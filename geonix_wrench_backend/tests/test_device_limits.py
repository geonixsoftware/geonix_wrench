"""Device quotas: three per account, one for an employee, and what gives way.

Firebase mints the ID tokens and verifies them by signature, so before this
existed the backend had no idea how many devices an account was signed in on
and no way to sign one out — a shop could buy a single employee seat and hand
the login round the whole workshop. The rules under test:

    Individual subscription ....... 3 devices
    Team subscription, owner ...... 3 devices
    Team subscription, employee ... 1 device

The enforcement runs on every authenticated request rather than at a login
endpoint, because there is no login endpoint to hang it on. That makes two
things worth pinning: a revoked device stops working within seconds instead of
whenever its token happens to expire, and a device the server has never seen
claims a slot on whichever request arrives first, so no ordering in the app can
let one slip past uncounted.
"""

import pytest
from fastapi.testclient import TestClient

import auth
import database
import devices
from config import (
    DEVICE_LIMIT_INDIVIDUAL,
    DEVICE_LIMIT_TEAM_MEMBER,
    DEVICE_LIMIT_TEAM_OWNER,
)
from main import app


@pytest.fixture()
def client(temp_db):
    # No dependency_overrides here, unlike most of the suite: overriding
    # get_current_user would replace the very code under test. The token check
    # is stubbed one layer down instead, so the real dependency — and with it
    # the real device enforcement — still runs.
    app.dependency_overrides.clear()
    yield TestClient(app)
    app.dependency_overrides.clear()


@pytest.fixture()
def signed_in(monkeypatch):
    """Make every request authenticate as one chosen user."""
    state = {}

    def _as(user):
        state["user_id"] = user["id"]

    def _fake_verify(credentials):
        # Re-read the row each call so a role change mid-test is picked up,
        # exactly as the real dependency would.
        return database.get_user_by_id(state["user_id"])

    monkeypatch.setattr(auth, "_verify_token", _fake_verify)
    return _as


def _user(email="mechanic@example.com"):
    return database.get_or_create_user(firebase_uid=f"uid-{email}", email=email)


def _headers(device_id, name=None, platform=None):
    headers = {"Authorization": "Bearer test", devices.DEVICE_ID_HEADER: device_id}
    if name:
        headers[devices.DEVICE_NAME_HEADER] = name
    if platform:
        headers[devices.DEVICE_PLATFORM_HEADER] = platform
    return headers


def _register(client, device_id, name=None):
    return client.post(
        "/api/auth/session",
        headers=_headers(device_id),
        json={"device_id": device_id, "device_name": name, "platform": "ios"},
    )


# ── the wire contract with the app ────────────────────────────────────────


def test_the_header_names_are_the_ones_the_app_sends():
    # Spelled out as literals on both sides — see the matching test in the
    # app's test/device_quota_test.dart. Renaming one end alone breaks nothing
    # visibly: requests keep succeeding and simply stop being counted, so the
    # quota quietly stops being enforced.
    assert devices.DEVICE_ID_HEADER == "X-Device-Id"
    assert devices.DEVICE_NAME_HEADER == "X-Device-Name"
    assert devices.DEVICE_PLATFORM_HEADER == "X-Device-Platform"


# ── the quota itself ──────────────────────────────────────────────────────


def test_the_three_documented_limits(temp_db):
    solo = _user("solo@example.com")
    assert devices.resolve_device_limit(solo) == DEVICE_LIMIT_INDIVIDUAL == 3

    org = database.create_organization(solo["id"], "Shop", seat_limit=3)
    database.update_user_org(solo["id"], org["id"], "owner")
    assert devices.resolve_device_limit(database.get_user_by_id(solo["id"])) == (
        DEVICE_LIMIT_TEAM_OWNER
    ) == 3

    employee = _user("emp@example.com")
    database.update_user_org(employee["id"], org["id"], "member")
    assert devices.resolve_device_limit(database.get_user_by_id(employee["id"])) == (
        DEVICE_LIMIT_TEAM_MEMBER
    ) == 1


def test_an_account_with_no_subscription_is_not_the_strictest_case(temp_db):
    # Deliberate: an unsubscribed account cannot record or export anything, so
    # there is nothing for a tight limit to protect, and one device would get
    # in the way of the screen where they would subscribe.
    assert devices.resolve_device_limit(_user("new@example.com")) == 3


# ── registration ──────────────────────────────────────────────────────────


def test_registering_three_devices_uses_three_slots(client, signed_in):
    signed_in(_user())
    for i in range(3):
        assert _register(client, f"device-{i}", f"Device {i}").status_code == 200

    body = client.get("/api/auth/devices", headers=_headers("device-0")).json()
    assert body["limit"] == 3
    assert body["used"] == 3
    assert {d["device_name"] for d in body["devices"]} == {"Device 0", "Device 1", "Device 2"}


def test_the_same_device_signing_in_twice_does_not_take_a_second_slot(client, signed_in):
    signed_in(_user())
    _register(client, "phone", "Phone")
    second = _register(client, "phone", "Phone renamed")

    assert second.status_code == 200
    assert second.json()["used"] == 1
    assert second.json()["device"]["device_name"] == "Phone renamed"


def test_a_fourth_device_pushes_out_the_least_recently_used(client, signed_in, monkeypatch):
    # Least recently *used*, not first registered — the distinction matters: a
    # mechanic's daily phone is very often the first device they ever set up,
    # and evicting by registration date would take away the one device they
    # actually work on to make room for a laptop they touched once.
    #
    # last_seen_at is normally only rewritten every few minutes, so the whole
    # test would fit inside one throttle window and silently degrade into a
    # first-registered check. Turning the throttle off is what makes the
    # ordering below real.
    monkeypatch.setattr(database, "DEVICE_LAST_SEEN_REFRESH_SECONDS", 0)
    user = _user()
    signed_in(user)
    for i in range(3):
        _register(client, f"device-{i}")

    # Registration order was 0, 1, 2. Using them in the reverse order makes
    # device-2 — the newest — the stalest, so a first-registered rule would
    # evict device-0 here and this test would fail.
    client.get("/api/auth/me", headers=_headers("device-1"))
    client.get("/api/auth/me", headers=_headers("device-0"))

    fourth = _register(client, "device-3", "New phone")
    assert fourth.status_code == 200
    assert fourth.json()["evicted"] == 1
    assert database.count_active_device_sessions(user["id"]) == 3

    # The evicted device is told, rather than carrying on until its token
    # expires up to an hour later.
    kicked = client.get("/api/auth/me", headers=_headers("device-2"))
    assert kicked.status_code == 401
    assert kicked.json()["detail"] == devices.DEVICE_REVOKED_DETAIL

    # ...and the two that were actually in use are untouched.
    assert client.get("/api/auth/me", headers=_headers("device-0")).status_code == 200
    assert client.get("/api/auth/me", headers=_headers("device-1")).status_code == 200


def test_eviction_never_removes_the_device_doing_the_signing_in(client, signed_in):
    user = _user()
    signed_in(user)
    for i in range(3):
        _register(client, f"device-{i}")

    _register(client, "device-3")
    assert client.get("/api/auth/me", headers=_headers("device-3")).status_code == 200
    assert database.count_active_device_sessions(user["id"]) == 3


def test_the_reject_policy_refuses_instead_of_evicting(client, signed_in, monkeypatch):
    monkeypatch.setattr(devices, "DEVICE_LIMIT_POLICY", devices.POLICY_REJECT)
    user = _user()
    signed_in(user)
    for i in range(3):
        _register(client, f"device-{i}")

    refused = _register(client, "device-3")
    # 403, not 401: being at the ceiling must not end the session of the device
    # asking, which would free a slot by taking the wrong one away.
    assert refused.status_code == 403
    assert refused.json()["detail"] == devices.DEVICE_LIMIT_DETAIL
    assert database.count_active_device_sessions(user["id"]) == 3
    assert client.get("/api/auth/me", headers=_headers("device-0")).status_code == 200


def test_a_typo_in_the_policy_setting_lets_the_customer_in(monkeypatch):
    # Failing towards eviction rather than towards locking a paying customer
    # out of their own account.
    monkeypatch.setattr(devices, "DEVICE_LIMIT_POLICY", "evcit_odlest")
    assert devices.evicts_oldest() is True


# ── enforcement on ordinary requests ──────────────────────────────────────


def test_an_unregistered_device_claims_a_slot_on_its_first_request(client, signed_in):
    user = _user()
    signed_in(user)

    # No POST /api/auth/session first. The app has no way to guarantee that
    # call lands before the profile fetch it makes at startup, so the quota
    # cannot depend on the ordering.
    resp = client.get("/api/auth/me", headers=_headers("walk-in", "Bench tablet", "android"))

    assert resp.status_code == 200
    sessions = database.list_device_sessions(user["id"])
    assert [s["device_name"] for s in sessions] == ["Bench tablet"]


def test_implicit_registration_obeys_the_same_ceiling(client, signed_in):
    user = _user()
    signed_in(user)
    for i in range(3):
        _register(client, f"device-{i}")

    client.get("/api/jobcards", headers=_headers("device-9"))
    assert database.count_active_device_sessions(user["id"]) == 3


def test_a_revoked_device_cannot_quietly_re_register_itself(client, signed_in):
    user = _user()
    signed_in(user)
    _register(client, "phone")
    session = database.list_device_sessions(user["id"])[0]
    database.revoke_device_session(user["id"], session["id"])

    # The row survives revocation precisely so this request answers 401 rather
    # than finding a clean table and signing the device straight back in.
    assert client.get("/api/auth/me", headers=_headers("phone")).status_code == 401
    assert database.count_active_device_sessions(user["id"]) == 0


def test_signing_in_again_brings_a_revoked_device_back(client, signed_in):
    user = _user()
    signed_in(user)
    _register(client, "phone")
    session = database.list_device_sessions(user["id"])[0]
    database.revoke_device_session(user["id"], session["id"])

    assert _register(client, "phone").status_code == 200
    assert client.get("/api/auth/me", headers=_headers("phone")).status_code == 200


def test_a_request_with_no_device_header_is_untracked_by_default(client, signed_in):
    user = _user()
    signed_in(user)
    assert client.get("/api/auth/me", headers={"Authorization": "Bearer t"}).status_code == 200
    assert database.count_active_device_sessions(user["id"]) == 0


def test_strict_mode_rejects_a_request_with_no_device_header(client, signed_in, monkeypatch):
    monkeypatch.setattr(auth, "REQUIRE_DEVICE_ID", True)
    signed_in(_user())

    resp = client.get("/api/auth/me", headers={"Authorization": "Bearer t"})
    # 400 rather than 401: the credentials are fine and signing the user out
    # would not add a header to an older build of the app.
    assert resp.status_code == 400
    assert devices.DEVICE_ID_HEADER in resp.json()["detail"]


# ── managing devices ──────────────────────────────────────────────────────


def test_the_device_list_marks_the_one_you_are_holding(client, signed_in):
    signed_in(_user())
    _register(client, "phone", "Phone")
    _register(client, "tablet", "Tablet")

    body = client.get("/api/auth/devices", headers=_headers("phone")).json()
    current = [d for d in body["devices"] if d["is_current"]]
    assert [d["device_name"] for d in current] == ["Phone"]


def test_signing_a_device_out_frees_its_slot(client, signed_in):
    user = _user()
    signed_in(user)
    _register(client, "phone", "Phone")
    _register(client, "tablet", "Tablet")
    tablet = next(d for d in client.get("/api/auth/devices", headers=_headers("phone")).json()["devices"] if d["device_name"] == "Tablet")

    body = client.delete(f"/api/auth/devices/{tablet['id']}", headers=_headers("phone")).json()
    assert body["used"] == 1
    assert client.get("/api/auth/me", headers=_headers("tablet")).status_code == 401


def test_you_cannot_sign_out_someone_elses_device(client, signed_in):
    stranger = _user("stranger@example.com")
    mine = _user("mine@example.com")

    signed_in(stranger)
    _register(client, "their-phone", "Their phone")
    victim = database.list_device_sessions(stranger["id"])[0]

    signed_in(mine)
    _register(client, "my-phone", "My phone")
    resp = client.delete(f"/api/auth/devices/{victim['id']}", headers=_headers("my-phone"))

    # 404, not 403 — a probe must not learn that the id exists on some other
    # account.
    assert resp.status_code == 404
    assert database.count_active_device_sessions(stranger["id"]) == 1


def test_the_device_screen_is_reachable_while_at_the_ceiling(client, signed_in, monkeypatch):
    # The one that would make the feature unusable if it regressed: enforcing
    # the quota on the screen that frees a slot is a locked door with the key
    # behind it.
    monkeypatch.setattr(devices, "DEVICE_LIMIT_POLICY", devices.POLICY_REJECT)
    user = _user()
    signed_in(user)
    for i in range(3):
        _register(client, f"device-{i}")

    listing = client.get("/api/auth/devices", headers=_headers("brand-new-laptop"))
    assert listing.status_code == 200
    assert listing.json()["used"] == 3

    # ...and the listing itself did not sneak the new device in.
    assert database.count_active_device_sessions(user["id"]) == 3


# ── role changes ──────────────────────────────────────────────────────────


def test_joining_a_shop_as_an_employee_cuts_the_account_back_to_one_device(
    client, signed_in
):
    owner = _user("owner@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=5)
    database.update_user_org(owner["id"], org["id"], "owner")

    joiner = _user("joiner@example.com")
    signed_in(joiner)
    for i in range(3):
        _register(client, f"device-{i}")
    assert database.count_active_device_sessions(joiner["id"]) == 3

    invite = database.create_invite(org["id"], joiner["id"], owner["id"])
    # The accepting device is the most recently used by definition, and
    # eviction takes the least recently used, so it survives its own promotion.
    resp = client.post(f"/api/invites/{invite['id']}/accept", headers=_headers("device-2"))

    assert resp.status_code == 200
    assert database.count_active_device_sessions(joiner["id"]) == DEVICE_LIMIT_TEAM_MEMBER == 1
    assert client.get("/api/auth/me", headers=_headers("device-2")).status_code == 200
    assert client.get("/api/auth/me", headers=_headers("device-0")).status_code == 401


def test_an_employee_who_leaves_gets_the_full_allowance_back(client, signed_in):
    owner = _user("owner2@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=5)
    database.update_user_org(owner["id"], org["id"], "owner")
    employee = _user("emp2@example.com")
    database.update_user_org(employee["id"], org["id"], "member")

    signed_in(employee)
    _register(client, "phone")
    assert client.get("/api/auth/devices", headers=_headers("phone")).json()["limit"] == 1

    database.leave_organization(employee["id"])
    assert client.get("/api/auth/devices", headers=_headers("phone")).json()["limit"] == 3


# ── what the subscription panel is told ───────────────────────────────────


def test_billing_status_quotes_the_quota_for_an_individual(client, signed_in):
    signed_in(_user())
    _register(client, "phone")

    body = client.get("/api/billing/status", headers=_headers("phone")).json()
    assert body["device_limit"] == 3
    assert body["device_used"] == 1


def test_billing_status_quotes_one_device_to_an_employee(client, signed_in):
    owner = _user("owner3@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=5)
    database.update_user_org(owner["id"], org["id"], "owner")
    employee = _user("emp3@example.com")
    database.update_user_org(employee["id"], org["id"], "member")

    signed_in(employee)
    _register(client, "phone")
    body = client.get("/api/billing/status", headers=_headers("phone")).json()

    # Owner and employee share one Team subscription, so a panel that read the
    # plan instead of the role would promise an employee three.
    assert body["device_limit"] == 1
    assert body["device_used"] == 1


def test_billing_status_quotes_three_to_the_shop_owner(client, signed_in):
    owner = _user("owner4@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=5)
    database.update_user_org(owner["id"], org["id"], "owner")

    signed_in(database.get_user_by_id(owner["id"]))
    _register(client, "phone")
    assert client.get("/api/billing/status", headers=_headers("phone")).json()["device_limit"] == 3


# ── erasure ───────────────────────────────────────────────────────────────


def test_closing_an_account_takes_its_device_rows_with_it(client, signed_in):
    user = _user("closing@example.com")
    signed_in(user)
    _register(client, "phone")
    assert database.count_active_device_sessions(user["id"]) == 1

    database.delete_user_account(user["id"])

    with database.get_connection() as conn:
        remaining = conn.execute(
            "SELECT COUNT(*) AS c FROM device_sessions WHERE user_id = ?", (user["id"],)
        ).fetchone()["c"]
    # Revoked rows normally survive to stop a device re-registering; there is
    # no account left to register against, and keeping device identifiers for
    # someone who asked to be forgotten is the thing to avoid.
    assert remaining == 0

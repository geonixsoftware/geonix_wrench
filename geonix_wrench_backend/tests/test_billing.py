from fastapi.testclient import TestClient

import auth
import billing
import database
from config import (
    BILLING_CURRENCY,
    INDIVIDUAL_PRICE_ID,
    INDIVIDUAL_PRICE_PER_MONTH,
    TEAM_MIN_SEATS,
    TEAM_PRICE_ID,
    TEAM_PRICE_PER_SEAT,
)
from main import app


def _override_for(user_id):
    def _get_current_user():
        return database.get_user_by_id(user_id)

    return _get_current_user


def _make_client(temp_db, user_id):
    app.dependency_overrides[auth.get_current_user] = _override_for(user_id)
    return TestClient(app)


def _make_user(email):
    return database.get_or_create_user(firebase_uid=f"uid-{email}", email=email)


def _clear_overrides():
    app.dependency_overrides.clear()


class _FakeSession:
    url = "https://checkout.stripe.com/test"


def _patch_session_create(monkeypatch):
    captured = {}

    def fake_create(**kwargs):
        captured.update(kwargs)
        return _FakeSession()

    monkeypatch.setattr(billing.stripe.checkout.Session, "create", staticmethod(fake_create))
    return captured


def _checkout_body(plan, **overrides):
    body = {
        "plan": plan,
        "success_url": "https://geonix.site/billing/success/",
        "cancel_url": "https://geonix.site/billing/cancel/",
    }
    body.update(overrides)
    return body


def test_team_checkout_rejects_quantity_below_minimum(temp_db):
    owner = _make_user("teamlow@example.com")
    database.create_organization(owner["id"], "Shop", seat_limit=2)
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("team", quantity=1))
    assert resp.status_code == 400
    _clear_overrides()


def test_team_checkout_rejects_missing_quantity(temp_db):
    owner = _make_user("teamnone@example.com")
    database.create_organization(owner["id"], "Shop", seat_limit=2)
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("team"))
    assert resp.status_code == 400
    _clear_overrides()


def test_team_checkout_is_allowed_before_the_shop_exists(temp_db, monkeypatch):
    # Seats are chosen and paid for first; the shop is named afterwards. The
    # subscription is held against the buyer until then, so it is scoped to the
    # user rather than an org that does not exist yet.
    captured = _patch_session_create(monkeypatch)
    owner = _make_user("teamnoorg@example.com")
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("team", quantity=3))
    assert resp.status_code == 200
    assert captured["line_items"] == [{"price": TEAM_PRICE_ID, "quantity": 3}]
    metadata = captured["subscription_data"]["metadata"]
    assert metadata["scope_type"] == "user"
    assert metadata["scope_id"] == str(owner["id"])
    assert metadata["plan"] == "team"
    _clear_overrides()


def test_team_checkout_still_enforces_the_seat_minimum_without_a_shop(temp_db):
    owner = _make_user("teamminnoorg@example.com")
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("team", quantity=1))
    assert resp.status_code == 400
    _clear_overrides()


def test_team_checkout_requires_owner(temp_db):
    owner = _make_user("teamown@example.com")
    member = _make_user("teammember@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=5)
    database.update_user_org(member["id"], org["id"], "member")

    client = _make_client(temp_db, member["id"])
    resp = client.post("/api/billing/checkout-session", json=_checkout_body("team", quantity=3))
    assert resp.status_code == 403
    _clear_overrides()


def test_team_checkout_sends_selected_quantity(temp_db, monkeypatch):
    owner = _make_user("teamqty@example.com")
    database.create_organization(owner["id"], "Shop", seat_limit=2)
    captured = _patch_session_create(monkeypatch)
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("team", quantity=4))
    assert resp.status_code == 200
    assert resp.json()["checkout_url"] == _FakeSession.url
    assert captured["line_items"] == [{"price": TEAM_PRICE_ID, "quantity": 4}]
    assert captured["subscription_data"]["metadata"]["scope_type"] == "org"
    _clear_overrides()


def test_checkout_accepts_promotion_codes(temp_db, monkeypatch):
    # Without this flag Checkout renders no promo code field at all, which made
    # every coupon we handed out impossible to redeem.
    user = _make_user("promo@example.com")
    captured = _patch_session_create(monkeypatch)
    client = _make_client(temp_db, user["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("individual"))
    assert resp.status_code == 200
    assert captured["allow_promotion_codes"] is True
    _clear_overrides()


def test_checkout_opts_out_of_managed_payments(temp_db, monkeypatch):
    # Managed Payments is on by default for the account and demands a product
    # tax code our prices do not carry, so Stripe rejected every session with an
    # invalid_request_error and checkout 502'd. Opting out must stay explicit.
    user = _make_user("managedpay@example.com")
    captured = _patch_session_create(monkeypatch)
    client = _make_client(temp_db, user["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("individual"))
    assert resp.status_code == 200
    assert captured["managed_payments"] == {"enabled": False}
    _clear_overrides()


def test_team_checkout_has_no_upper_seat_limit(temp_db, monkeypatch):
    # Deliberate product decision: an owner who wants 999 seats gets 999. Only a
    # floor of TEAM_MIN_SEATS is enforced — do not add a cap.
    owner = _make_user("teambig@example.com")
    database.create_organization(owner["id"], "Big Shop", seat_limit=2)
    captured = _patch_session_create(monkeypatch)
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("team", quantity=999))
    assert resp.status_code == 200
    assert captured["line_items"] == [{"price": TEAM_PRICE_ID, "quantity": 999}]
    _clear_overrides()


def test_individual_checkout_rejects_org_members(temp_db):
    owner = _make_user("indorg@example.com")
    database.create_organization(owner["id"], "Shop", seat_limit=2)
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("individual"))
    assert resp.status_code == 400
    _clear_overrides()


def test_individual_checkout_sends_quantity_one(temp_db, monkeypatch):
    user = _make_user("induser@example.com")
    captured = _patch_session_create(monkeypatch)
    client = _make_client(temp_db, user["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("individual"))
    assert resp.status_code == 200
    assert captured["line_items"] == [{"price": INDIVIDUAL_PRICE_ID, "quantity": 1}]
    assert captured["subscription_data"]["metadata"]["scope_type"] == "user"
    assert captured["customer_email"] == "induser@example.com"
    _clear_overrides()


def test_unknown_plan_rejected(temp_db):
    user = _make_user("badplan@example.com")
    client = _make_client(temp_db, user["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("enterprise"))
    assert resp.status_code == 400
    _clear_overrides()


def test_status_inactive_without_subscription(temp_db):
    user = _make_user("nobus@example.com")
    client = _make_client(temp_db, user["id"])

    resp = client.get("/api/billing/status")
    assert resp.status_code == 200
    body = resp.json()
    assert body["scope_type"] == "user"
    assert body["is_active"] is False
    assert body["status"] is None
    _clear_overrides()


def test_status_active_for_user_subscription(temp_db):
    user = _make_user("subuser@example.com")
    database.upsert_subscription(
        scope_type="user",
        scope_id=user["id"],
        stripe_subscription_id="sub_1",
        stripe_customer_id="cus_1",
        plan="individual",
        status="active",
        quantity=1,
        current_period_end="2026-09-01T00:00:00+00:00",
    )
    client = _make_client(temp_db, user["id"])

    resp = client.get("/api/billing/status")
    body = resp.json()
    assert body["scope_type"] == "user"
    assert body["is_active"] is True
    assert body["status"] == "active"
    assert body["seat_limit"] == 1
    _clear_overrides()


def test_status_org_scope_uses_organization_subscription(temp_db):
    owner = _make_user("orgsub@example.com")
    member = _make_user("orgmember@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=3)
    database.update_user_org(member["id"], org["id"], "member")
    database.upsert_subscription(
        scope_type="org",
        scope_id=org["id"],
        stripe_subscription_id="sub_org",
        stripe_customer_id="cus_org",
        plan="team",
        status="trialing",
        quantity=3,
        current_period_end="2026-09-01T00:00:00+00:00",
    )

    client = _make_client(temp_db, member["id"])
    resp = client.get("/api/billing/status")
    body = resp.json()
    assert body["scope_type"] == "org"
    assert body["is_active"] is True
    assert body["status"] == "trialing"
    assert body["seat_limit"] == 3
    assert body["seat_used"] == 2
    _clear_overrides()


def test_status_quotes_both_plan_prices_in_every_scope(temp_db):
    # The app's plan picker renders the Individual and Team cards together, so
    # both figures must be present whichever scope the caller occupies. Quoting
    # only the scope's own price made the other card advertise the wrong one.
    user = _make_user("prices@example.com")
    client = _make_client(temp_db, user["id"])
    body = client.get("/api/billing/status").json()
    assert body["scope_type"] == "user"
    assert body["individual_price"] == INDIVIDUAL_PRICE_PER_MONTH
    assert body["team_price_per_seat"] == TEAM_PRICE_PER_SEAT
    _clear_overrides()

    owner = _make_user("pricesorg@example.com")
    database.create_organization(owner["id"], "Shop", seat_limit=2)
    client = _make_client(temp_db, owner["id"])
    body = client.get("/api/billing/status").json()
    assert body["scope_type"] == "org"
    assert body["individual_price"] == INDIVIDUAL_PRICE_PER_MONTH
    assert body["team_price_per_seat"] == TEAM_PRICE_PER_SEAT
    _clear_overrides()


def test_the_two_advertised_prices_are_distinct(temp_db):
    # Guards the bug directly: if these ever collapse to one value the plan
    # cards can no longer disagree, and this test stops being meaningful.
    assert INDIVIDUAL_PRICE_PER_MONTH != TEAM_PRICE_PER_SEAT


def _as_stripe_object(payload):
    """Wrap a payload the way the Stripe SDK actually returns it.

    `StripeObject` is not a dict subclass and has no `.get()`. Every test here
    passed plain dicts, so `payload.get(...)` looked fine while failing against
    every real API response — the webhook could never have synced a live
    subscription. These tests use the real type so that cannot recur.
    """
    from stripe._stripe_object import StripeObject

    return StripeObject.construct_from(payload, "sk_test")


def _as_stripe_list(rows):
    from stripe._list_object import ListObject

    return ListObject.construct_from(
        {"object": "list", "has_more": False, "url": "/v1/x", "data": rows},
        "sk_test",
    )


def test_sync_handles_real_stripe_objects_not_just_dicts(temp_db):
    user = _make_user("realobj@example.com")
    subscription = _as_stripe_object(
        _stripe_subscription(scope_type="user", scope_id=user["id"], quantity=1)
    )

    billing._sync_subscription(subscription)

    stored = database.get_subscription("user", user["id"])
    assert stored is not None
    assert stored["status"] == "active"
    assert stored["stripe_subscription_id"] == "sub_from_stripe"


def _patch_confirmation_email(monkeypatch):
    calls = []
    monkeypatch.setattr(
        billing.email_service,
        "send_subscription_confirmation",
        lambda **kwargs: calls.append(kwargs) or True,
    )
    return calls


def test_new_subscription_sends_a_confirmation_email(temp_db, monkeypatch):
    calls = _patch_confirmation_email(monkeypatch)
    user = _make_user("newsub@example.com")

    billing._sync_subscription(_stripe_subscription(scope_type="user", scope_id=user["id"]))

    assert len(calls) == 1
    assert calls[0]["email"] == "newsub@example.com"
    assert calls[0]["plan"] == "individual"


def test_renewal_does_not_resend_the_confirmation_email(temp_db, monkeypatch):
    # A renewal, a proration, or any other update to an already-active
    # subscription fires the same webhook event as a brand new one. Only the
    # activation itself should trigger an email.
    calls = _patch_confirmation_email(monkeypatch)
    user = _make_user("renewsub@example.com")
    subscription = _stripe_subscription(scope_type="user", scope_id=user["id"])

    billing._sync_subscription(subscription)
    billing._sync_subscription(subscription)

    assert len(calls) == 1


def test_team_subscription_emails_the_shop_owner(temp_db, monkeypatch):
    calls = _patch_confirmation_email(monkeypatch)
    owner = _make_user("shopowner@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=2)

    billing._sync_subscription(
        _stripe_subscription(scope_type="org", scope_id=org["id"], plan="team", quantity=3)
    )

    assert len(calls) == 1
    assert calls[0]["email"] == "shopowner@example.com"
    assert calls[0]["seats"] == 3


def test_reconciliation_handles_real_stripe_list_objects(temp_db, monkeypatch):
    user = _make_user("reallist@example.com")
    monkeypatch.setattr(
        billing.stripe.Customer,
        "list",
        lambda **kwargs: _as_stripe_list([{"id": "cus_real"}]),
    )
    monkeypatch.setattr(
        billing.stripe.Subscription,
        "list",
        lambda **kwargs: _as_stripe_list(
            [_stripe_subscription(scope_type="user", scope_id=user["id"])]
        ),
    )
    client = _make_client(temp_db, user["id"])

    assert client.get("/api/billing/status?reconcile=true").json()["is_active"] is True
    _clear_overrides()


def _patch_stripe_lookup(monkeypatch, subscriptions, *, customer_id="cus_rec"):
    """Pretend Stripe holds `subscriptions` for the caller's email."""
    monkeypatch.setattr(
        billing.stripe.Customer,
        "list",
        lambda **kwargs: {"data": [{"id": customer_id}]},
    )
    monkeypatch.setattr(
        billing.stripe.Subscription,
        "list",
        lambda **kwargs: {"data": subscriptions},
    )


def _stripe_subscription(*, scope_type, scope_id, plan="individual", status="active", quantity=1):
    return {
        "id": "sub_from_stripe",
        "customer": "cus_rec",
        "status": status,
        "current_period_end": 1788220800,
        "metadata": {"scope_type": scope_type, "scope_id": str(scope_id), "plan": plan},
        "items": {"data": [{"quantity": quantity, "price": {"id": INDIVIDUAL_PRICE_ID}}]},
    }


def test_status_recovers_a_subscription_the_webhook_never_delivered(temp_db, monkeypatch):
    # The webhook is the only writer, and Stripe cannot reach a local dev
    # server — so without reconciliation a paid customer stays locked out.
    user = _make_user("missedhook@example.com")
    _patch_stripe_lookup(
        monkeypatch,
        [_stripe_subscription(scope_type="user", scope_id=user["id"])],
    )
    client = _make_client(temp_db, user["id"])

    assert client.get("/api/billing/status").json()["is_active"] is False
    body = client.get("/api/billing/status?reconcile=true").json()
    assert body["is_active"] is True
    # And it is now stored, so later reads need no Stripe round-trip.
    assert database.get_subscription("user", user["id"]) is not None
    _clear_overrides()


def test_reconciliation_ignores_another_accounts_subscription(temp_db, monkeypatch):
    # Shared or recycled emails must not hand over someone else's plan.
    user = _make_user("shared@example.com")
    _patch_stripe_lookup(
        monkeypatch,
        [_stripe_subscription(scope_type="user", scope_id=user["id"] + 999)],
    )
    client = _make_client(temp_db, user["id"])

    assert client.get("/api/billing/status?reconcile=true").json()["is_active"] is False
    _clear_overrides()


def test_reconciliation_prefers_the_live_subscription(temp_db, monkeypatch):
    user = _make_user("twosubs@example.com")
    _patch_stripe_lookup(
        monkeypatch,
        [
            _stripe_subscription(scope_type="user", scope_id=user["id"], status="canceled"),
            _stripe_subscription(scope_type="user", scope_id=user["id"], status="active"),
        ],
    )
    client = _make_client(temp_db, user["id"])

    assert client.get("/api/billing/status?reconcile=true").json()["is_active"] is True
    _clear_overrides()


def test_status_does_not_reconcile_unless_asked(temp_db, monkeypatch):
    # The ordinary polling path must not pay for a Stripe round-trip.
    called = {"n": 0}

    def _boom(**kwargs):
        called["n"] += 1
        return {"data": []}

    monkeypatch.setattr(billing.stripe.Customer, "list", _boom)
    user = _make_user("nopoll@example.com")
    client = _make_client(temp_db, user["id"])

    client.get("/api/billing/status")
    assert called["n"] == 0
    _clear_overrides()


def _buy_team_before_shop(email, *, seats, status="active"):
    """A user who has paid for Team seats but has not named their shop yet."""
    user = _make_user(email)
    database.upsert_subscription(
        scope_type="user",
        scope_id=user["id"],
        stripe_subscription_id="sub_pending",
        stripe_customer_id="cus_pending",
        plan="team",
        status=status,
        quantity=seats,
        current_period_end="2026-09-01T00:00:00+00:00",
    )
    return user


def test_status_flags_a_paid_team_subscription_with_no_shop(temp_db):
    user = _buy_team_before_shop("pendingteam@example.com", seats=5)
    client = _make_client(temp_db, user["id"])

    body = client.get("/api/billing/status").json()
    assert body["is_active"] is True
    assert body["plan"] == "team"
    # The app uses this to prompt for a shop name, and must show the seat count
    # that was actually purchased rather than a solo seat.
    assert body["needs_shop"] is True
    assert body["seat_limit"] == 5
    _clear_overrides()


def test_status_does_not_flag_an_individual_subscription(temp_db):
    user = _make_user("solo@example.com")
    database.upsert_subscription(
        scope_type="user",
        scope_id=user["id"],
        stripe_subscription_id="sub_solo",
        stripe_customer_id="cus_solo",
        plan="individual",
        status="active",
        quantity=1,
        current_period_end=None,
    )
    client = _make_client(temp_db, user["id"])

    body = client.get("/api/billing/status").json()
    assert body["needs_shop"] is False
    assert body["seat_limit"] == 1
    _clear_overrides()


def test_naming_the_shop_inherits_the_purchased_seats(temp_db, monkeypatch):
    modified = {}

    def fake_modify(subscription_id, **kwargs):
        modified["id"] = subscription_id
        modified["metadata"] = kwargs.get("metadata")
        return {}

    monkeypatch.setattr(billing.stripe.Subscription, "modify", fake_modify)

    user = _buy_team_before_shop("naming@example.com", seats=6)
    client = _make_client(temp_db, user["id"])

    # The client cannot pick a seat count; only a name is sent.
    resp = client.post("/api/organizations", json={"name": "Pit Lane"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["name"] == "Pit Lane"
    assert body["seat_limit"] == 6

    org_id = body["id"]
    # The subscription moved onto the shop and no longer sits on the buyer.
    assert database.get_subscription("user", user["id"]) is None
    moved = database.get_subscription("org", org_id)
    assert moved is not None
    assert moved["quantity"] == 6
    assert moved["stripe_subscription_id"] == "sub_pending"

    # Future webhooks must resolve to the org, not the buyer.
    assert modified["id"] == "sub_pending"
    assert modified["metadata"]["scope_type"] == "org"
    assert modified["metadata"]["scope_id"] == str(org_id)
    _clear_overrides()


def test_naming_the_shop_ignores_a_client_supplied_seat_limit(temp_db, monkeypatch):
    monkeypatch.setattr(billing.stripe.Subscription, "modify", lambda *a, **k: {})
    user = _buy_team_before_shop("greedy@example.com", seats=2)
    client = _make_client(temp_db, user["id"])

    resp = client.post("/api/organizations", json={"name": "Greedy", "seat_limit": 99})
    assert resp.status_code == 200
    assert resp.json()["seat_limit"] == 2
    _clear_overrides()


def test_a_cancelled_team_subscription_does_not_grant_seats(temp_db):
    user = _buy_team_before_shop("lapsed@example.com", seats=8, status="canceled")
    client = _make_client(temp_db, user["id"])

    assert client.get("/api/billing/status").json()["needs_shop"] is False
    resp = client.post("/api/organizations", json={"name": "Lapsed"})
    assert resp.status_code == 200
    assert resp.json()["seat_limit"] == TEAM_MIN_SEATS
    assert database.get_subscription("org", resp.json()["id"]) is None
    _clear_overrides()


def _seat_org(owner_email, *, seat_limit, status="active", members=0):
    """An org with an active Team subscription and `members` extra members."""
    owner = _make_user(owner_email)
    org = database.create_organization(owner["id"], "Shop", seat_limit=seat_limit)
    for i in range(members):
        member = _make_user(f"{i}-member-{owner_email}")
        database.update_user_org(member["id"], org["id"], "member")
    database.upsert_subscription(
        scope_type="org",
        scope_id=org["id"],
        stripe_subscription_id="sub_seats",
        stripe_customer_id="cus_seats",
        plan="team",
        status=status,
        quantity=seat_limit,
        current_period_end="2026-09-01T00:00:00+00:00",
    )
    return owner, org


def _patch_subscription_modify(monkeypatch):
    captured = {}

    monkeypatch.setattr(
        billing.stripe.Subscription,
        "retrieve",
        staticmethod(lambda *a, **kw: {"items": {"data": [{"id": "si_1"}]}}),
    )

    def fake_modify(sub_id, **kwargs):
        captured["id"] = sub_id
        captured.update(kwargs)
        return {}

    monkeypatch.setattr(billing.stripe.Subscription, "modify", staticmethod(fake_modify))
    return captured


def test_seat_update_changes_stripe_quantity_and_seat_limit(temp_db, monkeypatch):
    owner, org = _seat_org("seatup@example.com", seat_limit=2)
    captured = _patch_subscription_modify(monkeypatch)
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/seats", json={"quantity": 5})
    assert resp.status_code == 200
    assert captured["id"] == "sub_seats"
    assert captured["items"] == [{"id": "si_1", "quantity": 5}]
    assert captured["proration_behavior"] == "create_prorations"
    # Applied locally too, so the owner does not stare at a stale count while
    # the webhook is in flight (or not forwarded at all in dev).
    assert database.get_organization(org["id"])["seat_limit"] == 5
    assert resp.json()["seat_limit"] == 5
    _clear_overrides()


def test_seat_update_has_no_upper_seat_limit(temp_db, monkeypatch):
    owner, org = _seat_org("seatbig@example.com", seat_limit=2)
    captured = _patch_subscription_modify(monkeypatch)
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/seats", json={"quantity": 999})
    assert resp.status_code == 200
    assert captured["items"] == [{"id": "si_1", "quantity": 999}]
    assert database.get_organization(org["id"])["seat_limit"] == 999
    _clear_overrides()


def test_seat_update_rejects_below_plan_minimum(temp_db, monkeypatch):
    owner, _ = _seat_org("seatmin@example.com", seat_limit=4)
    _patch_subscription_modify(monkeypatch)
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/seats", json={"quantity": 1})
    assert resp.status_code == 400
    _clear_overrides()


def test_seat_update_rejects_dropping_below_occupied_seats(temp_db, monkeypatch):
    # Owner + 3 members = 4 seats in use; nothing evicts members, so shrinking
    # to 3 would oversell the plan.
    owner, org = _seat_org("seatused@example.com", seat_limit=5, members=3)
    _patch_subscription_modify(monkeypatch)
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/seats", json={"quantity": 3})
    assert resp.status_code == 400
    assert "in use" in resp.json()["detail"]
    assert database.get_organization(org["id"])["seat_limit"] == 5
    _clear_overrides()


def test_seat_update_requires_owner(temp_db, monkeypatch):
    _, org = _seat_org("seatowner@example.com", seat_limit=4, members=1)
    _patch_subscription_modify(monkeypatch)
    member = database.list_org_members(org["id"])[1]
    client = _make_client(temp_db, member["id"])

    resp = client.post("/api/billing/seats", json={"quantity": 6})
    assert resp.status_code == 403
    _clear_overrides()


def test_seat_update_requires_active_subscription(temp_db, monkeypatch):
    owner, _ = _seat_org("seatcanceled@example.com", seat_limit=4, status="canceled")
    _patch_subscription_modify(monkeypatch)
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/seats", json={"quantity": 6})
    assert resp.status_code == 400
    _clear_overrides()


def test_seat_update_requires_an_organization(temp_db, monkeypatch):
    solo = _make_user("seatsolo@example.com")
    _patch_subscription_modify(monkeypatch)
    client = _make_client(temp_db, solo["id"])

    resp = client.post("/api/billing/seats", json={"quantity": 3})
    assert resp.status_code == 400
    _clear_overrides()


def test_status_exposes_seat_management_affordances(temp_db):
    owner, org = _seat_org("seatstatus@example.com", seat_limit=3, members=1)

    client = _make_client(temp_db, owner["id"])
    owner_body = client.get("/api/billing/status").json()
    assert owner_body["plan"] == "team"
    assert owner_body["min_seats"] == 2
    assert owner_body["can_manage_seats"] is True
    # The clients render the advertised price from this rather than a figure
    # retyped in each of them.
    assert owner_body["price_per_seat"] == TEAM_PRICE_PER_SEAT
    assert owner_body["currency"] == BILLING_CURRENCY
    _clear_overrides()

    member = database.list_org_members(org["id"])[1]
    client = _make_client(temp_db, member["id"])
    member_body = client.get("/api/billing/status").json()
    # Members see the seat usage but must not get the stepper.
    assert member_body["can_manage_seats"] is False
    _clear_overrides()


def _patch_webhook(monkeypatch, event):
    monkeypatch.setattr(
        billing.stripe.Webhook, "construct_event", lambda *args, **kwargs: event
    )


def test_webhook_invalid_signature_rejected(temp_db, monkeypatch):
    def _raise(*args, **kwargs):
        raise ValueError("bad signature")

    monkeypatch.setattr(billing.stripe.Webhook, "construct_event", _raise)

    client = TestClient(app)
    app.dependency_overrides.clear()
    resp = client.post(
        "/api/billing/webhook",
        content=b"{}",
        headers={"stripe-signature": "tampered"},
    )
    assert resp.status_code == 400


def test_webhook_syncs_org_seat_limit(temp_db, monkeypatch):
    owner = _make_user("webhookorg@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=5)
    event = {
        "type": "customer.subscription.updated",
        "data": {
            "object": {
                "id": "sub_org_2",
                "customer": "cus_org_2",
                "status": "active",
                "current_period_end": 1750000000,
                "metadata": {
                    "scope_type": "org",
                    "scope_id": str(org["id"]),
                    "plan": "team",
                },
                "items": {"data": [{"price": {"id": TEAM_PRICE_ID}, "quantity": 6}]},
            }
        },
    }
    _patch_webhook(monkeypatch, event)

    client = TestClient(app)
    app.dependency_overrides.clear()
    resp = client.post(
        "/api/billing/webhook",
        content=b"{}",
        headers={"stripe-signature": "test"},
    )
    assert resp.status_code == 200
    assert database.get_organization(org["id"])["seat_limit"] == 6
    sub = database.get_subscription("org", org["id"])
    assert sub["status"] == "active"
    assert sub["quantity"] == 6
    assert sub["current_period_end"] is not None


def test_webhook_upserts_user_subscription_on_delete(temp_db, monkeypatch):
    user = _make_user("webhookuser@example.com")
    event = {
        "type": "customer.subscription.deleted",
        "data": {
            "object": {
                "id": "sub_user_1",
                "customer": "cus_user_1",
                "status": "canceled",
                "metadata": {
                    "scope_type": "user",
                    "scope_id": str(user["id"]),
                    "plan": "individual",
                },
                "items": {"data": [{"price": {"id": INDIVIDUAL_PRICE_ID}, "quantity": 1}]},
            }
        },
    }
    _patch_webhook(monkeypatch, event)

    client = TestClient(app)
    app.dependency_overrides.clear()
    resp = client.post(
        "/api/billing/webhook",
        content=b"{}",
        headers={"stripe-signature": "test"},
    )
    assert resp.status_code == 200

    sub = database.get_subscription("user", user["id"])
    assert sub["status"] == "canceled"

    client = _make_client(temp_db, user["id"])
    status_resp = client.get("/api/billing/status")
    assert status_resp.json()["is_active"] is False
    _clear_overrides()


def test_webhook_ignores_unhandled_events(temp_db, monkeypatch):
    user = _make_user("webhookignored@example.com")
    event = {
        "type": "invoice.paid",
        "data": {"object": {}},
    }
    _patch_webhook(monkeypatch, event)

    client = TestClient(app)
    app.dependency_overrides.clear()
    resp = client.post(
        "/api/billing/webhook",
        content=b"{}",
        headers={"stripe-signature": "test"},
    )
    assert resp.status_code == 200
    assert database.get_subscription("user", user["id"]) is None


# ------------------------------------------------------- billing portal


def _patch_portal(monkeypatch, url="https://billing.stripe.com/session/test"):
    captured = {}

    def fake_create(**kwargs):
        captured.update(kwargs)
        return type("S", (), {"url": url})()

    monkeypatch.setattr(
        billing.stripe.billing_portal.Session, "create", staticmethod(fake_create)
    )
    return captured


def test_portal_opens_for_an_individual_subscriber(temp_db, monkeypatch):
    user = _make_user("portalsolo@example.com")
    database.upsert_subscription(
        scope_type="user", scope_id=user["id"],
        stripe_subscription_id="sub_p", stripe_customer_id="cus_p",
        plan="individual", status="active", quantity=1,
        current_period_end="2026-09-01T00:00:00+00:00",
    )
    captured = _patch_portal(monkeypatch)
    client = _make_client(temp_db, user["id"])

    resp = client.post("/api/billing/portal-session", json={"return_url": "https://geonix.site/settings/"})
    assert resp.status_code == 200
    assert resp.json()["portal_url"].startswith("https://billing.stripe.com/")
    assert captured["customer"] == "cus_p"
    assert captured["return_url"] == "https://geonix.site/settings/"
    _clear_overrides()


def test_portal_requires_owner_for_a_shop(temp_db, monkeypatch):
    _, org = _seat_org("portalteam@example.com", seat_limit=3, members=1)
    _patch_portal(monkeypatch)
    member = database.list_org_members(org["id"])[1]
    client = _make_client(temp_db, member["id"])

    resp = client.post("/api/billing/portal-session", json={"return_url": "https://geonix.site/settings/"})
    assert resp.status_code == 403
    _clear_overrides()


def test_portal_rejected_without_a_subscription(temp_db, monkeypatch):
    user = _make_user("portalnone@example.com")
    _patch_portal(monkeypatch)
    client = _make_client(temp_db, user["id"])

    resp = client.post("/api/billing/portal-session", json={"return_url": "https://geonix.site/settings/"})
    assert resp.status_code == 400
    _clear_overrides()


def test_failed_invoice_marks_the_subscription_past_due(temp_db, monkeypatch):
    # Previously only customer.subscription.* was handled, so a lapse for
    # non-payment kept reporting the last known status.
    owner, org = _seat_org("pastdue@example.com", seat_limit=2)

    monkeypatch.setattr(
        billing.stripe.Subscription, "retrieve",
        staticmethod(lambda *a, **kw: {
            "id": "sub_seats", "customer": "cus_seats", "status": "past_due",
            "current_period_end": 1750000000,
            "metadata": {"scope_type": "org", "scope_id": str(org["id"]), "plan": "team"},
            "items": {"data": [{"price": {"id": TEAM_PRICE_ID}, "quantity": 2}]},
        }),
    )
    _patch_webhook(monkeypatch, {
        "type": "invoice.payment_failed",
        "data": {"object": {"id": "in_1", "subscription": "sub_seats"}},
    })

    client = TestClient(app)
    app.dependency_overrides.clear()
    resp = client.post("/api/billing/webhook", content=b"{}", headers={"stripe-signature": "t"})
    assert resp.status_code == 200

    assert database.get_subscription("org", org["id"])["status"] == "past_due"

    client = _make_client(temp_db, owner["id"])
    assert client.get("/api/billing/status").json()["is_active"] is False
    _clear_overrides()


def test_invoice_without_subscription_is_ignored(temp_db, monkeypatch):
    _patch_webhook(monkeypatch, {
        "type": "invoice.payment_failed",
        "data": {"object": {"id": "in_2"}},
    })
    client = TestClient(app)
    app.dependency_overrides.clear()
    resp = client.post("/api/billing/webhook", content=b"{}", headers={"stripe-signature": "t"})
    assert resp.status_code == 200


def test_checkout_refuses_a_return_url_off_our_site(temp_db, monkeypatch):
    # Stripe sends the customer wherever these say. Before the host check any
    # account holder could mint a Stripe-branded checkout that landed on a
    # site of their choosing.
    user = _make_user("redirect@example.com")
    captured = _patch_session_create(monkeypatch)
    client = _make_client(temp_db, user["id"])

    resp = client.post(
        "/api/billing/checkout-session",
        json=_checkout_body("individual", success_url="https://evil.example/phish"),
    )
    assert resp.status_code == 400
    assert "success_url" in resp.json()["detail"]
    assert not captured, "the Stripe session must not have been created"

    resp = client.post(
        "/api/billing/checkout-session",
        json=_checkout_body("individual", cancel_url="javascript:alert(1)"),
    )
    assert resp.status_code == 400
    _clear_overrides()


def test_portal_refuses_a_return_url_off_our_site(temp_db, monkeypatch):
    user = _make_user("portalredirect@example.com")
    database.upsert_subscription(
        scope_type="user", scope_id=user["id"],
        stripe_subscription_id="sub_r", stripe_customer_id="cus_r",
        plan="individual", status="active", quantity=1,
        current_period_end="2026-09-01T00:00:00+00:00",
    )
    _patch_portal(monkeypatch)
    client = _make_client(temp_db, user["id"])

    resp = client.post("/api/billing/portal-session", json={"return_url": "https://evil.example/"})
    assert resp.status_code == 400
    _clear_overrides()

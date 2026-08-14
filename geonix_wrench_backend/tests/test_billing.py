from fastapi.testclient import TestClient

import auth
import billing
import database
from config import INDIVIDUAL_PRICE_ID, TEAM_PRICE_ID
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
        "success_url": "https://geonix.test/success",
        "cancel_url": "https://geonix.test/cancel",
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


def test_team_checkout_requires_an_organization(temp_db):
    owner = _make_user("teamnoorg@example.com")
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("team", quantity=3))
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

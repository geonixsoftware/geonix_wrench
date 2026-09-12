"""The server, not the app, decides whether an account has paid.

Before this the subscription gate lived only in the Flutter client. Every
route asked for nothing beyond a valid Firebase token — and signing up for one
is self-service — so anyone could call the transcription endpoint directly and
run Whisper and a paid model here without subscribing. These pin the routes
that cost money or produce the product to a 402 without a live subscription,
and keep the routes an unsubscribed account still needs (its profile, billing,
devices, the job cards it already has) open.
"""

import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import auth
import database
import logo_storage
from conftest import activate
from main import app


@pytest.fixture()
def storage_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(logo_storage, "LOGO_STORAGE_DIR", str(tmp_path))
    return tmp_path


def _client_as(user_id):
    app.dependency_overrides[auth.get_current_user] = lambda: database.get_user_by_id(user_id)
    return TestClient(app)


def _png():
    buffer = io.BytesIO()
    Image.new("RGB", (20, 20), "white").save(buffer, format="PNG")
    return buffer.getvalue()


@pytest.fixture()
def unpaid(temp_db, storage_dir):
    user = database.get_or_create_user(firebase_uid="uid-unpaid", email="unpaid@example.com")
    yield user
    app.dependency_overrides.clear()


def test_recording_requires_a_subscription(unpaid):
    resp = _client_as(unpaid["id"]).post(
        "/api/process-audio", files={"file": ("a.wav", b"RIFF....", "audio/wav")}
    )
    assert resp.status_code == 402
    assert "subscription" in resp.json()["detail"].lower()


def test_editing_and_exporting_require_a_subscription(unpaid):
    client = _client_as(unpaid["id"])
    assert client.patch("/api/jobcards/1", json={"labor_rate": 50.0}).status_code == 402
    assert client.get("/api/jobcards/1/pdf").status_code == 402


def test_logo_changes_require_a_subscription(unpaid):
    client = _client_as(unpaid["id"])
    resp = client.post("/api/shop-logo", files={"file": ("logo.png", _png(), "image/png")})
    assert resp.status_code == 402
    assert client.delete("/api/shop-logo").status_code == 402


def test_an_unpaid_account_can_still_reach_everything_else(unpaid):
    client = _client_as(unpaid["id"])
    assert client.get("/api/auth/me").status_code == 200
    assert client.get("/api/jobcards").status_code == 200
    assert client.get("/api/billing/status").status_code == 200
    assert client.get("/api/shop-logo/status").status_code == 200
    assert client.get("/api/shop-logo").status_code == 200


def test_paying_unlocks_the_gate(unpaid):
    activate(unpaid)
    client = _client_as(unpaid["id"])
    # 404, not 402: the gate is passed and the route runs (there is no card 1).
    assert client.patch("/api/jobcards/1", json={"labor_rate": 50.0}).status_code == 404
    resp = client.post("/api/shop-logo", files={"file": ("logo.png", _png(), "image/png")})
    assert resp.status_code == 200


def test_a_shop_member_is_covered_by_the_shop_subscription(temp_db, storage_dir):
    owner = database.get_or_create_user(firebase_uid="uid-pw-owner", email="pwowner@example.com")
    member = database.get_or_create_user(firebase_uid="uid-pw-member", email="pwmember@example.com")
    org = database.create_organization(owner["id"], "Paid Motors", 5)
    database.update_user_org(member["id"], org["id"], "member")
    try:
        assert _client_as(member["id"]).patch(
            "/api/jobcards/1", json={"labor_rate": 50.0}
        ).status_code == 402
        activate(database.get_user_by_id(owner["id"]))
        assert _client_as(member["id"]).patch(
            "/api/jobcards/1", json={"labor_rate": 50.0}
        ).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_a_lapsed_subscription_closes_the_gate_again(unpaid):
    activate(unpaid)
    database.upsert_subscription(
        scope_type="user", scope_id=unpaid["id"],
        stripe_subscription_id=None, stripe_customer_id=None,
        plan="individual", status="canceled", quantity=1,
        current_period_end=None,
    )
    assert _client_as(unpaid["id"]).get("/api/jobcards/1/pdf").status_code == 402


def test_negative_invoice_figures_are_refused(unpaid):
    activate(unpaid)
    client = _client_as(unpaid["id"])
    assert client.patch("/api/jobcards/1", json={"labor_rate": -5}).status_code == 422
    assert client.patch(
        "/api/jobcards/1",
        json={"parts_used": [{"part_name": "Oil", "quantity": -1}]},
    ).status_code == 422
    assert client.patch(
        "/api/jobcards/1",
        json={"parts_used": [{"part_name": "Oil", "quantity": 1, "unit_price": -3}]},
    ).status_code == 422
    assert client.get("/api/jobcards/1/pdf", headers={"X-Labor-Rate": "-1"}).status_code == 400

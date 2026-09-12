"""Who may change the logo a shop prints on its job cards.

Inside an organization the logo is one file shared by everyone — _logo_path
resolves every member to the same org_<id> file — so a member replacing it
replaced what appeared on every colleague's invoices, silently. Uploading and
removing are the owner's; seeing it is everyone's, because inheriting the
shop's logo is the point of being in a shop.
"""

import io
import pathlib

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import auth
import database
import logo_storage
from conftest import activate
from main import app
from scoping import OwnerScope


@pytest.fixture()
def storage_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(logo_storage, "LOGO_STORAGE_DIR", str(tmp_path))
    return tmp_path


def _client_as(user_id):
    app.dependency_overrides[auth.get_current_user] = lambda: database.get_user_by_id(user_id)
    return TestClient(app)


def _png(colour="white"):
    buffer = io.BytesIO()
    Image.new("RGB", (120, 40), colour).save(buffer, format="PNG")
    return buffer.getvalue()


def _upload(client, colour="white"):
    return client.post(
        "/api/shop-logo",
        files={"file": ("logo.png", _png(colour), "image/png")},
    )


@pytest.fixture()
def shop(temp_db, storage_dir):
    """An owner and a member in the same organization."""
    owner = database.get_or_create_user(firebase_uid="uid-owner", email="owner@shop.test")
    member = database.get_or_create_user(firebase_uid="uid-member", email="mech@shop.test")

    # create_organization already marks the creator as owner.
    org = database.create_organization(owner["id"], "Test Motors", 5)
    database.update_user_org(member["id"], org["id"], "member")
    activate(database.get_user_by_id(owner["id"]))

    yield {
        "owner": database.get_user_by_id(owner["id"]),
        "member": database.get_user_by_id(member["id"]),
        "org": org,
    }
    app.dependency_overrides.clear()


# ── 1. only the owner may change it ──────────────────────────────────────

def test_owner_can_upload(shop):
    assert _upload(_client_as(shop["owner"]["id"])).status_code == 200


def test_member_cannot_upload(shop):
    resp = _upload(_client_as(shop["member"]["id"]))
    assert resp.status_code == 403
    assert "owner" in resp.json()["detail"].lower()


def test_member_cannot_delete(shop):
    _upload(_client_as(shop["owner"]["id"]))
    resp = _client_as(shop["member"]["id"]).delete("/api/shop-logo")
    assert resp.status_code == 403


def test_a_refused_upload_does_not_overwrite_the_owners_logo(shop):
    _upload(_client_as(shop["owner"]["id"]), colour="red")
    scope = OwnerScope(org_id=shop["org"]["id"], user_id=shop["owner"]["id"])
    stored = logo_storage.get_active_logo_path(scope)
    original = pathlib.Path(stored).read_bytes()

    _upload(_client_as(shop["member"]["id"]), colour="black")

    assert pathlib.Path(stored).read_bytes() == original, "the member's upload landed anyway"


def test_a_solo_account_is_its_own_owner(temp_db, storage_dir):
    solo = database.get_or_create_user(firebase_uid="uid-solo", email="solo@example.com")
    activate(solo)
    try:
        assert _upload(_client_as(solo["id"])).status_code == 200
    finally:
        app.dependency_overrides.clear()


# ── 2. the UI is told, rather than guessing ──────────────────────────────

def test_status_tells_the_owner_they_may_manage_it(shop):
    body = _client_as(shop["owner"]["id"]).get("/api/shop-logo/status").json()
    assert body["can_manage"] is True


def test_status_tells_a_member_they_may_not(shop):
    body = _client_as(shop["member"]["id"]).get("/api/shop-logo/status").json()
    assert body["can_manage"] is False


def test_a_solo_account_may_manage_its_own(temp_db, storage_dir):
    solo = database.get_or_create_user(firebase_uid="uid-solo2", email="solo2@example.com")
    try:
        body = _client_as(solo["id"]).get("/api/shop-logo/status").json()
        assert body["can_manage"] is True
    finally:
        app.dependency_overrides.clear()


# ── 3. everyone in the shop inherits the owner's logo ────────────────────

def test_a_member_sees_the_logo_the_owner_uploaded(shop):
    _upload(_client_as(shop["owner"]["id"]), colour="red")

    member = _client_as(shop["member"]["id"])
    assert member.get("/api/shop-logo/status").json()["has_custom_logo"] is True

    resp = member.get("/api/shop-logo")
    assert resp.status_code == 200
    # Byte-identical to what the owner uploaded: the same file, not a copy that
    # could drift.
    owner_bytes = _client_as(shop["owner"]["id"]).get("/api/shop-logo").content
    assert resp.content == owner_bytes


def test_removing_it_removes_it_for_the_whole_shop(shop):
    _upload(_client_as(shop["owner"]["id"]))
    assert _client_as(shop["member"]["id"]).get("/api/shop-logo/status").json()["has_custom_logo"]

    _client_as(shop["owner"]["id"]).delete("/api/shop-logo")

    assert not _client_as(shop["member"]["id"]).get("/api/shop-logo/status").json()["has_custom_logo"]


def test_another_shop_does_not_see_this_one(temp_db, storage_dir):
    a_owner = database.get_or_create_user(firebase_uid="uid-a", email="a@shop.test")
    b_owner = database.get_or_create_user(firebase_uid="uid-b", email="b@shop.test")
    database.create_organization(a_owner["id"], "A Motors", 5)
    database.create_organization(b_owner["id"], "B Motors", 5)
    activate(database.get_user_by_id(a_owner["id"]))

    try:
        _upload(_client_as(a_owner["id"]))
        assert _client_as(b_owner["id"]).get("/api/shop-logo/status").json()["has_custom_logo"] is False
    finally:
        app.dependency_overrides.clear()


# ── 4. closing an account does not take the shop's logo with it ──────────

def test_a_member_closing_their_account_leaves_the_shop_logo(shop, monkeypatch):
    # delete_me used to call delete_shop_logo on the caller's owner scope, and
    # a member's scope *is* the shop — so an employee exercising their right
    # to erasure erased the branding from every colleague's invoices.
    import main as main_module

    monkeypatch.setattr(main_module, "delete_firebase_user", lambda uid: None)
    _upload(_client_as(shop["owner"]["id"]))
    assert logo_storage.has_custom_logo(
        OwnerScope(org_id=shop["org"]["id"], user_id=shop["owner"]["id"])
    )

    resp = _client_as(shop["member"]["id"]).delete("/api/auth/me")
    assert resp.status_code == 204

    assert logo_storage.has_custom_logo(
        OwnerScope(org_id=shop["org"]["id"], user_id=shop["owner"]["id"])
    )


def test_a_solo_account_closing_takes_its_own_logo(temp_db, storage_dir, monkeypatch):
    import main as main_module

    monkeypatch.setattr(main_module, "delete_firebase_user", lambda uid: None)
    solo = database.get_or_create_user(firebase_uid="uid-solo-del", email="solodel@example.com")
    activate(solo)
    try:
        _upload(_client_as(solo["id"]))
        scope = OwnerScope(org_id=None, user_id=solo["id"])
        assert logo_storage.has_custom_logo(scope)
        assert _client_as(solo["id"]).delete("/api/auth/me").status_code == 204
        assert not logo_storage.has_custom_logo(scope)
    finally:
        app.dependency_overrides.clear()

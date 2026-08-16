from fastapi.testclient import TestClient

import auth
import database
from config import TEAM_MIN_SEATS
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


def test_handle_claim_success_and_taken(temp_db):
    u1 = _make_user("route1@example.com")
    u2 = _make_user("route2@example.com")

    client = _make_client(temp_db, u1["id"])
    resp = client.post("/api/auth/handle", json={"handle": "Wrenchmaster"})
    assert resp.status_code == 200
    assert resp.json()["handle"] == "wrenchmaster"

    app.dependency_overrides[auth.get_current_user] = _override_for(u2["id"])
    resp2 = client.post("/api/auth/handle", json={"handle": "wrenchmaster"})
    assert resp2.status_code == 409

    app.dependency_overrides.clear()


def test_create_organization_route(temp_db):
    owner = _make_user("orgroute@example.com")
    client = _make_client(temp_db, owner["id"])

    # seat_limit is deliberately ignored if sent: the shop gets the seats its
    # owner paid for, and with no Team subscription that is the plan minimum.
    resp = client.post("/api/organizations", json={"name": "Route Shop", "seat_limit": 3})
    assert resp.status_code == 200
    body = resp.json()
    assert body["name"] == "Route Shop"
    assert body["seat_used"] == 1
    assert body["seat_limit"] == TEAM_MIN_SEATS

    resp2 = client.get("/api/organizations/me")
    assert resp2.status_code == 200
    assert resp2.json()["id"] == body["id"]

    app.dependency_overrides.clear()


def test_invite_and_accept_flow(temp_db):
    owner = _make_user("inviteowner@example.com")
    invitee = _make_user("invitee@example.com")
    database.set_user_handle(invitee["id"], "mechanic1")

    client = _make_client(temp_db, owner["id"])
    org_resp = client.post("/api/organizations", json={"name": "Invite Shop", "seat_limit": 2})
    org_id = org_resp.json()["id"]

    invite_resp = client.post(f"/api/organizations/{org_id}/invites", json={"handle": "mechanic1"})
    assert invite_resp.status_code == 200
    invite_id = invite_resp.json()["id"]

    dup_resp = client.post(f"/api/organizations/{org_id}/invites", json={"handle": "mechanic1"})
    assert dup_resp.status_code == 409

    app.dependency_overrides[auth.get_current_user] = _override_for(invitee["id"])
    my_invites = client.get("/api/invites/me")
    assert len(my_invites.json()) == 1

    accept_resp = client.post(f"/api/invites/{invite_id}/accept")
    assert accept_resp.status_code == 200
    assert accept_resp.json()["org_id"] == org_id
    assert accept_resp.json()["org_role"] == "member"

    app.dependency_overrides.clear()


def test_jobcards_list_scoping_via_two_users(temp_db):
    u1 = _make_user("jc1@example.com")
    u2 = _make_user("jc2@example.com")

    client = _make_client(temp_db, u1["id"])
    resp = client.patch("/api/jobcards/1", json={"labor_rate": 50.0})
    assert resp.status_code == 404

    from schemas import JobCardExtraction
    from scoping import OwnerScope

    extraction = JobCardExtraction(vehicle_info="Truck", labor_hours=1.0, work_performed="Tires")
    database.insert_jobcard(extraction, "t1", OwnerScope(org_id=None, user_id=u1["id"]))
    database.insert_jobcard(extraction, "t2", OwnerScope(org_id=None, user_id=u2["id"]))

    resp1 = client.get("/api/jobcards")
    assert resp1.status_code == 200
    assert len(resp1.json()) == 1
    assert resp1.json()[0]["transcript"] == "t1"

    app.dependency_overrides[auth.get_current_user] = _override_for(u2["id"])
    resp2 = client.get("/api/jobcards")
    assert resp2.status_code == 200
    assert len(resp2.json()) == 1
    assert resp2.json()[0]["transcript"] == "t2"

    app.dependency_overrides.clear()


def test_unauthenticated_request_rejected(temp_db):
    app.dependency_overrides.clear()
    client = TestClient(app)
    resp = client.get("/api/jobcards")
    assert resp.status_code in (401, 403)

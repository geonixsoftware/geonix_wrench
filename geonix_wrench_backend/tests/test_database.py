import pytest

import database
from scoping import OwnerScope


def test_init_db_twice_is_idempotent(temp_db):
    database.init_db()

    with database.get_connection() as conn:
        tables = {
            row["name"]
            for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall()
        }
        assert {"jobcards", "users", "organizations", "invites"} <= tables

        columns = {row["name"] for row in conn.execute("PRAGMA table_info(jobcards)").fetchall()}
        assert {"user_id", "org_id", "labor_rate"} <= columns


def _make_user(temp_db, email="user@example.com"):
    return database.get_or_create_user(firebase_uid=f"uid-{email}", email=email)


def test_get_or_create_user_is_idempotent(temp_db):
    first = database.get_or_create_user(firebase_uid="uid-1", email="a@example.com")
    second = database.get_or_create_user(firebase_uid="uid-1", email="a@example.com")
    assert first["id"] == second["id"]


def test_set_user_handle_rejects_duplicate(temp_db):
    u1 = _make_user(temp_db, "one@example.com")
    u2 = _make_user(temp_db, "two@example.com")

    database.set_user_handle(u1["id"], "sparky")
    with pytest.raises(database.HandleTakenError):
        database.set_user_handle(u2["id"], "sparky")


def test_jobcards_scoping_between_personal_users(temp_db):
    from schemas import JobCardExtraction

    u1 = _make_user(temp_db, "p1@example.com")
    u2 = _make_user(temp_db, "p2@example.com")
    owner1 = OwnerScope(org_id=None, user_id=u1["id"])
    owner2 = OwnerScope(org_id=None, user_id=u2["id"])

    extraction = JobCardExtraction(
        vehicle_info="2020 Civic",
        labor_hours=1.5,
        work_performed="Oil change",
    )
    database.insert_jobcard(extraction, "transcript one", owner1)
    database.insert_jobcard(extraction, "transcript two", owner2)

    cards1 = database.list_jobcards(owner1)
    cards2 = database.list_jobcards(owner2)

    assert len(cards1) == 1
    assert len(cards2) == 1
    assert cards1[0]["transcript"] == "transcript one"
    assert cards2[0]["transcript"] == "transcript two"


def test_jobcards_shared_within_org(temp_db):
    from schemas import JobCardExtraction

    owner_user = _make_user(temp_db, "owner@example.com")
    member_user = _make_user(temp_db, "member@example.com")
    org = database.create_organization(owner_user["id"], "Bob's Shop", seat_limit=5)
    database.update_user_org(member_user["id"], org["id"], "member")

    owner_scope = OwnerScope(org_id=org["id"], user_id=owner_user["id"])
    member_scope = OwnerScope(org_id=org["id"], user_id=member_user["id"])

    extraction = JobCardExtraction(vehicle_info="2021 CR-V", labor_hours=2.0, work_performed="Brakes")
    database.insert_jobcard(extraction, "org transcript", owner_scope)

    assert len(database.list_jobcards(owner_scope)) == 1
    assert len(database.list_jobcards(member_scope)) == 1


def test_create_organization_rejects_if_already_in_org(temp_db):
    owner_user = _make_user(temp_db, "owner2@example.com")
    database.create_organization(owner_user["id"], "Shop A", seat_limit=2)
    with pytest.raises(database.AlreadyInOrgError):
        database.create_organization(owner_user["id"], "Shop B", seat_limit=2)


def test_seat_limit_invite_state_machine(temp_db):
    owner = _make_user(temp_db, "owner3@example.com")
    second = _make_user(temp_db, "second@example.com")
    third = _make_user(temp_db, "third@example.com")

    # seat_limit counts every org member including the owner (count_org_members
    # queries users WHERE org_id = ?), so the owner already occupies one seat;
    # seat_limit=2 is the smallest value that leaves room for exactly one invite.
    org = database.create_organization(owner["id"], "One Free Seat Shop", seat_limit=2)

    invite = database.create_invite(org["id"], second["id"], owner["id"])
    database.respond_to_invite(invite["id"], accept=True)
    assert database.count_org_members(org["id"]) == 2

    invite2 = database.create_invite(org["id"], third["id"], owner["id"])
    with pytest.raises(database.OrgFullError):
        database.respond_to_invite(invite2["id"], accept=True)


def test_duplicate_pending_invite_rejected(temp_db):
    owner = _make_user(temp_db, "owner4@example.com")
    target = _make_user(temp_db, "target@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=5)

    database.create_invite(org["id"], target["id"], owner["id"])
    with pytest.raises(database.DuplicateInviteError):
        database.create_invite(org["id"], target["id"], owner["id"])


def test_owner_cannot_leave(temp_db):
    owner = _make_user(temp_db, "owner5@example.com")
    database.create_organization(owner["id"], "Shop", seat_limit=5)

    with pytest.raises(database.OwnerCannotLeaveError):
        database.leave_organization(owner["id"])


def test_member_can_leave(temp_db):
    owner = _make_user(temp_db, "owner5b@example.com")
    member = _make_user(temp_db, "member5b@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=5)
    invite = database.create_invite(org["id"], member["id"], owner["id"])
    database.respond_to_invite(invite["id"], accept=True)

    database.leave_organization(member["id"])
    assert database.get_user_by_id(member["id"])["org_id"] is None


def test_kick_member_frees_seat(temp_db):
    owner = _make_user(temp_db, "owner6@example.com")
    member = _make_user(temp_db, "member6@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=2)
    invite = database.create_invite(org["id"], member["id"], owner["id"])
    database.respond_to_invite(invite["id"], accept=True)

    assert database.count_org_members(org["id"]) == 2
    database.remove_org_member(org["id"], member["id"])
    assert database.count_org_members(org["id"]) == 1


def test_remove_org_member_rejects_non_member(temp_db):
    owner = _make_user(temp_db, "owner7@example.com")
    outsider = _make_user(temp_db, "outsider7@example.com")
    org = database.create_organization(owner["id"], "Shop", seat_limit=5)

    with pytest.raises(database.NotOrgMemberError):
        database.remove_org_member(org["id"], outsider["id"])

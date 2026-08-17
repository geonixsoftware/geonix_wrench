"""Account deletion.

There was no way to close an account, which blocks an App Store listing and
fails GDPR's right to erasure — and the product is priced in EUR for European
shops, so both apply.

Deletion is the one operation that cannot be undone, so what it refuses matters
as much as what it removes: taking a shop out from under the mechanics still
working in it would destroy other people's data, not just the caller's.
"""

import pytest

import database
from scoping import OwnerScope
from schemas import JobCardExtraction


def _extraction(vehicle="VW Golf"):
    return JobCardExtraction(
        vehicle_info=vehicle,
        labor_hours=1.0,
        work_performed="Oil change",
        parts_used=[],
        unbilled_items_flagged=[],
    )


def _user(email="a@example.com", uid=None):
    return database.get_or_create_user(uid or f"uid-{email}", email)


def test_deletes_the_user_and_their_personal_jobcards(temp_db):
    user = _user()
    scope = OwnerScope(org_id=None, user_id=user["id"])
    database.insert_jobcard(_extraction(), "said out loud", scope)
    database.insert_jobcard(_extraction("Ford"), "also said", scope)

    summary = database.delete_user_account(user["id"])

    assert summary["jobcards"] == 2
    assert database.get_user_by_id(user["id"]) is None
    # The transcript is the most personal field in the product, so "gone" has to
    # mean gone rather than orphaned.
    assert database.list_jobcards(scope) == []


def test_unknown_user_is_reported_not_silently_ignored(temp_db):
    with pytest.raises(database.UserNotFoundError):
        database.delete_user_account(99999)


def test_owner_of_a_shop_with_other_members_is_refused(temp_db):
    owner = _user("owner@example.com")
    member = _user("member@example.com")
    org = database.create_organization(owner["id"], "Shop", 5)
    database.update_user_org(member["id"], org["id"], "member")

    with pytest.raises(database.OwnerMustDeleteOrgError):
        database.delete_user_account(owner["id"])

    # Nothing partially applied: the refusal happens before any delete runs.
    assert database.get_user_by_id(owner["id"]) is not None
    assert database.get_organization(org["id"]) is not None
    assert database.get_user_by_id(member["id"])["org_id"] == org["id"]


def test_sole_owner_takes_the_empty_shop_with_them(temp_db):
    owner = _user("solo@example.com")
    org = database.create_organization(owner["id"], "One-man shop", 2)

    summary = database.delete_user_account(owner["id"])

    # There is nobody left for the shop to belong to.
    assert summary["org_id"] == org["id"]
    assert database.get_organization(org["id"]) is None


def test_org_jobcards_go_with_the_shop(temp_db):
    owner = _user("owner2@example.com")
    org = database.create_organization(owner["id"], "Shop", 3)
    org_scope = OwnerScope(org_id=org["id"], user_id=owner["id"])
    database.insert_jobcard(_extraction(), "shop work", org_scope)

    summary = database.delete_user_account(owner["id"])

    assert summary["jobcards"] == 1
    assert database.list_jobcards(org_scope) == []


def test_a_members_deletion_leaves_the_shop_standing(temp_db):
    owner = _user("owner3@example.com")
    member = _user("member3@example.com")
    org = database.create_organization(owner["id"], "Shop", 5)
    database.update_user_org(member["id"], org["id"], "member")
    org_scope = OwnerScope(org_id=org["id"], user_id=owner["id"])
    database.insert_jobcard(_extraction(), "shop work", org_scope)

    database.delete_user_account(member["id"])

    # The shop's own job cards belong to the business, not to whoever dictated
    # them, so a member leaving must not erase the shop's records.
    assert database.get_user_by_id(member["id"]) is None
    assert database.get_organization(org["id"]) is not None
    assert len(database.list_jobcards(org_scope)) == 1


def test_invites_in_both_directions_are_cleared(temp_db):
    owner = _user("owner4@example.com")
    invitee = _user("invitee@example.com")
    org = database.create_organization(owner["id"], "Shop", 5)
    database.create_invite(org["id"], invitee["id"], owner["id"])

    database.delete_user_account(invitee["id"])

    # A pending invite naming a deleted user would otherwise sit in the owner's
    # list forever, unacceptable and unremovable.
    assert database.list_pending_invites_for_org(org["id"]) == []


def test_the_subscription_record_goes_too(temp_db):
    user = _user("payer@example.com")
    database.upsert_subscription(
        scope_type="user",
        scope_id=user["id"],
        stripe_subscription_id="sub_123",
        stripe_customer_id="cus_123",
        plan="individual",
        status="active",
        quantity=1,
        current_period_end=None,
    )

    database.delete_user_account(user["id"])

    assert database.get_subscription("user", user["id"]) is None


def test_a_freed_handle_can_be_claimed_again(temp_db):
    first = _user("first@example.com")
    database.set_user_handle(first["id"], "sharedhandle")
    database.delete_user_account(first["id"])

    # The handle is UNIQUE, so a row left behind would permanently reserve a
    # name nobody owns.
    second = _user("second@example.com")
    database.set_user_handle(second["id"], "sharedhandle")
    assert database.get_user_by_handle("sharedhandle")["id"] == second["id"]

"""A closed account stays closed, even with a token issued before the closure.

Deleting the Firebase identity does not invalidate an ID token already in the
caller's hands — it stays cryptographically valid until it expires, up to an
hour later. get_or_create_user creates on miss, so any request made in that
window put the row straight back: the account returned, carrying the email
address of somebody who had just asked to be erased.
"""

from datetime import datetime, timedelta, timezone

import pytest

import database
from database import AccountDeletedError, get_or_create_user, delete_user_account


def test_a_deleted_account_is_not_recreated_by_a_stale_token(temp_db):
    user = get_or_create_user(firebase_uid="uid-alice", email="alice@example.com")
    delete_user_account(user["id"])

    # Exactly what a request carrying the old token does.
    with pytest.raises(AccountDeletedError):
        get_or_create_user(firebase_uid="uid-alice", email="alice@example.com")


def test_the_email_is_not_written_back(temp_db):
    user = get_or_create_user(firebase_uid="uid-bob", email="bob@example.com")
    delete_user_account(user["id"])

    try:
        get_or_create_user(firebase_uid="uid-bob", email="bob@example.com")
    except AccountDeletedError:
        pass

    with database.get_connection() as conn:
        rows = conn.execute(
            "SELECT COUNT(*) AS c FROM users WHERE email = ?", ("bob@example.com",)
        ).fetchone()["c"]
    assert rows == 0, "the erased email came back"


def test_the_raw_uid_is_not_kept(temp_db):
    user = get_or_create_user(firebase_uid="uid-carol", email="carol@example.com")
    delete_user_account(user["id"])

    # Enforcing the erasure must not itself retain the identifier.
    with database.get_connection() as conn:
        stored = [r["uid_hash"] for r in conn.execute("SELECT uid_hash FROM deleted_accounts")]
    assert stored, "no tombstone written"
    assert "uid-carol" not in stored
    assert all(len(h) == 64 for h in stored), "expected sha256 hex"


def test_other_accounts_are_unaffected(temp_db):
    keep = get_or_create_user(firebase_uid="uid-keep", email="keep@example.com")
    drop = get_or_create_user(firebase_uid="uid-drop", email="drop@example.com")
    delete_user_account(drop["id"])

    again = get_or_create_user(firebase_uid="uid-keep", email="keep@example.com")
    assert again["id"] == keep["id"]


def test_a_brand_new_signup_is_never_blocked(temp_db):
    user = get_or_create_user(firebase_uid="uid-old", email="dave@example.com")
    delete_user_account(user["id"])

    # Signing up again mints a new Firebase identity, so the same person with a
    # new uid gets a fresh account rather than being locked out.
    fresh = get_or_create_user(firebase_uid="uid-new", email="dave@example.com")
    assert fresh["id"] is not None


def test_the_tombstone_expires(temp_db):
    user = get_or_create_user(firebase_uid="uid-eve", email="eve@example.com")
    delete_user_account(user["id"])

    # Age it past the window. Any token from before the deletion is long dead
    # by now, so the record has done its job and should not linger.
    stale = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()
    with database.get_connection() as conn:
        conn.execute("UPDATE deleted_accounts SET deleted_at = ?", (stale,))
        conn.commit()

    revived = get_or_create_user(firebase_uid="uid-eve", email="eve@example.com")
    assert revived["id"] is not None

    with database.get_connection() as conn:
        left = conn.execute("SELECT COUNT(*) AS c FROM deleted_accounts").fetchone()["c"]
    assert left == 0, "expired tombstones should be pruned"

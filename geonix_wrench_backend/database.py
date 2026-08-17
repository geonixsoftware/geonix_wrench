import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

from config import DB_PATH
from schemas import JobCardExtraction, JobCardUpdate
from scoping import OwnerScope


class HandleTakenError(Exception):
    pass


class DuplicateInviteError(Exception):
    pass


class OrgFullError(Exception):
    pass


class AlreadyInOrgError(Exception):
    pass


class NotOrgMemberError(Exception):
    pass


class UserNotFoundError(Exception):
    pass


class OwnerMustDeleteOrgError(Exception):
    """The account owns a shop that still has other members in it."""


class OwnerCannotLeaveError(Exception):
    pass


def init_db() -> None:
    with get_connection() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS jobcards (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TEXT NOT NULL,
                vehicle_info TEXT NOT NULL,
                labor_hours REAL NOT NULL,
                work_performed TEXT NOT NULL,
                parts_used TEXT NOT NULL,
                unbilled_items_flagged TEXT NOT NULL,
                transcript TEXT NOT NULL
            )
            """
        )
        try:
            conn.execute("ALTER TABLE jobcards ADD COLUMN labor_rate REAL")
        except sqlite3.OperationalError:
            pass
        try:
            conn.execute("ALTER TABLE jobcards ADD COLUMN user_id INTEGER")
        except sqlite3.OperationalError:
            pass
        try:
            conn.execute("ALTER TABLE jobcards ADD COLUMN org_id INTEGER")
        except sqlite3.OperationalError:
            pass

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                firebase_uid TEXT NOT NULL UNIQUE,
                email TEXT NOT NULL,
                handle TEXT UNIQUE,
                display_name TEXT,
                org_id INTEGER,
                org_role TEXT CHECK (org_role IN ('owner', 'member')),
                created_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS organizations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                owner_user_id INTEGER NOT NULL,
                seat_limit INTEGER NOT NULL,
                created_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS invites (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                org_id INTEGER NOT NULL,
                invited_user_id INTEGER NOT NULL,
                invited_by_user_id INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'revoked')),
                created_at TEXT NOT NULL,
                responded_at TEXT
            )
            """
        )
        conn.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS ux_invites_pending_target
                ON invites(org_id, invited_user_id)
                WHERE status = 'pending'
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS subscriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scope_type TEXT NOT NULL CHECK (scope_type IN ('user', 'org')),
                scope_id INTEGER NOT NULL,
                stripe_subscription_id TEXT,
                stripe_customer_id TEXT,
                plan TEXT NOT NULL,
                status TEXT NOT NULL,
                quantity INTEGER,
                current_period_end TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE (scope_type, scope_id)
            )
            """
        )
        conn.commit()


@contextmanager
def get_connection():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def _scope_clause(owner: OwnerScope) -> Tuple[str, List[Any]]:
    if owner.org_id is not None:
        return "org_id = ?", [owner.org_id]
    return "org_id IS NULL AND user_id = ?", [owner.user_id]


def insert_jobcard(extraction: JobCardExtraction, transcript: str, owner: OwnerScope) -> int:
    with get_connection() as conn:
        cursor = conn.execute(
            """
            INSERT INTO jobcards
                (created_at, vehicle_info, labor_hours, work_performed, parts_used, unbilled_items_flagged, transcript, user_id, org_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                datetime.now(timezone.utc).isoformat(),
                extraction.vehicle_info,
                extraction.labor_hours,
                extraction.work_performed,
                json.dumps([p.model_dump() for p in extraction.parts_used]),
                json.dumps(extraction.unbilled_items_flagged),
                transcript,
                owner.user_id,
                owner.org_id,
            ),
        )
        conn.commit()
        return cursor.lastrowid


def _row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    return {
        "id": row["id"],
        "created_at": row["created_at"],
        "vehicle_info": row["vehicle_info"],
        "labor_hours": row["labor_hours"],
        "labor_rate": row["labor_rate"],
        "work_performed": row["work_performed"],
        "parts_used": json.loads(row["parts_used"]),
        "unbilled_items_flagged": json.loads(row["unbilled_items_flagged"]),
        "transcript": row["transcript"],
    }


def update_jobcard(jobcard_id: int, update: JobCardUpdate, owner: OwnerScope) -> Optional[Dict[str, Any]]:
    fields = []
    values: List[Any] = []
    if update.labor_rate is not None:
        fields.append("labor_rate = ?")
        values.append(update.labor_rate)
    if update.parts_used is not None:
        fields.append("parts_used = ?")
        values.append(json.dumps([p.model_dump() for p in update.parts_used]))

    if not fields:
        return get_jobcard(jobcard_id, owner)

    scope_sql, scope_values = _scope_clause(owner)
    values.append(jobcard_id)
    with get_connection() as conn:
        conn.execute(
            f"UPDATE jobcards SET {', '.join(fields)} WHERE id = ? AND {scope_sql}",
            values + scope_values,
        )
        conn.commit()
    return get_jobcard(jobcard_id, owner)


def list_jobcards(owner: OwnerScope) -> List[Dict[str, Any]]:
    scope_sql, scope_values = _scope_clause(owner)
    with get_connection() as conn:
        rows = conn.execute(
            f"SELECT * FROM jobcards WHERE {scope_sql} ORDER BY id DESC", scope_values
        ).fetchall()
        return [_row_to_dict(r) for r in rows]


def get_jobcard(jobcard_id: int, owner: OwnerScope) -> Optional[Dict[str, Any]]:
    scope_sql, scope_values = _scope_clause(owner)
    with get_connection() as conn:
        row = conn.execute(
            f"SELECT * FROM jobcards WHERE id = ? AND {scope_sql}", [jobcard_id, *scope_values]
        ).fetchone()
        return _row_to_dict(row) if row else None


def _user_row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    return {
        "id": row["id"],
        "firebase_uid": row["firebase_uid"],
        "email": row["email"],
        "handle": row["handle"],
        "display_name": row["display_name"],
        "org_id": row["org_id"],
        "org_role": row["org_role"],
        "created_at": row["created_at"],
    }


def get_or_create_user(firebase_uid: str, email: str) -> Dict[str, Any]:
    with get_connection() as conn:
        row = conn.execute("SELECT * FROM users WHERE firebase_uid = ?", (firebase_uid,)).fetchone()
        if row:
            return _user_row_to_dict(row)

        cursor = conn.execute(
            "INSERT INTO users (firebase_uid, email, created_at) VALUES (?, ?, ?)",
            (firebase_uid, email, datetime.now(timezone.utc).isoformat()),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM users WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return _user_row_to_dict(row)


def get_user_by_id(user_id: int) -> Optional[Dict[str, Any]]:
    with get_connection() as conn:
        row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
        return _user_row_to_dict(row) if row else None


def get_user_by_handle(handle: str) -> Optional[Dict[str, Any]]:
    with get_connection() as conn:
        row = conn.execute("SELECT * FROM users WHERE handle = ?", (handle,)).fetchone()
        return _user_row_to_dict(row) if row else None


def set_user_handle(user_id: int, handle: str) -> Dict[str, Any]:
    with get_connection() as conn:
        existing = conn.execute(
            "SELECT id FROM users WHERE handle = ? AND id != ?", (handle, user_id)
        ).fetchone()
        if existing:
            raise HandleTakenError(f"Handle '{handle}' is already taken")

        try:
            conn.execute("UPDATE users SET handle = ? WHERE id = ?", (handle, user_id))
            conn.commit()
        except sqlite3.IntegrityError:
            raise HandleTakenError(f"Handle '{handle}' is already taken") from None

        row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
        return _user_row_to_dict(row)


def update_user_org(user_id: int, org_id: Optional[int], org_role: Optional[str]) -> None:
    with get_connection() as conn:
        conn.execute(
            "UPDATE users SET org_id = ?, org_role = ? WHERE id = ?", (org_id, org_role, user_id)
        )
        conn.commit()


def leave_organization(user_id: int) -> None:
    with get_connection() as conn:
        row = conn.execute("SELECT org_id, org_role FROM users WHERE id = ?", (user_id,)).fetchone()
        if row is None or row["org_id"] is None:
            raise NotOrgMemberError("User is not a member of any organization")
        if row["org_role"] == "owner":
            raise OwnerCannotLeaveError("Owner cannot leave the organization; delete it instead")

        conn.execute("UPDATE users SET org_id = NULL, org_role = NULL WHERE id = ?", (user_id,))
        conn.commit()


def remove_org_member(org_id: int, user_id: int) -> None:
    with get_connection() as conn:
        row = conn.execute("SELECT org_id FROM users WHERE id = ?", (user_id,)).fetchone()
        if row is None or row["org_id"] != org_id:
            raise NotOrgMemberError("User is not a member of this organization")

        conn.execute("UPDATE users SET org_id = NULL, org_role = NULL WHERE id = ?", (user_id,))
        conn.commit()


def delete_user_account(user_id: int) -> Dict[str, Any]:
    """Erase a user and everything of theirs, in one transaction.

    GDPR calls this the right to erasure, and the App Store refuses a listing
    with accounts but no way to close one. Both want the data actually gone
    rather than flagged deleted, so this is a real DELETE.

    Refuses when the user owns a shop that other people are still in: dropping
    it would silently take away another mechanic's workplace and their access to
    the job cards in it. The owner deletes or hands over the shop first, which
    the Organization screen already supports. A shop with nobody but the owner
    left in it is removed here, since there is no one for it to belong to.

    Returns a summary of what was erased so the caller can log the shape of the
    deletion without holding on to the contents.
    """
    with get_connection() as conn:
        user = conn.execute(
            "SELECT id, org_id, org_role FROM users WHERE id = ?", (user_id,)
        ).fetchone()
        if user is None:
            raise UserNotFoundError(f"No user with id {user_id}")

        org_id = user["org_id"]
        if org_id is not None and user["org_role"] == "owner":
            others = conn.execute(
                "SELECT COUNT(*) AS c FROM users WHERE org_id = ? AND id != ?",
                (org_id, user_id),
            ).fetchone()["c"]
            if others:
                raise OwnerMustDeleteOrgError(
                    "Remove the other members from your shop, or hand it over, "
                    "before deleting your account"
                )

        # Job cards carry the transcript of what the mechanic said, so they are
        # the most personal thing here. Personal-scope cards go unconditionally;
        # org-scope cards go only with the shop, because they belong to the
        # business rather than to whoever dictated them.
        deleted_jobcards = conn.execute(
            "DELETE FROM jobcards WHERE user_id = ? AND org_id IS NULL", (user_id,)
        ).rowcount

        conn.execute(
            "DELETE FROM invites WHERE invited_user_id = ? OR invited_by_user_id = ?",
            (user_id, user_id),
        )
        conn.execute(
            "DELETE FROM subscriptions WHERE scope_type = 'user' AND scope_id = ?", (user_id,)
        )

        deleted_org = None
        if org_id is not None and user["org_role"] == "owner":
            deleted_org = org_id
            deleted_jobcards += conn.execute(
                "DELETE FROM jobcards WHERE org_id = ?", (org_id,)
            ).rowcount
            conn.execute("DELETE FROM invites WHERE org_id = ?", (org_id,))
            conn.execute(
                "DELETE FROM subscriptions WHERE scope_type = 'org' AND scope_id = ?", (org_id,)
            )
            conn.execute("DELETE FROM organizations WHERE id = ?", (org_id,))

        conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
        conn.commit()

    return {"jobcards": deleted_jobcards, "org_id": deleted_org}


def _org_row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    return {
        "id": row["id"],
        "name": row["name"],
        "owner_user_id": row["owner_user_id"],
        "seat_limit": row["seat_limit"],
        "created_at": row["created_at"],
    }


def create_organization(owner_user_id: int, name: str, seat_limit: int) -> Dict[str, Any]:
    with get_connection() as conn:
        owner = conn.execute("SELECT org_id FROM users WHERE id = ?", (owner_user_id,)).fetchone()
        if owner is not None and owner["org_id"] is not None:
            raise AlreadyInOrgError("User already belongs to an organization")

        cursor = conn.execute(
            "INSERT INTO organizations (name, owner_user_id, seat_limit, created_at) VALUES (?, ?, ?, ?)",
            (name, owner_user_id, seat_limit, datetime.now(timezone.utc).isoformat()),
        )
        org_id = cursor.lastrowid
        conn.execute(
            "UPDATE users SET org_id = ?, org_role = ? WHERE id = ?", (org_id, "owner", owner_user_id)
        )
        conn.commit()

        row = conn.execute("SELECT * FROM organizations WHERE id = ?", (org_id,)).fetchone()
        return _org_row_to_dict(row)


def get_organization(org_id: int) -> Optional[Dict[str, Any]]:
    with get_connection() as conn:
        row = conn.execute("SELECT * FROM organizations WHERE id = ?", (org_id,)).fetchone()
        return _org_row_to_dict(row) if row else None


def delete_organization(org_id: int) -> None:
    with get_connection() as conn:
        conn.execute(
            "UPDATE users SET org_id = NULL, org_role = NULL WHERE org_id = ?", (org_id,)
        )
        conn.execute("DELETE FROM invites WHERE org_id = ?", (org_id,))
        conn.execute("DELETE FROM organizations WHERE id = ?", (org_id,))
        conn.commit()


def count_org_members(org_id: int) -> int:
    with get_connection() as conn:
        row = conn.execute("SELECT COUNT(*) AS c FROM users WHERE org_id = ?", (org_id,)).fetchone()
        return row["c"]


def set_org_seat_limit(org_id: int, seat_limit: int) -> None:
    with get_connection() as conn:
        conn.execute(
            "UPDATE organizations SET seat_limit = ? WHERE id = ?", (seat_limit, org_id)
        )
        conn.commit()


def _subscription_row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    return {
        "id": row["id"],
        "scope_type": row["scope_type"],
        "scope_id": row["scope_id"],
        "stripe_subscription_id": row["stripe_subscription_id"],
        "stripe_customer_id": row["stripe_customer_id"],
        "plan": row["plan"],
        "status": row["status"],
        "quantity": row["quantity"],
        "current_period_end": row["current_period_end"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def get_subscription(scope_type: str, scope_id: int) -> Optional[Dict[str, Any]]:
    with get_connection() as conn:
        row = conn.execute(
            "SELECT * FROM subscriptions WHERE scope_type = ? AND scope_id = ?",
            (scope_type, scope_id),
        ).fetchone()
        return _subscription_row_to_dict(row) if row else None


def move_subscription_scope(
    *,
    from_scope_type: str,
    from_scope_id: int,
    to_scope_type: str,
    to_scope_id: int,
) -> Optional[Dict[str, Any]]:
    """Re-point an existing subscription at a different scope.

    The Team plan can be bought before the shop exists, in which case the
    subscription is held against the buyer. Naming the shop moves that same
    Stripe subscription onto the org so seats, the billing portal and the
    member limit all resolve against the shop from then on.
    """
    with get_connection() as conn:
        # (scope_type, scope_id) is unique; clear any stale row at the target
        # so the move cannot violate the constraint.
        conn.execute(
            "DELETE FROM subscriptions WHERE scope_type = ? AND scope_id = ?",
            (to_scope_type, to_scope_id),
        )
        conn.execute(
            """
            UPDATE subscriptions
               SET scope_type = ?, scope_id = ?, updated_at = ?
             WHERE scope_type = ? AND scope_id = ?
            """,
            (
                to_scope_type,
                to_scope_id,
                datetime.now(timezone.utc).isoformat(),
                from_scope_type,
                from_scope_id,
            ),
        )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM subscriptions WHERE scope_type = ? AND scope_id = ?",
            (to_scope_type, to_scope_id),
        ).fetchone()
        return _subscription_row_to_dict(row) if row else None


def upsert_subscription(
    *,
    scope_type: str,
    scope_id: int,
    stripe_subscription_id: Optional[str],
    stripe_customer_id: Optional[str],
    plan: str,
    status: str,
    quantity: Optional[int],
    current_period_end: Optional[str],
) -> Dict[str, Any]:
    now = datetime.now(timezone.utc).isoformat()
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO subscriptions (
                scope_type, scope_id, stripe_subscription_id, stripe_customer_id,
                plan, status, quantity, current_period_end, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(scope_type, scope_id) DO UPDATE SET
                stripe_subscription_id = excluded.stripe_subscription_id,
                stripe_customer_id = excluded.stripe_customer_id,
                plan = excluded.plan,
                status = excluded.status,
                quantity = excluded.quantity,
                current_period_end = excluded.current_period_end,
                updated_at = excluded.updated_at
            """,
            (
                scope_type,
                scope_id,
                stripe_subscription_id,
                stripe_customer_id,
                plan,
                status,
                quantity,
                current_period_end,
                now,
                now,
            ),
        )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM subscriptions WHERE scope_type = ? AND scope_id = ?",
            (scope_type, scope_id),
        ).fetchone()
        return _subscription_row_to_dict(row)


def list_org_members(org_id: int) -> List[Dict[str, Any]]:
    with get_connection() as conn:
        rows = conn.execute("SELECT * FROM users WHERE org_id = ? ORDER BY id", (org_id,)).fetchall()
        return [_user_row_to_dict(r) for r in rows]


def _invite_row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    return {
        "id": row["id"],
        "org_id": row["org_id"],
        "invited_user_id": row["invited_user_id"],
        "invited_by_user_id": row["invited_by_user_id"],
        "status": row["status"],
        "created_at": row["created_at"],
        "responded_at": row["responded_at"],
    }


def create_invite(org_id: int, invited_user_id: int, invited_by_user_id: int) -> Dict[str, Any]:
    with get_connection() as conn:
        invited = conn.execute("SELECT org_id FROM users WHERE id = ?", (invited_user_id,)).fetchone()
        if invited is not None and invited["org_id"] is not None:
            raise AlreadyInOrgError("User already belongs to an organization")

        try:
            cursor = conn.execute(
                """
                INSERT INTO invites (org_id, invited_user_id, invited_by_user_id, status, created_at)
                VALUES (?, ?, ?, 'pending', ?)
                """,
                (org_id, invited_user_id, invited_by_user_id, datetime.now(timezone.utc).isoformat()),
            )
        except sqlite3.IntegrityError:
            raise DuplicateInviteError("A pending invite for this user already exists") from None
        conn.commit()

        row = conn.execute("SELECT * FROM invites WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return _invite_row_to_dict(row)


def get_invite(invite_id: int) -> Optional[Dict[str, Any]]:
    with get_connection() as conn:
        row = conn.execute("SELECT * FROM invites WHERE id = ?", (invite_id,)).fetchone()
        return _invite_row_to_dict(row) if row else None


def list_pending_invites_for_user(user_id: int) -> List[Dict[str, Any]]:
    with get_connection() as conn:
        rows = conn.execute(
            "SELECT * FROM invites WHERE invited_user_id = ? AND status = 'pending' ORDER BY id DESC",
            (user_id,),
        ).fetchall()
        return [_invite_row_to_dict(r) for r in rows]


def list_pending_invites_for_org(org_id: int) -> List[Dict[str, Any]]:
    with get_connection() as conn:
        rows = conn.execute(
            "SELECT * FROM invites WHERE org_id = ? AND status = 'pending' ORDER BY id DESC",
            (org_id,),
        ).fetchall()
        return [_invite_row_to_dict(r) for r in rows]


def revoke_invite(invite_id: int) -> None:
    with get_connection() as conn:
        conn.execute("UPDATE invites SET status = 'revoked' WHERE id = ?", (invite_id,))
        conn.commit()


def respond_to_invite(invite_id: int, accept: bool) -> Dict[str, Any]:
    with get_connection() as conn:
        invite_row = conn.execute("SELECT * FROM invites WHERE id = ?", (invite_id,)).fetchone()
        invite = _invite_row_to_dict(invite_row)
        now = datetime.now(timezone.utc).isoformat()

        if not accept:
            conn.execute(
                "UPDATE invites SET status = 'declined', responded_at = ? WHERE id = ?",
                (now, invite_id),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM invites WHERE id = ?", (invite_id,)).fetchone()
            return _invite_row_to_dict(row)

        org_row = conn.execute(
            "SELECT * FROM organizations WHERE id = ?", (invite["org_id"],)
        ).fetchone()
        org = _org_row_to_dict(org_row)
        seat_count = conn.execute(
            "SELECT COUNT(*) AS c FROM users WHERE org_id = ?", (org["id"],)
        ).fetchone()["c"]
        if seat_count >= org["seat_limit"]:
            raise OrgFullError("Organization has no free seats")

        invited_user = conn.execute(
            "SELECT org_id FROM users WHERE id = ?", (invite["invited_user_id"],)
        ).fetchone()
        if invited_user is not None and invited_user["org_id"] is not None:
            raise AlreadyInOrgError("User already belongs to an organization")

        conn.execute(
            "UPDATE users SET org_id = ?, org_role = ? WHERE id = ?",
            (org["id"], "member", invite["invited_user_id"]),
        )
        conn.execute(
            "UPDATE invites SET status = 'accepted', responded_at = ? WHERE id = ?",
            (now, invite_id),
        )
        conn.commit()

        row = conn.execute("SELECT * FROM invites WHERE id = ?", (invite_id,)).fetchone()
        return _invite_row_to_dict(row)

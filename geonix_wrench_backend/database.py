import hashlib
import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

from config import (
    DB_PATH,
    DELETED_ACCOUNT_TOMBSTONE_HOURS,
    DEVICE_LAST_SEEN_REFRESH_SECONDS,
    DEVICE_SESSION_RETENTION_HOURS,
)
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


class AccountDeletedError(Exception):
    """A token belonging to an account that has been closed.

    Raised instead of silently creating the row again — see the
    deleted_accounts table. auth.get_current_user turns this into a 401, which
    is what the app already treats as "sign in again".
    """


class UserNotFoundError(Exception):
    pass


class OwnerMustDeleteOrgError(Exception):
    """The account owns a shop that still has other members in it."""


class OwnerCannotLeaveError(Exception):
    pass


class DeviceLimitReachedError(Exception):
    """A device tried to sign in while the account was already at its ceiling.

    Only ever raised under DEVICE_LIMIT_POLICY="reject" — the default policy
    makes room by evicting the least recently used device instead, so this
    never fires there.
    """


class DeviceSessionNotFoundError(Exception):
    """No such device on this account, or it was already signed out."""


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
        # Closed accounts, kept just long enough to enforce the closure.
        #
        # A Firebase ID token stays cryptographically valid until it expires —
        # up to an hour — and deleting the identity does not invalidate one
        # already issued. get_or_create_user would happily INSERT the row
        # straight back, so an account could be un-deleted by a token still in
        # flight, re-storing the email of someone who had just asked for
        # erasure. This is what makes the deletion stick.
        #
        # The uid is stored hashed, not raw: it only ever needs to be matched,
        # never read back, and keeping an identifier for someone who asked to
        # be forgotten is the thing to avoid. Rows are pruned after
        # DELETED_ACCOUNT_TOMBSTONE_HOURS, which is well past any token's life.
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS deleted_accounts (
                uid_hash TEXT PRIMARY KEY,
                deleted_at TEXT NOT NULL
            )
            """
        )

        # One row per device signed in to an account.
        #
        # This is the *only* server-side record that a session exists. Firebase
        # ID tokens are minted by Firebase and verified by signature, so the
        # backend has nothing it could revoke — without this table "sign this
        # device out" could not mean anything until the token expired on its
        # own, up to an hour later.
        #
        # device_hash, not device_id: the raw value is a per-install UUID the
        # app sends on every request, so storing it plain would leave a
        # ready-made cross-account device identifier in the database for
        # anything that reads it. It only ever needs to be matched, exactly as
        # with deleted_accounts.uid_hash.
        #
        # Signed-out rows are kept, not deleted, with revoked_at set: an
        # evicted device that came back to a clean table would re-register
        # itself on its next request and quietly undo the eviction. They are
        # pruned after DEVICE_SESSION_RETENTION_HOURS.
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS device_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL,
                device_hash TEXT NOT NULL,
                device_name TEXT,
                platform TEXT,
                created_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                revoked_at TEXT,
                revoked_reason TEXT
            )
            """
        )
        # The uniqueness is what makes registration idempotent: a device that
        # signs in twice updates its row rather than consuming a second slot.
        conn.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS ux_device_sessions_user_device
                ON device_sessions(user_id, device_hash)
            """
        )
        # Every authenticated request counts the active rows for one user, so
        # this index is on the hot path rather than a nicety.
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS ix_device_sessions_user_active
                ON device_sessions(user_id)
                WHERE revoked_at IS NULL
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


def _uid_hash(firebase_uid: str) -> str:
    return hashlib.sha256(firebase_uid.encode("utf-8")).hexdigest()


def _prune_expired_tombstones(conn: sqlite3.Connection) -> None:
    cutoff = datetime.now(timezone.utc) - timedelta(hours=DELETED_ACCOUNT_TOMBSTONE_HOURS)
    conn.execute("DELETE FROM deleted_accounts WHERE deleted_at < ?", (cutoff.isoformat(),))


def get_or_create_user(firebase_uid: str, email: str) -> Dict[str, Any]:
    with get_connection() as conn:
        row = conn.execute("SELECT * FROM users WHERE firebase_uid = ?", (firebase_uid,)).fetchone()
        if row:
            return _user_row_to_dict(row)

        # Only checked on the create path. An existing user is never blocked by
        # this, so the cost falls on first sign-in rather than every request.
        _prune_expired_tombstones(conn)
        if conn.execute(
            "SELECT 1 FROM deleted_accounts WHERE uid_hash = ?", (_uid_hash(firebase_uid),)
        ).fetchone():
            conn.commit()
            raise AccountDeletedError("This account has been closed")
        conn.commit()

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


def count_active_subscriptions(scope_type: str, plan: str) -> int:
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT COUNT(*) AS c FROM subscriptions
            WHERE scope_type = ? AND plan = ? AND status IN ('active', 'trialing')
            """,
            (scope_type, plan),
        ).fetchone()
        return row["c"]


def list_organizations_overview() -> List[Dict[str, Any]]:
    """Every organization with its owner and current seat usage.

    Feeds admin.py's stats for the local admin_portal.py tool. Not scoped to
    any one shop — this is deliberately outside the ordinary per-account API
    surface, and only ever called from a process running on the operator's
    own machine.
    """
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT o.id, o.name, o.seat_limit, o.owner_user_id,
                   u.email AS owner_email, u.handle AS owner_handle,
                   s.status AS subscription_status, s.plan AS plan
            FROM organizations o
            LEFT JOIN users u ON u.id = o.owner_user_id
            LEFT JOIN subscriptions s ON s.scope_type = 'org' AND s.scope_id = o.id
            ORDER BY o.id
            """
        ).fetchall()
        overview = []
        for row in rows:
            seat_used = conn.execute(
                "SELECT COUNT(*) AS c FROM users WHERE org_id = ?", (row["id"],)
            ).fetchone()["c"]
            overview.append(
                {
                    "id": row["id"],
                    "name": row["name"],
                    "seat_limit": row["seat_limit"],
                    "seat_used": seat_used,
                    "owner_email": row["owner_email"] or "",
                    "owner_handle": row["owner_handle"],
                    "subscription_status": row["subscription_status"],
                    "plan": row["plan"],
                }
            )
        return overview


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
            "SELECT id, org_id, org_role, firebase_uid FROM users WHERE id = ?", (user_id,)
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
        # Deleted outright rather than tombstoned. The reason revoked rows
        # normally survive is to stop a device re-registering itself, and there
        # is no account left for it to register against — deleted_accounts
        # already refuses the token. Keeping them would only hold on to device
        # identifiers for someone who asked to be forgotten.
        conn.execute("DELETE FROM device_sessions WHERE user_id = ?", (user_id,))

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

        # In the same transaction as the delete: a tombstone written separately
        # could fail on its own and leave the account re-creatable.
        conn.execute(
            "INSERT OR REPLACE INTO deleted_accounts (uid_hash, deleted_at) VALUES (?, ?)",
            (_uid_hash(user["firebase_uid"]), datetime.now(timezone.utc).isoformat()),
        )
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


# ── device sessions ───────────────────────────────────────────────────────
#
# See the device_sessions table in init_db for why this exists at all, and
# devices.py for who is allowed how many.


def _device_hash(device_id: str) -> str:
    return hashlib.sha256(device_id.encode("utf-8")).hexdigest()


def _device_row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    return {
        "id": row["id"],
        "user_id": row["user_id"],
        "device_name": row["device_name"],
        "platform": row["platform"],
        "created_at": row["created_at"],
        "last_seen_at": row["last_seen_at"],
        "revoked_at": row["revoked_at"],
    }


def _prune_expired_device_sessions(conn: sqlite3.Connection) -> None:
    """Forget devices signed out long enough ago that they cannot come back.

    A revoked row's whole job is to answer "you were signed out" the next time
    that device calls. Past the retention window any token it could still be
    holding expired hours ago, so the row is just a stored device identifier
    with no purpose left.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(hours=DEVICE_SESSION_RETENTION_HOURS)
    conn.execute(
        "DELETE FROM device_sessions WHERE revoked_at IS NOT NULL AND revoked_at < ?",
        (cutoff.isoformat(),),
    )


def _active_sessions(conn: sqlite3.Connection, user_id: int) -> List[sqlite3.Row]:
    """Signed-in devices for one account, least recently used first.

    The order is the eviction order. Least *recently used* rather than oldest
    *registered*: a mechanic's daily phone can easily be the first device they
    ever set up, and evicting by registration date would throw them off the one
    device they actually work on to make room for a laptop they signed into
    once.
    """
    return conn.execute(
        """
        SELECT * FROM device_sessions
        WHERE user_id = ? AND revoked_at IS NULL
        ORDER BY last_seen_at ASC, id ASC
        """,
        (user_id,),
    ).fetchall()


def count_active_device_sessions(user_id: int) -> int:
    with get_connection() as conn:
        return conn.execute(
            "SELECT COUNT(*) AS c FROM device_sessions WHERE user_id = ? AND revoked_at IS NULL",
            (user_id,),
        ).fetchone()["c"]


def list_device_sessions(user_id: int) -> List[Dict[str, Any]]:
    """Signed-in devices, most recently used first — the order Settings shows."""
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT * FROM device_sessions
            WHERE user_id = ? AND revoked_at IS NULL
            ORDER BY last_seen_at DESC, id DESC
            """,
            (user_id,),
        ).fetchall()
        return [_device_row_to_dict(r) for r in rows]


def register_device_session(
    *,
    user_id: int,
    device_id: str,
    device_name: Optional[str],
    platform: Optional[str],
    limit: int,
    evict_oldest: bool,
) -> Dict[str, Any]:
    """Sign a device in, making room for it if the account is at its ceiling.

    Idempotent for a device that is already signed in — it refreshes the name
    and timestamp and consumes no extra slot, which is what lets the app call
    this on every launch without thinking about it.

    A revoked row for the same device is *revived* here rather than left alone.
    That is the difference between this and the implicit registration in
    `touch_device_session`: coming back through the front door (a real sign-in)
    should work, while a background request from an evicted device should not
    silently reinstate it.

    Returns {"session": ..., "evicted": [...], "limit": ...}. `evicted` is what
    the caller logs and what the app could show as "signed out on your other
    device"; it is empty in the ordinary case.

    Raises DeviceLimitReachedError when there is no room and `evict_oldest` is
    False.
    """
    device_hash = _device_hash(device_id)
    now = datetime.now(timezone.utc).isoformat()

    with get_connection() as conn:
        # Serialise the count-then-insert below. Without it two devices
        # registering at the same moment both read "2 of 3 used" and both
        # insert, putting the account one over its limit — the classic
        # check-then-act race, and the one thing a quota must not lose.
        conn.execute("BEGIN IMMEDIATE")
        try:
            _prune_expired_device_sessions(conn)

            existing = conn.execute(
                "SELECT * FROM device_sessions WHERE user_id = ? AND device_hash = ?",
                (user_id, device_hash),
            ).fetchone()

            # Already signed in: refresh in place, no slot accounting at all.
            if existing is not None and existing["revoked_at"] is None:
                conn.execute(
                    """
                    UPDATE device_sessions
                    SET device_name = COALESCE(?, device_name),
                        platform = COALESCE(?, platform),
                        last_seen_at = ?
                    WHERE id = ?
                    """,
                    (device_name, platform, now, existing["id"]),
                )
                row = conn.execute(
                    "SELECT * FROM device_sessions WHERE id = ?", (existing["id"],)
                ).fetchone()
                conn.commit()
                return {"session": _device_row_to_dict(row), "evicted": [], "limit": limit}

            # A limit of zero means no device may hold a session, so there is
            # nothing to evict towards — evicting would clear the account and
            # then admit the new device anyway, which is the opposite of the
            # instruction.
            if limit <= 0:
                conn.rollback()
                raise DeviceLimitReachedError("This account may not sign in on any device")

            active = _active_sessions(conn, user_id)
            evicted: List[Dict[str, Any]] = []

            # `limit - 1` because the device being registered needs a slot of
            # its own. Written as a loop rather than a single eviction so a
            # limit that *drops* — an owner accepting an invite and becoming an
            # employee, 3 devices down to 1 — is brought back into line in one
            # go instead of one device per sign-in.
            if len(active) >= limit:
                if not evict_oldest:
                    conn.rollback()
                    raise DeviceLimitReachedError(
                        f"This account is limited to {limit} "
                        f"device{'' if limit == 1 else 's'}"
                    )
                for row in active[: len(active) - max(limit - 1, 0)]:
                    conn.execute(
                        "UPDATE device_sessions SET revoked_at = ?, revoked_reason = ? WHERE id = ?",
                        (now, "evicted", row["id"]),
                    )
                    evicted.append(_device_row_to_dict(row))

            if existing is not None:
                # Revive the revoked row instead of inserting beside it — the
                # unique index would reject a second row for the same device,
                # and reusing it keeps created_at meaning "first seen".
                conn.execute(
                    """
                    UPDATE device_sessions
                    SET device_name = COALESCE(?, device_name),
                        platform = COALESCE(?, platform),
                        last_seen_at = ?,
                        revoked_at = NULL,
                        revoked_reason = NULL
                    WHERE id = ?
                    """,
                    (device_name, platform, now, existing["id"]),
                )
                session_id = existing["id"]
            else:
                cursor = conn.execute(
                    """
                    INSERT INTO device_sessions
                        (user_id, device_hash, device_name, platform, created_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (user_id, device_hash, device_name, platform, now, now),
                )
                session_id = cursor.lastrowid

            row = conn.execute(
                "SELECT * FROM device_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            conn.commit()
            return {"session": _device_row_to_dict(row), "evicted": evicted, "limit": limit}
        except DeviceLimitReachedError:
            raise
        except Exception:
            conn.rollback()
            raise


# What `touch_device_session` found. The caller turns these into HTTP: `active`
# proceeds, `revoked` is a 401 that ends the session, `unknown` means register
# it.
DEVICE_ACTIVE = "active"
DEVICE_REVOKED = "revoked"
DEVICE_UNKNOWN = "unknown"


def touch_device_session(user_id: int, device_id: str) -> str:
    """Check a device on an authenticated request and keep its clock current.

    Runs on every request, so it does as little as possible: one indexed
    lookup, and a write only when last_seen_at has gone stale by more than
    DEVICE_LAST_SEEN_REFRESH_SECONDS. Eviction picks the least recently used
    device, and that choice does not get better for being accurate to the
    second — it does get much more expensive.
    """
    device_hash = _device_hash(device_id)
    with get_connection() as conn:
        row = conn.execute(
            "SELECT id, last_seen_at, revoked_at FROM device_sessions "
            "WHERE user_id = ? AND device_hash = ?",
            (user_id, device_hash),
        ).fetchone()
        if row is None:
            return DEVICE_UNKNOWN
        if row["revoked_at"] is not None:
            return DEVICE_REVOKED

        now = datetime.now(timezone.utc)
        if _is_stale(row["last_seen_at"], now):
            conn.execute(
                "UPDATE device_sessions SET last_seen_at = ? WHERE id = ?",
                (now.isoformat(), row["id"]),
            )
            conn.commit()
        return DEVICE_ACTIVE


def _is_stale(last_seen_at: Optional[str], now: datetime) -> bool:
    if not last_seen_at:
        return True
    try:
        parsed = datetime.fromisoformat(last_seen_at)
    except ValueError:
        # An unparseable timestamp would otherwise pin the row as "fresh"
        # forever and make it un-evictable. Rewriting it repairs the row.
        return True
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return (now - parsed).total_seconds() >= DEVICE_LAST_SEEN_REFRESH_SECONDS


def revoke_device_session(user_id: int, session_id: int, reason: str = "manual") -> Dict[str, Any]:
    """Sign one device out, by row id.

    Scoped to `user_id` in the WHERE clause rather than checked afterwards, so
    a guessed id belonging to someone else cannot sign out a stranger's device
    — and is indistinguishable from an id that does not exist.
    """
    with get_connection() as conn:
        row = conn.execute(
            "SELECT * FROM device_sessions WHERE id = ? AND user_id = ? AND revoked_at IS NULL",
            (session_id, user_id),
        ).fetchone()
        if row is None:
            raise DeviceSessionNotFoundError(f"No active device session {session_id}")

        conn.execute(
            "UPDATE device_sessions SET revoked_at = ?, revoked_reason = ? WHERE id = ?",
            (datetime.now(timezone.utc).isoformat(), reason, session_id),
        )
        conn.commit()
        return _device_row_to_dict(row)


def enforce_device_limit(user_id: int, limit: int) -> List[Dict[str, Any]]:
    """Bring an account back within a limit that has just got smaller.

    Called when a role change lowers the quota — accepting a shop invite turns
    an account with up to three devices into an employee entitled to one. Without
    this the extra devices would keep working until each happened to sign in
    again, which for a tablet left signed in is never.

    Returns the devices that were signed out, least recently used first.
    """
    now = datetime.now(timezone.utc).isoformat()
    with get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        try:
            active = _active_sessions(conn, user_id)
            surplus = active[: max(len(active) - max(limit, 0), 0)]
            for row in surplus:
                conn.execute(
                    "UPDATE device_sessions SET revoked_at = ?, revoked_reason = ? WHERE id = ?",
                    (now, "limit_lowered", row["id"]),
                )
            conn.commit()
            return [_device_row_to_dict(r) for r in surplus]
        except Exception:
            conn.rollback()
            raise


def find_device_session(user_id: int, device_id: str) -> Optional[Dict[str, Any]]:
    """The row for one raw device id, revoked or not.

    Exists so main.py can mark "This device" in the list without being handed
    the hashing scheme — the routes compare row ids, and the mapping from a
    device id to a row stays here.
    """
    with get_connection() as conn:
        row = conn.execute(
            "SELECT * FROM device_sessions WHERE user_id = ? AND device_hash = ?",
            (user_id, _device_hash(device_id)),
        ).fetchone()
        return _device_row_to_dict(row) if row else None

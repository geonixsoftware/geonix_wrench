"""Revenue, profit, subscriber and usage aggregates for admin_portal.py.

Not wired into the FastAPI app in main.py and not reachable by the mobile/
desktop app at all — this is read by the local-only portal
(admin_portal.py), which you run yourself on your own machine. See that
file for how it is served.
"""

from datetime import datetime, timedelta, timezone
from typing import Dict, List

import database
from billing import ACTIVE_SUBSCRIPTION_STATUSES
from config import (
    ADMIN_MONTHLY_COSTS,
    BILLING_CURRENCY,
    INDIVIDUAL_PRICE_PER_MONTH,
    TEAM_PRICE_PER_SEAT,
)

HIDDEN_KIND_ORG = "organization"
HIDDEN_KIND_INDIVIDUAL = "individual_subscription"
_HIDDEN_KINDS = (HIDDEN_KIND_ORG, HIDDEN_KIND_INDIVIDUAL)


# ── "vanish" / hide-unhide ──────────────────────────────────────────────────
#
# One extra table, owned entirely by this module. It only ever records "the
# operator hid shop #7 from their own dashboard" — nothing here touches the
# users/organizations/subscriptions tables the live app depends on, so hiding
# something in the portal cannot change what that shop or subscriber can
# actually do in the product. It is a display filter, saved so it survives a
# restart, and reversible at any time.


def init_portal_db() -> None:
    with database.get_connection() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS admin_portal_hidden (
                kind TEXT NOT NULL CHECK (kind IN ('organization', 'individual_subscription')),
                ref_id INTEGER NOT NULL,
                hidden_at TEXT NOT NULL,
                PRIMARY KEY (kind, ref_id)
            )
            """
        )
        conn.commit()


def _hidden_ids(kind: str) -> set:
    with database.get_connection() as conn:
        rows = conn.execute(
            "SELECT ref_id FROM admin_portal_hidden WHERE kind = ?", (kind,)
        ).fetchall()
        return {row["ref_id"] for row in rows}


def hide(kind: str, ref_id: int) -> None:
    if kind not in _HIDDEN_KINDS:
        raise ValueError(f"Unknown kind: {kind}")
    with database.get_connection() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO admin_portal_hidden (kind, ref_id, hidden_at) VALUES (?, ?, ?)",
            (kind, ref_id, datetime.now(timezone.utc).isoformat()),
        )
        conn.commit()


def unhide(kind: str, ref_id: int) -> None:
    if kind not in _HIDDEN_KINDS:
        raise ValueError(f"Unknown kind: {kind}")
    with database.get_connection() as conn:
        conn.execute(
            "DELETE FROM admin_portal_hidden WHERE kind = ? AND ref_id = ?", (kind, ref_id)
        )
        conn.commit()


# ── data ─────────────────────────────────────────────────────────────────


def _individual_subscriptions() -> List[Dict]:
    """Every user-scope subscription, whatever its status — active or lapsed."""
    with database.get_connection() as conn:
        rows = conn.execute(
            """
            SELECT s.scope_id AS user_id, s.status, s.plan, s.current_period_end,
                   u.email, u.handle
            FROM subscriptions s
            JOIN users u ON u.id = s.scope_id
            WHERE s.scope_type = 'user'
            ORDER BY s.updated_at DESC
            """
        ).fetchall()
        return [dict(row) for row in rows]


def list_organizations() -> List[Dict]:
    """Visible (non-hidden) organizations."""
    hidden = _hidden_ids(HIDDEN_KIND_ORG)
    return [org for org in database.list_organizations_overview() if org["id"] not in hidden]


def list_individual_subscribers() -> List[Dict]:
    """Visible (non-hidden) user-scope subscriptions, active or not."""
    hidden = _hidden_ids(HIDDEN_KIND_INDIVIDUAL)
    return [sub for sub in _individual_subscriptions() if sub["user_id"] not in hidden]


def list_churned_subscriptions() -> List[Dict]:
    """Visible subscriptions that exist but are not currently active.

    Both scopes at once, each row labelled with the shop or account it
    belongs to — this is the "who cancelled" list the stat tiles don't show.
    """
    hidden_orgs = _hidden_ids(HIDDEN_KIND_ORG)
    hidden_individuals = _hidden_ids(HIDDEN_KIND_INDIVIDUAL)

    placeholders = ",".join("?" for _ in ACTIVE_SUBSCRIPTION_STATUSES)
    with database.get_connection() as conn:
        rows = conn.execute(
            f"""
            SELECT scope_type, scope_id, plan, status, updated_at
            FROM subscriptions
            WHERE status NOT IN ({placeholders})
            ORDER BY updated_at DESC
            """,
            tuple(ACTIVE_SUBSCRIPTION_STATUSES),
        ).fetchall()

    churned = []
    for row in rows:
        entry = dict(row)
        if entry["scope_type"] == "user":
            if entry["scope_id"] in hidden_individuals:
                continue
            user = database.get_user_by_id(entry["scope_id"])
            entry["label"] = (user["handle"] or user["email"]) if user else f"user #{entry['scope_id']}"
            entry["kind"] = HIDDEN_KIND_INDIVIDUAL
        else:
            if entry["scope_id"] in hidden_orgs:
                continue
            org = database.get_organization(entry["scope_id"])
            entry["label"] = org["name"] if org else f"shop #{entry['scope_id']}"
            entry["kind"] = HIDDEN_KIND_ORG
        churned.append(entry)
    return churned


def list_hidden() -> List[Dict]:
    """Everything currently vanished, for the "Hidden" panel's Unhide buttons."""
    with database.get_connection() as conn:
        rows = conn.execute(
            "SELECT kind, ref_id, hidden_at FROM admin_portal_hidden ORDER BY hidden_at DESC"
        ).fetchall()

    hidden = []
    for row in rows:
        entry = dict(row)
        if entry["kind"] == HIDDEN_KIND_ORG:
            org = database.get_organization(entry["ref_id"])
            entry["label"] = org["name"] if org else f"shop #{entry['ref_id']}"
        else:
            user = database.get_user_by_id(entry["ref_id"])
            entry["label"] = (user["handle"] or user["email"]) if user else f"user #{entry['ref_id']}"
        hidden.append(entry)
    return hidden


def usage_stats() -> Dict:
    """Signup and job-card volume, plus devices signed in right now.

    Simple counts, not filtered by hidden shops/subscribers — these describe
    product usage as a whole, which hiding a shop from the revenue view
    should not distort.
    """
    since_7d = (datetime.now(timezone.utc) - timedelta(days=7)).isoformat()
    with database.get_connection() as conn:
        return {
            "total_signups": conn.execute("SELECT COUNT(*) AS c FROM users").fetchone()["c"],
            "signups_last_7d": conn.execute(
                "SELECT COUNT(*) AS c FROM users WHERE created_at >= ?", (since_7d,)
            ).fetchone()["c"],
            "total_jobcards": conn.execute("SELECT COUNT(*) AS c FROM jobcards").fetchone()["c"],
            "jobcards_last_7d": conn.execute(
                "SELECT COUNT(*) AS c FROM jobcards WHERE created_at >= ?", (since_7d,)
            ).fetchone()["c"],
            "active_device_sessions": conn.execute(
                "SELECT COUNT(*) AS c FROM device_sessions WHERE revoked_at IS NULL"
            ).fetchone()["c"],
        }


def get_stats() -> Dict:
    """Revenue, profit and subscriber counts, estimated from the local ledger.

    Not a live Stripe query — it reads the same subscriptions table the
    billing status endpoint does, which webhooks and reconciliation keep in
    sync. Revenue is the advertised monthly price of every currently active,
    non-hidden subscription; "active seats" sums org.seat_limit for
    non-hidden orgs on an active Team plan, since that is what was actually
    purchased, not just occupied.

    Priced at the baseline (North America) rates. Pricing is regional but the
    local ledger does not record which region a subscription was bought in, so
    this over-counts by the difference on every subscription from a cheaper
    region — an upper bound, not a Stripe statement.
    """
    individual_subscribers = len(
        [
            sub
            for sub in list_individual_subscribers()
            if sub["plan"] == "individual" and sub["status"] in ACTIVE_SUBSCRIPTION_STATUSES
        ]
    )

    active_team_orgs = [
        org
        for org in list_organizations()
        if org["plan"] == "team" and org["subscription_status"] in ACTIVE_SUBSCRIPTION_STATUSES
    ]
    team_subscribers = len(active_team_orgs)
    total_active_seats = sum(org["seat_limit"] for org in active_team_orgs)

    team_revenue = total_active_seats * TEAM_PRICE_PER_SEAT
    total_revenue = individual_subscribers * INDIVIDUAL_PRICE_PER_MONTH + team_revenue
    avg_revenue_per_shop = (team_revenue / team_subscribers) if team_subscribers else 0.0

    stats = {
        "currency": BILLING_CURRENCY,
        "total_revenue": total_revenue,
        "total_profit": total_revenue - ADMIN_MONTHLY_COSTS,
        "individual_subscribers": individual_subscribers,
        "team_subscribers": team_subscribers,
        "total_active_seats": total_active_seats,
        "avg_revenue_per_shop": avg_revenue_per_shop,
    }
    stats.update(usage_stats())
    return stats

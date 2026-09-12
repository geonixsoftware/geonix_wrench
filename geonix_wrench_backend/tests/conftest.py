import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import database  # noqa: E402
import limits  # noqa: E402


@pytest.fixture(autouse=True)
def _fresh_rate_limits():
    # The per-account budget now runs inside token verification, and its
    # counters live in process memory. Every temp database hands out user id 1
    # again, so without this the suite would spend one shared budget.
    limits.reset_rate_limits()
    yield
    limits.reset_rate_limits()


@pytest.fixture()
def temp_db(tmp_path, monkeypatch):
    db_path = str(tmp_path / "test.db")
    monkeypatch.setattr(database, "DB_PATH", db_path)
    database.init_db()
    return db_path


def activate(user: dict, plan: str = "individual") -> None:
    """Give a test user (or their shop) a live subscription.

    The product routes now check for one server-side, so any test that
    records, edits, exports or changes the logo has to pay first.
    """
    if user.get("org_id") is not None:
        scope_type, scope_id, plan = "org", user["org_id"], "team"
    else:
        scope_type, scope_id = "user", user["id"]
    database.upsert_subscription(
        scope_type=scope_type,
        scope_id=scope_id,
        stripe_subscription_id=None,
        stripe_customer_id=None,
        plan=plan,
        status="active",
        quantity=1 if plan == "individual" else 5,
        current_period_end="2099-01-01T00:00:00+00:00",
    )

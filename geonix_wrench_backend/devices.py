"""Per-account device quotas: how many, whose, and what happens at the ceiling.

The rule lives here rather than in database.py or auth.py because three
different callers need the same answer and must not each derive it: the
enforcement path when a device appears, the Settings screen listing devices,
and /api/billing/status, which quotes the quota next to the plan so the app can
show it without knowing the rule.

Firebase ID tokens are stateless — the backend never issued them and cannot
revoke one — so "active session" here means a row in device_sessions, and
signing a device out means marking that row revoked. auth.get_current_user
checks it on every authenticated request, which is what makes a revocation take
effect within seconds rather than whenever the token happens to expire.
"""

from typing import Optional

from fastapi import HTTPException

from config import (
    DEVICE_LIMIT_INDIVIDUAL,
    DEVICE_LIMIT_POLICY,
    DEVICE_LIMIT_TEAM_MEMBER,
    DEVICE_LIMIT_TEAM_OWNER,
    DEVICE_NAME_MAX_LENGTH,
)

# Sent by the app on every authenticated request. A random UUID minted once per
# installation — not a hardware serial, IDFA or anything else the platform
# would (rightly) gate behind a permission prompt. It identifies an install, and
# reinstalling deliberately looks like a new device.
DEVICE_ID_HEADER = "X-Device-Id"

# Only read when a device is registering. Cosmetic: it is what the user sees in
# the device list, so they can tell which row is the tablet they lost.
DEVICE_NAME_HEADER = "X-Device-Name"
DEVICE_PLATFORM_HEADER = "X-Device-Platform"

POLICY_EVICT_OLDEST = "evict_oldest"
POLICY_REJECT = "reject"

# Returned in the `detail` of the 403 so the app can recognise this specific
# refusal and open the device list instead of showing a generic error.
DEVICE_LIMIT_DETAIL = (
    "Device limit reached. Sign out on another device, or remove one from "
    "Settings, then try again."
)

# ...and of the 401 when the device itself was signed out. Distinct from the
# generic "Invalid or expired token" on purpose: the caller already proved who
# they are with a valid token, so naming the reason leaks nothing, and it is
# the difference between "your session expired" and "someone removed this
# device from the account".
DEVICE_REVOKED_DETAIL = "This device was signed out of the account."


def resolve_device_limit(user: dict) -> int:
    """How many devices this account may have signed in at once.

    Keyed on org role. `member` is an employee on someone else's Team
    subscription and gets one device; everyone else — an Individual subscriber,
    a shop owner, an account with no subscription yet — gets the standard
    allowance. See config.py for why the unsubscribed case is not the strictest
    number.
    """
    if user.get("org_id") is not None and user.get("org_role") == "member":
        return DEVICE_LIMIT_TEAM_MEMBER
    if user.get("org_id") is not None and user.get("org_role") == "owner":
        return DEVICE_LIMIT_TEAM_OWNER
    return DEVICE_LIMIT_INDIVIDUAL


def evicts_oldest() -> bool:
    """True when a sign-in past the ceiling pushes the least-used device out.

    Anything other than an explicit "reject" evicts, so a typo in the env var
    fails towards letting the customer in rather than locking them out of an
    account they pay for.
    """
    return DEVICE_LIMIT_POLICY != POLICY_REJECT


def device_limit_exception() -> HTTPException:
    """403, not 409: the caller is authenticated and simply may not do this.

    The app splits on status — 401 ends the session, 403 does not — and being
    at the device ceiling must not sign anyone out. That would free a slot by
    taking away the very device asking for one.
    """
    return HTTPException(status_code=403, detail=DEVICE_LIMIT_DETAIL)


def clean_device_name(raw: Optional[str]) -> Optional[str]:
    """Trim a client-supplied device name to something displayable, or None.

    Rendered back into the device list and into a PDF-free HTML-free Flutter
    Text widget, so there is nothing to escape — but it arrives in an HTTP
    header, where a stray newline would be a header-injection primitive, and it
    is unbounded. Both are handled here so no caller has to remember.
    """
    if raw is None:
        return None
    collapsed = " ".join(raw.split())
    if not collapsed:
        return None
    return collapsed[:DEVICE_NAME_MAX_LENGTH]

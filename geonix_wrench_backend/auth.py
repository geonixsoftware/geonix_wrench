import re
from typing import Optional

import firebase_admin
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from firebase_admin import auth as firebase_auth
from firebase_admin import credentials

import billing
import database
import devices
from config import (
    DEVICE_ID_MAX_LENGTH,
    FIREBASE_SERVICE_ACCOUNT_PATH,
    HANDLE_MAX_LENGTH,
    HANDLE_MIN_LENGTH,
    RATE_LIMIT_DEFAULT_PER_WINDOW,
    REQUIRE_DEVICE_ID,
)
from limits import enforce_rate_limit

HANDLE_REGEX = re.compile(r"^[a-z0-9_]+$")


class InvalidHandleError(ValueError):
    pass


def validate_handle(raw: str) -> str:
    handle = raw.strip().lower()
    if len(handle) < HANDLE_MIN_LENGTH or len(handle) > HANDLE_MAX_LENGTH:
        raise InvalidHandleError(
            f"Handle must be between {HANDLE_MIN_LENGTH} and {HANDLE_MAX_LENGTH} characters"
        )
    if not HANDLE_REGEX.match(handle):
        raise InvalidHandleError("Handle may only contain lowercase letters, numbers, and underscores")
    return handle


def init_firebase_app() -> None:
    if firebase_admin._apps:
        return
    try:
        firebase_admin.initialize_app(credentials.Certificate(FIREBASE_SERVICE_ACCOUNT_PATH))
    except ValueError:
        pass


# auto_error=False so the missing- and malformed-header cases come back to us
# instead of being answered by HTTPBearer itself.
#
# Left to its own devices HTTPBearer raises **403** for both ("Not
# authenticated" / "Invalid authentication credentials") while an expired token
# raises 401 here. That put two different meanings behind one status: 403 was
# also what every permission check returns ("Only the shop owner can change
# seats", "Not a member of this organization"). A client cannot tell those
# apart, so an app that signs out on 403 would eject a mechanic for tapping an
# owner-only button, and one that signs out on 401 alone would miss a session
# with no token at all.
#
# Now the split is clean: 401 always means "your credentials are no good, sign
# in again", 403 always means "you are who you say you are and still may not do
# this".
_bearer_scheme = HTTPBearer(auto_error=False)

# One message for every authentication failure. It is also the only safe
# wording — saying whether a token was absent, malformed or merely expired
# tells an attacker which of those to change.
_INVALID_TOKEN = "Invalid or expired token"


def _unauthorized() -> HTTPException:
    # WWW-Authenticate is what makes a 401 a well-formed one. `Bearer` does not
    # trigger the browser's basic-auth dialog the way `Basic` would.
    return HTTPException(
        status_code=401,
        detail=_INVALID_TOKEN,
        headers={"WWW-Authenticate": "Bearer"},
    )


def _device_revoked() -> HTTPException:
    """401 with a reason, unlike every other authentication failure here.

    The generic wording above exists so an attacker cannot learn whether a
    token was absent, malformed or expired. That reasoning does not apply
    here: the caller presented a valid, unexpired token for a live account, so
    they already know all of that. What they do not know is that this device
    was signed out — and telling them is the difference between "your session
    expired, sign in again" and "somebody removed this tablet from the shop
    account", which are different problems with different fixes.
    """
    return HTTPException(
        status_code=401,
        detail=devices.DEVICE_REVOKED_DETAIL,
        headers={"WWW-Authenticate": "Bearer"},
    )


def _verify_token(credentials: Optional[HTTPAuthorizationCredentials]) -> dict:
    """Firebase token in, user row out. No device checking."""
    if credentials is None or not credentials.credentials:
        raise _unauthorized()

    try:
        decoded = firebase_auth.verify_id_token(credentials.credentials)
    except Exception:
        raise _unauthorized() from None

    try:
        user = database.get_or_create_user(
            firebase_uid=decoded["uid"], email=decoded.get("email", "")
        )
    except database.AccountDeletedError:
        # The token is genuine and unexpired; the account behind it is gone.
        # 401 rather than 403 because the answer is "sign in again", and the
        # app already ends the session on a 401. The message stays the generic
        # one so a closed account is not distinguishable from an expired token.
        raise _unauthorized() from None

    # The general per-account budget, applied here because every authenticated
    # route passes through this function. It used to be applied nowhere: only
    # audio processing had a ceiling, and PDF generation, logo uploads and
    # invite creation were each an unbounded amplifier for any account.
    enforce_rate_limit("default", str(user["id"]), RATE_LIMIT_DEFAULT_PER_WINDOW)
    return user


def _header(request: Request, name: str, limit: int) -> Optional[str]:
    raw = request.headers.get(name)
    if raw is None:
        return None
    trimmed = raw.strip()
    return trimmed[:limit] if trimmed else None


def enforce_device_session(request: Request, user: dict) -> None:
    """Decide whether this device may act on this account, on every request.

    Split out of the dependency so the device-management routes can verify a
    token without it — sign-in registration must work before a session exists,
    and the "which devices are signed in" screen has to stay reachable from a
    device that is about to be signed out.

    Three cases, in the order they are hit:

    * **Known and active** — the common one. Refreshes the last-seen clock,
      throttled, and returns.
    * **Known and revoked** — 401. Firebase would keep honouring the token for
      up to an hour after the device was removed, so this check is the entire
      teeth of "sign this device out".
    * **Unknown** — registered here, subject to the account's quota. Doing it
      implicitly rather than demanding an explicit call first means there is no
      ordering to get wrong: whichever request the app happens to make first on
      a new install claims the slot, and the explicit POST /api/auth/session
      later only fills in the display name.
    """
    device_id = _header(request, devices.DEVICE_ID_HEADER, DEVICE_ID_MAX_LENGTH)
    if not device_id:
        if REQUIRE_DEVICE_ID:
            # 400, not 401: the credentials are fine, the request is malformed.
            # A 401 would sign the user out of an app whose only mistake was
            # being an older build, and no amount of signing back in fixes a
            # missing header.
            raise HTTPException(
                status_code=400,
                detail=f"{devices.DEVICE_ID_HEADER} header is required",
            )
        # Untracked and unenforced. See REQUIRE_DEVICE_ID in config.py.
        return

    state = database.touch_device_session(user["id"], device_id)
    if state == database.DEVICE_ACTIVE:
        return
    if state == database.DEVICE_REVOKED:
        raise _device_revoked()

    try:
        database.register_device_session(
            user_id=user["id"],
            device_id=device_id,
            device_name=devices.clean_device_name(
                _header(request, devices.DEVICE_NAME_HEADER, DEVICE_ID_MAX_LENGTH)
            ),
            platform=_header(request, devices.DEVICE_PLATFORM_HEADER, 32),
            limit=devices.resolve_device_limit(user),
            evict_oldest=devices.evicts_oldest(),
        )
    except database.DeviceLimitReachedError:
        raise devices.device_limit_exception() from None


def get_current_user(
    request: Request,
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_bearer_scheme),
) -> dict:
    """The dependency every ordinary route uses: valid token *and* live device."""
    user = _verify_token(credentials)
    enforce_device_session(request, user)
    return user


def get_paying_user(user: dict = Depends(get_current_user)) -> dict:
    """A signed-in user on a live device whose account is also paid for.

    For the routes that cost money or produce the product: transcription,
    editing and exporting job cards, changing the shop logo. Everything else
    stays on `get_current_user`, since an unsubscribed account still has to
    reach the screens where it would subscribe, manage devices, or close.

    402 rather than 403: the caller is who they say they are and may well
    have permission — what they lack is a subscription, which is a different
    fix, and the app must not read it as "sign out" (401) or "not allowed"
    (403).
    """
    if not billing.is_account_active(user):
        raise HTTPException(status_code=402, detail=billing.SUBSCRIPTION_REQUIRED_DETAIL)
    return user


def get_current_user_without_device(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_bearer_scheme),
) -> dict:
    """Token only, for the handful of routes that manage devices themselves.

    Deliberately narrow. Anything else using this is a hole in the quota, since
    a device that never gets checked is a device that never gets counted.
    """
    return _verify_token(credentials)


def delete_firebase_user(firebase_uid: str) -> None:
    """Remove the Firebase identity behind a deleted account.

    Kept here beside the token verification rather than called from main, so
    firebase_admin stays confined to this module — everything else talks to
    Firebase only through these two functions.

    Without this the rows are gone but the login survives: signing in again
    would silently mint a brand-new empty account for an identity the user asked
    to have erased.
    """
    firebase_auth.delete_user(firebase_uid)

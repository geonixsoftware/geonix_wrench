import re

import firebase_admin
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from firebase_admin import auth as firebase_auth
from firebase_admin import credentials

import database
from config import FIREBASE_SERVICE_ACCOUNT_PATH, HANDLE_MAX_LENGTH, HANDLE_MIN_LENGTH

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


def get_current_user(credentials: HTTPAuthorizationCredentials = Depends(HTTPBearer())) -> dict:
    try:
        decoded = firebase_auth.verify_id_token(credentials.credentials)
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid or expired token") from None

    return database.get_or_create_user(firebase_uid=decoded["uid"], email=decoded.get("email", ""))


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

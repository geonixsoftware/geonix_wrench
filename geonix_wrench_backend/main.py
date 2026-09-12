import logging
import os
import tempfile
import time
from typing import Optional

from fastapi import Depends, FastAPI, File, Header, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles

from security_headers import SecurityHeadersMiddleware

import billing
import database
from auth import (
    InvalidHandleError,
    delete_firebase_user,
    get_current_user,
    get_current_user_without_device,
    get_paying_user,
    init_firebase_app,
    validate_handle,
)
from config import (
    ALLOWED_AUDIO_EXTENSIONS,
    ALLOWED_ORIGINS,
    ENABLE_API_DOCS,
    FRONTEND_DIST_DIR,
    LLM_PROVIDER,
    MAX_AUDIO_SIZE_BYTES,
    RATE_LIMIT_AUDIO_PER_WINDOW,
    ALLOWED_LOGO_EXTENSIONS,
    DEFAULT_CURRENCY,
    DEFAULT_LABOR_RATE,
    MAX_LOGO_SIZE_BYTES,
    TEAM_MIN_SEATS,
    DEVICE_ID_MAX_LENGTH,
)
from database import (
    AlreadyInOrgError,
    DuplicateInviteError,
    HandleTakenError,
    NotOrgMemberError,
    OrgFullError,
    OwnerCannotLeaveError,
    get_jobcard,
    init_db,
    insert_jobcard,
    list_jobcards,
    update_jobcard,
)
from extraction import ExtractionError, extract_jobcard
from logo_storage import (
    SVG_EXTENSION,
    InvalidLogoError,
    delete_shop_logo,
    get_active_logo_path,
    has_custom_logo,
    save_shop_logo,
)
from pdf_generator import generate_jobcard_pdf
from schemas import (
    BillingStatusResponse,
    CheckoutSessionRequest,
    CheckoutSessionResponse,
    DeviceRegisterRequest,
    DeviceRegisterResponse,
    DeviceSessionListResponse,
    DeviceSessionResponse,
    HandleClaimRequest,
    InviteCreateRequest,
    InviteResponse,
    JobCardResponse,
    JobCardUpdate,
    MemberResponse,
    OrganizationCreateRequest,
    OrganizationResponse,
    PortalSessionRequest,
    PortalSessionResponse,
    ProcessAudioResponse,
    SeatUpdateRequest,
    ShopLogoStatus,
    UserProfile,
)
import devices
from limits import enforce_rate_limit, read_upload_capped
from scoping import OwnerScope, resolve_owner_scope
from starlette.concurrency import run_in_threadpool

from transcription import TranscriptionBusy, preload_model, transcribe_audio_async

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# A hallucinated filler phrase (e.g. "Thank you.") from near-silent audio is
# still non-empty text, so a plain emptiness check isn't enough to catch it.
MIN_TRANSCRIPT_WORDS = 3

# /docs, /redoc and /openapi.json publish the entire route map and schemas to
# anyone. Off unless ENABLE_API_DOCS is set.
app = FastAPI(
    title="Geonix Wrench API",
    docs_url="/docs" if ENABLE_API_DOCS else None,
    redoc_url="/redoc" if ENABLE_API_DOCS else None,
    openapi_url="/openapi.json" if ENABLE_API_DOCS else None,
)

# Wildcard origins combined with allow_credentials made Starlette echo the
# caller's Origin back, which let any site call this API and read the response.
# ALLOWED_ORIGINS (comma-separated env var) overrides this list; the defaults
# are the public site, the API host itself and the local dev server.
DEFAULT_ALLOWED_ORIGINS = [
    "https://geonix.site",
    "https://api.geonix.site",
    "http://localhost:3000",
]

cors_origins = ALLOWED_ORIGINS or DEFAULT_ALLOWED_ORIGINS
if not ALLOWED_ORIGINS:
    logger.info(
        "ALLOWED_ORIGINS is unset - using the built-in origin list: %s",
        ", ".join(DEFAULT_ALLOWED_ORIGINS),
    )

app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

# Registered last, which makes it the OUTERMOST layer: add_middleware prepends,
# so the final call is the first to see a request and the last to touch a
# response. That ordering matters — CORSMiddleware answers preflights itself
# without calling inward, so a security layer registered before it would never
# see an OPTIONS response.
app.add_middleware(SecurityHeadersMiddleware)


@app.on_event("startup")
def on_startup() -> None:
    init_db()
    init_firebase_app()
    billing.init_stripe()
    # Loud on every boot: the offline extractor produces guesses, not
    # extractions, and a server left on it would quietly hand mechanics
    # keyword-matched job cards.
    if LLM_PROVIDER == "stub":
        logger.warning(
            "LLM_PROVIDER=stub - job cards are being generated OFFLINE by keyword "
            "matching, with no AI model. This is for development only; set "
            "LLM_PROVIDER=anthropic or =ollama before deploying."
        )
    logger.info("Loading Whisper model...")
    preload_model()
    logger.info("Whisper model ready")


@app.get("/health")
def health() -> dict:
    """Liveness probe for the container runtime and any reverse proxy.

    Unauthenticated and deliberately dull: it says the process is up and serving,
    nothing more. Every other route requires a Firebase token, so without this a
    health check either has to mint a real credential or read 403 as "healthy" —
    which would also read a broken auth config as healthy.

    It reports no version, uptime or dependency state, because this endpoint is
    reachable without credentials and none of that is anyone else's business.
    """
    return {"status": "ok"}


def _user_to_profile(user: dict) -> UserProfile:
    return UserProfile(
        id=user["id"],
        email=user["email"],
        handle=user["handle"],
        display_name=user["display_name"],
        org_id=user["org_id"],
        org_role=user["org_role"],
    )


def _org_to_response(org: dict) -> OrganizationResponse:
    sub = database.get_subscription("org", org["id"])
    return OrganizationResponse(
        id=org["id"],
        name=org["name"],
        seat_limit=org["seat_limit"],
        seat_used=database.count_org_members(org["id"]),
        owner_user_id=org["owner_user_id"],
        subscription_status=sub["status"] if sub else None,
        current_period_end=sub["current_period_end"] if sub else None,
    )


def _invite_to_response(invite: dict) -> InviteResponse:
    org = database.get_organization(invite["org_id"])
    inviter = database.get_user_by_id(invite["invited_by_user_id"])
    return InviteResponse(
        id=invite["id"],
        org_id=invite["org_id"],
        org_name=org["name"] if org else "",
        invited_by_handle=inviter["handle"] if inviter else None,
        status=invite["status"],
        created_at=invite["created_at"],
    )


def _require_org_owner(
    org_id: int,
    user: dict,
    detail: str = "Only the organization owner can do this",
) -> dict:
    org = database.get_organization(org_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found")
    if org["owner_user_id"] != user["id"]:
        raise HTTPException(status_code=403, detail=detail)
    return org


@app.post("/api/process-audio", response_model=ProcessAudioResponse)
async def process_audio(
    file: UploadFile = File(...), user: dict = Depends(get_paying_user)
) -> ProcessAudioResponse:
    # Transcription runs Whisper and then a paid model, so this route carries
    # its own tighter budget.
    enforce_rate_limit("audio", str(user["id"]), RATE_LIMIT_AUDIO_PER_WINDOW)

    ext = os.path.splitext(file.filename or "")[1].lower()
    if ext not in ALLOWED_AUDIO_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"Unsupported file type: {ext}")

    # Streamed to disk under a byte cap rather than buffered whole: the old
    # `tmp.write(await file.read())` had no ceiling at all.
    with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp:
        tmp_path = tmp.name
        try:
            await read_upload_capped(file, MAX_AUDIO_SIZE_BYTES, tmp.write)
        except HTTPException:
            os.unlink(tmp_path)
            raise

    try:
        try:
            transcribe_started = time.perf_counter()
            # Awaited, not called directly: this is a ~20s CPU burn, and running
            # it inline on the event loop stalled every other request in the
            # process — auth, billing, the lot — until it finished.
            transcript = await transcribe_audio_async(tmp_path)
            logger.info("Transcription took %.1fs", time.perf_counter() - transcribe_started)
        except TranscriptionBusy as e:
            raise HTTPException(
                status_code=503,
                detail="The server is busy transcribing other recordings. Please try again shortly.",
                headers={"Retry-After": str(e.retry_after_seconds)},
            ) from None
        except Exception:
            logger.exception("Transcription failed for %s", file.filename)
            raise HTTPException(status_code=502, detail="Audio transcription failed") from None

        if len(transcript.split()) < MIN_TRANSCRIPT_WORDS:
            raise HTTPException(
                status_code=422,
                detail="Recording did not contain enough usable speech",
            )

        try:
            extraction_started = time.perf_counter()
            # Also off the loop: the Anthropic client is synchronous, so calling
            # it inline blocked every other request for the length of the round
            # trip. Network-bound, so the shared thread pool is the right home.
            extraction = await run_in_threadpool(extract_jobcard, transcript)
            logger.info("Extraction took %.1fs", time.perf_counter() - extraction_started)
        except ExtractionError as e:
            # A permanent fault is ours to fix, not something the mechanic can
            # retry away — 500 so the app stops presenting it as transient.
            logger.error("Job card extraction failed (retryable=%s): %s", e.retryable, e.message)
            raise HTTPException(
                status_code=502 if e.retryable else 500, detail=e.message
            ) from None
        except Exception:
            logger.exception("Job card extraction failed for transcript: %r", transcript)
            raise HTTPException(status_code=502, detail="Job card extraction failed") from None
    finally:
        os.unlink(tmp_path)

    # Off the loop like the two stages above it. This is a synchronous SQLite
    # write inside an `async def`, so it ran *on* the event loop and stalled
    # every other request for the length of the insert — short, but it is the
    # last thing standing between the mechanic and their job card, and SQLite
    # writes serialise behind whatever else holds the database lock.
    jobcard_id = await run_in_threadpool(
        insert_jobcard, extraction, transcript, resolve_owner_scope(user)
    )
    return ProcessAudioResponse(transcript=transcript, extraction=extraction, jobcard_id=jobcard_id)


@app.get("/api/jobcards", response_model=list[JobCardResponse])
def get_jobcards(user: dict = Depends(get_current_user)) -> list[dict]:
    return list_jobcards(resolve_owner_scope(user))


@app.patch("/api/jobcards/{jobcard_id}", response_model=JobCardResponse)
def patch_jobcard(
    jobcard_id: int, update: JobCardUpdate, user: dict = Depends(get_paying_user)
) -> dict:
    owner = resolve_owner_scope(user)
    if get_jobcard(jobcard_id, owner) is None:
        raise HTTPException(status_code=404, detail="Job card not found")
    return update_jobcard(jobcard_id, update, owner)


@app.get("/api/jobcards/{jobcard_id}/pdf")
def get_jobcard_pdf(
    jobcard_id: int,
    user: dict = Depends(get_paying_user),
    x_currency: Optional[str] = Header(default=DEFAULT_CURRENCY),
    x_labor_rate: Optional[float] = Header(default=DEFAULT_LABOR_RATE),
) -> Response:
    # A header is not run through the pydantic bounds the body fields get, so
    # the floor is checked here; a negative rate prints a negative invoice.
    if x_labor_rate is None or x_labor_rate < 0:
        raise HTTPException(status_code=400, detail="X-Labor-Rate must be zero or greater")

    owner = resolve_owner_scope(user)
    jobcard = get_jobcard(jobcard_id, owner)
    if jobcard is None:
        raise HTTPException(status_code=404, detail="Job card not found")

    effective_labor_rate = jobcard["labor_rate"] if jobcard["labor_rate"] is not None else x_labor_rate
    # The owner scope selects the shop's own uploaded logo for the header,
    # falling back to the bundled default.
    pdf_bytes = generate_jobcard_pdf(
        jobcard, owner, currency=x_currency, labor_rate=effective_labor_rate
    )
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": f"inline; filename=jobcard_{jobcard_id}.pdf"},
    )


def _may_manage_logo(user: dict) -> bool:
    """Whether this caller may replace the logo their job cards carry.

    A mechanic with no shop is their own owner, so a solo account always may.
    Inside a shop the logo is one file shared by everyone (see _logo_path:
    every member resolves to the same org_<id> path), so one member changing it
    changes what appears on every colleague's invoices. That belongs to whoever
    owns the shop.
    """
    org_id = user.get("org_id")
    if org_id is None:
        return True
    org = database.get_organization(org_id)
    return org is not None and org["owner_user_id"] == user["id"]


def _require_logo_manager(user: dict) -> OwnerScope:
    """The write path's guard. Returns the scope to write to."""
    org_id = user.get("org_id")
    if org_id is not None:
        # Checked against the organization row rather than the user's cached
        # org_role, so a stale role column cannot hand out ownership.
        _require_org_owner(
            org_id, user, detail="Only the shop owner can change the shop logo"
        )
    return resolve_owner_scope(user)


@app.post("/api/shop-logo", response_model=ShopLogoStatus)
async def upload_shop_logo(
    file: UploadFile = File(...), user: dict = Depends(get_paying_user)
) -> ShopLogoStatus:
    # Before the upload is read: refusing a member after streaming their file
    # to the server wastes the bandwidth and the memory cap on a request that
    # was never going to be allowed.
    scope = _require_logo_manager(user)

    ext = os.path.splitext(file.filename or "")[1].lower()
    if ext not in ALLOWED_LOGO_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"Unsupported file type: {ext}")

    # Capped while streaming; this used to buffer the whole body and only then
    # measure it, so an oversized logo still cost full memory.
    chunks: list[bytes] = []
    await read_upload_capped(file, MAX_LOGO_SIZE_BYTES, chunks.append)
    data = b"".join(chunks)

    try:
        save_shop_logo(data, scope)
    except InvalidLogoError as e:
        raise HTTPException(status_code=400, detail=str(e)) from None

    return ShopLogoStatus(has_custom_logo=True, can_manage=True)


@app.get("/api/shop-logo/status", response_model=ShopLogoStatus)
def get_shop_logo_status(user: dict = Depends(get_current_user)) -> ShopLogoStatus:
    return ShopLogoStatus(
        has_custom_logo=has_custom_logo(resolve_owner_scope(user)),
        can_manage=_may_manage_logo(user),
    )


@app.get("/api/shop-logo")
def get_shop_logo(user: dict = Depends(get_current_user)) -> FileResponse:
    path = get_active_logo_path(resolve_owner_scope(user))
    is_svg = path.lower().endswith(SVG_EXTENSION)
    return FileResponse(
        path,
        media_type="image/svg+xml" if is_svg else "image/png",
        # An SVG is a document a browser will execute things inside. Uploads are
        # already screened for scripts and external references; these headers
        # are the second lock, so a logo can never act as a page on this origin.
        headers={
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox",
        }
        if is_svg
        else None,
    )


@app.delete("/api/shop-logo", response_model=ShopLogoStatus)
def remove_shop_logo(user: dict = Depends(get_paying_user)) -> ShopLogoStatus:
    delete_shop_logo(_require_logo_manager(user))
    return ShopLogoStatus(has_custom_logo=False, can_manage=True)


@app.get("/api/auth/me", response_model=UserProfile)
def get_me(user: dict = Depends(get_current_user)) -> UserProfile:
    return _user_to_profile(user)


@app.delete("/api/auth/me", status_code=204)
def delete_me(user: dict = Depends(get_current_user)) -> Response:
    """Close an account and erase its data.

    Required rather than optional: GDPR gives an EU customer the right to
    erasure, and the App Store will not list an app that creates accounts with
    no way to close one. This app is priced in EUR and sold to European shops,
    so both apply.

    Order matters. Billing is cancelled first — if that were last, a failure
    part-way through would leave a paying customer with no account and an
    unstoppable charge. The Firebase identity goes last, because until it is gone
    the caller's token still works and the request can still be retried.
    """
    cancelled = billing.cancel_subscriptions_for_account(user)

    try:
        summary = database.delete_user_account(user["id"])
    except database.OwnerMustDeleteOrgError as e:
        raise HTTPException(status_code=409, detail=str(e)) from None
    except database.UserNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e)) from None

    # The stored logo is a file, not a row, so it needs removing separately.
    #
    # Only when it was theirs to remove. Inside a shop every member resolves
    # to the same org_<id> file, so deleting on the caller's scope regardless
    # meant an employee closing their account wiped the logo off every
    # colleague's future invoices. A member's departure leaves the shop's
    # branding alone; a solo account's logo goes with the account, and a
    # shop's goes with the shop (summary["org_id"] is set only when the caller
    # owned it and it was deleted here).
    if user["org_id"] is None or summary["org_id"] is not None:
        try:
            delete_shop_logo(resolve_owner_scope(user))
        except Exception:
            logger.exception("Could not delete shop logo for deleted user %s", user["id"])

    # Last, and deliberately not fatal: the rows are already gone, so failing
    # here would leave the caller unable to retry (their data is deleted) while
    # reporting failure. It is logged loudly instead so the orphan can be cleared.
    try:
        delete_firebase_user(user["firebase_uid"])
    except Exception:
        logger.exception(
            "Deleted user %s but could not remove their Firebase identity; "
            "delete uid %s by hand",
            user["id"],
            user["firebase_uid"],
        )

    logger.info(
        "Deleted account %s: %s job cards, org %s, cancelled subscriptions %s",
        user["id"],
        summary["jobcards"],
        summary["org_id"],
        cancelled or "none",
    )
    return Response(status_code=204)


@app.post("/api/auth/handle", response_model=UserProfile)
def claim_handle(payload: HandleClaimRequest, user: dict = Depends(get_current_user)) -> UserProfile:
    try:
        handle = validate_handle(payload.handle)
    except InvalidHandleError as e:
        raise HTTPException(status_code=400, detail=str(e)) from None

    try:
        updated = database.set_user_handle(user["id"], handle)
    except HandleTakenError as e:
        raise HTTPException(status_code=409, detail=str(e)) from None

    return _user_to_profile(updated)


@app.post("/api/organizations", response_model=OrganizationResponse)
def create_organization(
    payload: OrganizationCreateRequest, user: dict = Depends(get_current_user)
) -> OrganizationResponse:
    # The seat limit is never taken from the request: it is whatever the owner
    # actually paid for. Letting the client choose meant a shop could be created
    # with more seats than were purchased.
    pending = billing.pending_team_subscription(user)
    seat_limit = (pending["quantity"] if pending else None) or TEAM_MIN_SEATS

    try:
        org = database.create_organization(user["id"], payload.name, seat_limit)
    except AlreadyInOrgError as e:
        raise HTTPException(status_code=400, detail=str(e)) from None

    if pending is not None:
        # Hand the Team subscription over to the shop it was bought for.
        billing.attach_subscription_to_org(subscription=pending, org_id=org["id"])
        org = database.get_organization(org["id"]) or org

    return _org_to_response(org)


@app.get("/api/organizations/me", response_model=OrganizationResponse)
def get_my_organization(user: dict = Depends(get_current_user)) -> OrganizationResponse:
    if user["org_id"] is None:
        raise HTTPException(status_code=404, detail="Not a member of any organization")

    org = database.get_organization(user["org_id"])
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found")

    return _org_to_response(org)


@app.delete("/api/organizations/{org_id}")
def delete_organization_route(org_id: int, user: dict = Depends(get_current_user)) -> Response:
    _require_org_owner(org_id, user)
    database.delete_organization(org_id)
    return Response(status_code=204)


@app.delete("/api/organizations/me/leave")
def leave_organization(user: dict = Depends(get_current_user)) -> Response:
    try:
        database.leave_organization(user["id"])
    except (NotOrgMemberError, OwnerCannotLeaveError) as e:
        raise HTTPException(status_code=400, detail=str(e)) from None

    return Response(status_code=204)


@app.get("/api/organizations/{org_id}/members", response_model=list[MemberResponse])
def get_organization_members(org_id: int, user: dict = Depends(get_current_user)) -> list[dict]:
    if user["org_id"] != org_id:
        raise HTTPException(status_code=403, detail="Not a member of this organization")

    return [
        MemberResponse(
            id=member["id"],
            handle=member["handle"],
            display_name=member["display_name"],
            org_role=member["org_role"],
        )
        for member in database.list_org_members(org_id)
    ]


@app.delete("/api/organizations/{org_id}/members/{user_id}")
def remove_organization_member(
    org_id: int, user_id: int, user: dict = Depends(get_current_user)
) -> Response:
    org = _require_org_owner(org_id, user)
    if user_id == org["owner_user_id"] or user_id == user["id"]:
        raise HTTPException(status_code=400, detail="Cannot remove the owner or yourself this way")

    try:
        database.remove_org_member(org_id, user_id)
    except NotOrgMemberError as e:
        raise HTTPException(status_code=404, detail=str(e)) from None

    return Response(status_code=204)


@app.post("/api/organizations/{org_id}/invites", response_model=InviteResponse)
def create_organization_invite(
    org_id: int, payload: InviteCreateRequest, user: dict = Depends(get_current_user)
) -> InviteResponse:
    _require_org_owner(org_id, user)

    target = database.get_user_by_handle(payload.handle.strip().lower())
    if target is None:
        raise HTTPException(status_code=404, detail="No user with that handle")

    try:
        invite = database.create_invite(org_id, target["id"], user["id"])
    except DuplicateInviteError as e:
        raise HTTPException(status_code=409, detail=str(e)) from None
    except AlreadyInOrgError as e:
        raise HTTPException(status_code=400, detail=str(e)) from None

    return _invite_to_response(invite)


@app.get("/api/organizations/{org_id}/invites", response_model=list[InviteResponse])
def list_organization_invites(org_id: int, user: dict = Depends(get_current_user)) -> list[InviteResponse]:
    _require_org_owner(org_id, user)
    return [_invite_to_response(invite) for invite in database.list_pending_invites_for_org(org_id)]


@app.delete("/api/organizations/{org_id}/invites/{invite_id}")
def revoke_organization_invite(
    org_id: int, invite_id: int, user: dict = Depends(get_current_user)
) -> Response:
    _require_org_owner(org_id, user)

    invite = database.get_invite(invite_id)
    if invite is None or invite["org_id"] != org_id:
        raise HTTPException(status_code=404, detail="Invite not found")

    database.revoke_invite(invite_id)
    return Response(status_code=204)


@app.get("/api/invites/me", response_model=list[InviteResponse])
def list_my_invites(user: dict = Depends(get_current_user)) -> list[InviteResponse]:
    return [_invite_to_response(invite) for invite in database.list_pending_invites_for_user(user["id"])]


def _require_own_pending_invite(invite_id: int, user: dict) -> dict:
    invite = database.get_invite(invite_id)
    if invite is None or invite["invited_user_id"] != user["id"] or invite["status"] != "pending":
        raise HTTPException(status_code=404, detail="Invite not found")
    return invite


@app.post("/api/invites/{invite_id}/accept", response_model=UserProfile)
def accept_invite(invite_id: int, user: dict = Depends(get_current_user)) -> UserProfile:
    _require_own_pending_invite(invite_id, user)

    try:
        database.respond_to_invite(invite_id, accept=True)
    except OrgFullError as e:
        raise HTTPException(status_code=409, detail=str(e)) from None
    except AlreadyInOrgError as e:
        raise HTTPException(status_code=400, detail=str(e)) from None

    updated_user = database.get_user_by_id(user["id"])

    # Joining a shop as an employee drops the device allowance from three to
    # one, and the devices already signed in do not ask again — a tablet left
    # signed in on a bench would keep working indefinitely on the old quota.
    # Bringing the account into line here is what makes the employee limit mean
    # anything for an account that had a personal subscription first.
    #
    # The caller's own device is the most recently used one by definition (it
    # is making this request), and eviction takes the least recently used, so
    # accepting an invite never signs out the phone doing the accepting.
    surplus = database.enforce_device_limit(
        updated_user["id"], devices.resolve_device_limit(updated_user)
    )
    if surplus:
        logger.info(
            "User %s joined org %s; signed out %s device(s) over the employee limit",
            updated_user["id"],
            updated_user["org_id"],
            len(surplus),
        )

    return _user_to_profile(updated_user)


@app.post("/api/invites/{invite_id}/decline", response_model=InviteResponse)
def decline_invite(invite_id: int, user: dict = Depends(get_current_user)) -> InviteResponse:
    _require_own_pending_invite(invite_id, user)
    invite = database.respond_to_invite(invite_id, accept=False)
    return _invite_to_response(invite)


# ══ devices ═══════════════════════════════════════════════════════════════
# How many devices an account may be signed in on, and which ones they are.
# See devices.py for the quota and database.device_sessions for why a stateless
# Firebase token needs a table behind it to be revocable at all.
#
# Every route here uses `get_current_user_without_device`, which checks the
# token but not the device. That is deliberate and is the whole reason the
# split dependency exists:
#
#   * registration has to work before a session exists, and
#   * a user who has hit the ceiling must still be able to reach this list to
#     free a slot — enforcing the quota on the screen that fixes the quota
#     would be a locked door with the key behind it.


def _device_to_response(session: dict, current_id: Optional[int]) -> DeviceSessionResponse:
    return DeviceSessionResponse(
        id=session["id"],
        device_name=session["device_name"],
        platform=session["platform"],
        created_at=session["created_at"],
        last_seen_at=session["last_seen_at"],
        is_current=current_id is not None and session["id"] == current_id,
    )


def _calling_device_session_id(request: Request, user: dict) -> Optional[int]:
    """Row id of the device making this request, if it is registered."""
    raw = request.headers.get(devices.DEVICE_ID_HEADER)
    device_id = raw.strip()[:DEVICE_ID_MAX_LENGTH] if raw else None
    if not device_id:
        return None
    session = database.find_device_session(user["id"], device_id)
    return session["id"] if session else None


@app.post("/api/auth/session", response_model=DeviceRegisterResponse)
def register_device(
    payload: DeviceRegisterRequest,
    user: dict = Depends(get_current_user_without_device),
) -> DeviceRegisterResponse:
    """Claim a device slot. The app calls this immediately after signing in.

    Safe to call on every launch: a device already signed in just refreshes its
    name here and consumes no second slot.

    It is also the only way back for a device that was signed out — an ordinary
    request from an evicted device gets a 401 instead, so eviction cannot be
    undone by the evicted device simply carrying on.
    """
    limit = devices.resolve_device_limit(user)
    try:
        result = database.register_device_session(
            user_id=user["id"],
            device_id=payload.device_id,
            device_name=devices.clean_device_name(payload.device_name),
            platform=devices.clean_device_name(payload.platform),
            limit=limit,
            evict_oldest=devices.evicts_oldest(),
        )
    except database.DeviceLimitReachedError:
        raise devices.device_limit_exception() from None

    session = result["session"]
    evicted = result["evicted"]
    if evicted:
        logger.info(
            "User %s signed in a new device; signed out %s to stay within %s",
            user["id"],
            len(evicted),
            limit,
        )

    return DeviceRegisterResponse(
        device=_device_to_response(session, session["id"]),
        limit=limit,
        used=database.count_active_device_sessions(user["id"]),
        evicted=len(evicted),
    )


@app.get("/api/auth/devices", response_model=DeviceSessionListResponse)
def list_devices(
    request: Request,
    user: dict = Depends(get_current_user_without_device),
) -> DeviceSessionListResponse:
    current_id = _calling_device_session_id(request, user)
    sessions = database.list_device_sessions(user["id"])
    return DeviceSessionListResponse(
        devices=[_device_to_response(s, current_id) for s in sessions],
        limit=devices.resolve_device_limit(user),
        used=len(sessions),
    )


@app.delete("/api/auth/devices/{session_id}", response_model=DeviceSessionListResponse)
def revoke_device(
    session_id: int,
    request: Request,
    user: dict = Depends(get_current_user_without_device),
) -> DeviceSessionListResponse:
    """Sign one of your own devices out.

    404 rather than 403 for someone else's session id: the id is scoped to the
    caller in the query, so a probe cannot tell a stranger's device from one
    that never existed.
    """
    try:
        database.revoke_device_session(user["id"], session_id)
    except database.DeviceSessionNotFoundError:
        raise HTTPException(status_code=404, detail="Device not found") from None

    current_id = _calling_device_session_id(request, user)
    sessions = database.list_device_sessions(user["id"])
    return DeviceSessionListResponse(
        devices=[_device_to_response(s, current_id) for s in sessions],
        limit=devices.resolve_device_limit(user),
        used=len(sessions),
    )


@app.post("/api/billing/checkout-session", response_model=CheckoutSessionResponse)
def create_checkout_session_route(
    payload: CheckoutSessionRequest, user: dict = Depends(get_current_user)
) -> CheckoutSessionResponse:
    checkout_url = billing.create_checkout_session(
        plan=payload.plan,
        quantity=payload.quantity,
        user=user,
        success_url=payload.success_url,
        cancel_url=payload.cancel_url,
        country=payload.country,
    )
    return CheckoutSessionResponse(checkout_url=checkout_url)


@app.get("/api/billing/status", response_model=BillingStatusResponse)
def get_billing_status_route(
    user: dict = Depends(get_current_user),
    reconcile: bool = False,
    country: Optional[str] = None,
) -> BillingStatusResponse:
    status = billing.get_billing_status(user, country)

    # Returning from checkout, the app asks for reconcile=1. If we still show
    # nothing active, go and ask Stripe rather than trusting that the webhook
    # arrived — it cannot reach a local dev server, and can be missed in
    # production. Gated on `reconcile` and on not already being active so the
    # ordinary polling path never pays for a Stripe round-trip.
    if reconcile and not status["is_active"]:
        if billing.reconcile_from_stripe(user):
            status = billing.get_billing_status(user, country)

    return BillingStatusResponse(**status)


@app.post("/api/billing/seats", response_model=BillingStatusResponse)
def update_team_seats_route(
    payload: SeatUpdateRequest, user: dict = Depends(get_current_user)
) -> BillingStatusResponse:
    return BillingStatusResponse(
        **billing.update_team_seats(
            user=user, quantity=payload.quantity, country=payload.country
        )
    )


@app.post("/api/billing/portal-session", response_model=PortalSessionResponse)
def create_portal_session_route(
    payload: PortalSessionRequest, user: dict = Depends(get_current_user)
) -> PortalSessionResponse:
    return PortalSessionResponse(
        portal_url=billing.create_portal_session(user=user, return_url=payload.return_url)
    )


@app.post("/api/billing/webhook")
async def billing_webhook(request: Request) -> Response:
    payload = await request.body()
    sig_header = request.headers.get("stripe-signature")
    billing.handle_webhook_event(payload, sig_header)
    return Response(content='{"received": true}', media_type="application/json")


# ══ website ═══════════════════════════════════════════════════════════════
# Everything below must stay at the bottom of this file. Starlette matches
# routes in registration order and the mount below claims "/", so anything
# declared after it is unreachable.

# The site moved from page.html to clean directory URLs, but builds of the app
# that are already on people's phones still hold the old .html links — and one
# of them is where Stripe returns a customer after checkout. Sending those to a
# 404 would strand someone who has just paid, so the old paths keep working.
_LEGACY_PAGE_REDIRECTS = {
    "/index.html": "/",
    "/geonix_wrench.html": "/geonixwrench/",
    "/privacy.html": "/privacy/",
    "/terms.html": "/terms/",
    "/wrench-billing-success.html": "/billing/success/",
    "/wrench-billing-cancel.html": "/billing/cancel/",
}


def _register_legacy_redirect(old_path: str, new_path: str) -> None:
    # A factory, not a loop body closing over the loop variable: the closure
    # would capture the name, and every route would redirect to the last pair.
    @app.get(old_path, include_in_schema=False)
    def _redirect() -> RedirectResponse:
        return RedirectResponse(new_path, status_code=301)


for _old, _new in _LEGACY_PAGE_REDIRECTS.items():
    _register_legacy_redirect(_old, _new)


# html=True is what makes the extensionless URLs work: /geonixwrench has no
# file behind it, it is a directory, and StaticFiles serves the index.html
# inside it. build.py in the website repo is what lays the tree out that way.
#
# The guard is for development. StaticFiles raises at import time if the
# directory is absent, so without it every dev machine and CI runner — none of
# which have /var/www — would fail to start the backend at all.
if FRONTEND_DIST_DIR and os.path.isdir(FRONTEND_DIST_DIR):
    app.mount(
        "/",
        StaticFiles(directory=FRONTEND_DIST_DIR, html=True),
        name="static",
    )
    logger.info("Serving the website from %s", FRONTEND_DIST_DIR)
else:
    logger.info(
        "FRONTEND_DIST_DIR (%s) is not a directory - the API is running without "
        "the website. Build it with geonix_website/build.py and point "
        "FRONTEND_DIST_DIR at the result.",
        FRONTEND_DIST_DIR or "unset",
    )

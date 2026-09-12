import logging
from datetime import datetime, timezone
from typing import Optional
from urllib.parse import urlsplit

import stripe
from fastapi import HTTPException

import database
import devices
import email_service
import regions
from config import (
    ALLOWED_RETURN_HOSTS,
    BILLING_CURRENCY,
    STRIPE_API_KEY,
    STRIPE_MANAGED_PAYMENTS,
    STRIPE_WEBHOOK_SECRET,
    TEAM_MIN_SEATS,
)

logger = logging.getLogger(__name__)

ACTIVE_SUBSCRIPTION_STATUSES = {"active", "trialing"}

PLANS = ("individual", "team")

# The detail on the 402 the paid routes answer with. Named so the app can
# recognise it and open the plan picker instead of showing a generic error.
SUBSCRIPTION_REQUIRED_DETAIL = "An active subscription is required for this."


def init_stripe() -> None:
    stripe.api_key = STRIPE_API_KEY


def is_account_active(user: dict) -> bool:
    """Whether this account is currently paid for, on the server's own record.

    The app checks its cached billing status before recording, but the API
    used to take the app's word for it: every route only required a valid
    Firebase token, and signing up for one is self-service. Anyone could
    call the transcription endpoint directly and run Whisper and a paid model
    on this server without ever subscribing. This is the server-side answer,
    read fresh from the subscriptions table on each call.

    A shop member is covered by the shop's Team subscription; everyone else
    by their own.
    """
    if user.get("org_id") is not None:
        sub = database.get_subscription("org", user["org_id"])
    else:
        sub = database.get_subscription("user", user["id"])
    return sub is not None and sub["status"] in ACTIVE_SUBSCRIPTION_STATUSES


def _validate_return_url(url: str, field: str) -> str:
    """Refuse a redirect target that is not one of our own pages.

    Stripe sends the customer wherever these say, and they arrive from the
    client. Restricting the host is what stops an account holder minting a
    Stripe-branded page that lands somewhere of their choosing.
    """
    parts = urlsplit(url or "")
    host = (parts.hostname or "").lower()
    if parts.scheme not in ("http", "https") or not host or host not in ALLOWED_RETURN_HOSTS:
        raise HTTPException(
            status_code=400,
            detail=f"{field} must point at one of: {', '.join(sorted(ALLOWED_RETURN_HOSTS))}",
        )
    return url


def _field(payload, key: str, default=None):
    """Read `key` from a Stripe payload, dict or `StripeObject` alike.

    As of stripe>=15 a `StripeObject` is *not* a dict subclass and has no
    `.get()` — attribute lookup falls through to `__getattr__`, which raises
    AttributeError. Plain `payload.get(key)` therefore works perfectly against
    the dicts used in tests and blows up against every real API response, which
    is exactly how the webhook handler shipped broken: it could never have
    synced a live subscription.
    """
    if payload is None:
        return default
    if isinstance(payload, dict):
        return payload.get(key, default)
    try:
        value = payload[key]
    except (KeyError, AttributeError, TypeError):
        return default
    return default if value is None else value


def _items_of(payload) -> list:
    """The line items of a subscription payload, in either representation."""
    items = _field(payload, "items")
    return _field(items, "data") or []


def _rows_of(listing) -> list:
    """The rows of a Stripe list response, in either representation."""
    if listing is None:
        return []
    if isinstance(listing, dict):
        return listing.get("data") or []
    # ListObject exposes `.data` and is iterable; it has no `.get`.
    return list(getattr(listing, "data", None) or [])


def create_checkout_session(
    *,
    plan: str,
    quantity: Optional[int],
    user: dict,
    success_url: str,
    cancel_url: str,
    country: Optional[str] = None,
) -> str:
    if plan not in PLANS:
        raise HTTPException(status_code=400, detail=f"Unknown plan: {plan}")
    _validate_return_url(success_url, "success_url")
    _validate_return_url(cancel_url, "cancel_url")

    # Regional pricing: the app sends the device's country and the matching
    # Stripe price is charged. See regions.py for the mapping and its limits.
    pricing = regions.pricing_for_country(country)
    price_id = (
        pricing["individual_price_id"] if plan == "individual" else pricing["team_price_id"]
    )

    if plan == "individual":
        if user["org_id"] is not None:
            raise HTTPException(
                status_code=400,
                detail="The Individual plan is for solo mechanics without a shop",
            )
        scope_type, scope_id, line_quantity = "user", user["id"], 1
    else:
        if quantity is None:
            raise HTTPException(status_code=400, detail="quantity is required for the Team plan")
        if quantity < TEAM_MIN_SEATS:
            raise HTTPException(
                status_code=400,
                detail=f"The Team plan requires at least {TEAM_MIN_SEATS} seats",
            )
        if user["org_id"] is None:
            # Buying seats before the shop exists. Requiring a shop first was a
            # dead end: the buyer had to guess a seat count while creating the
            # shop, then pay for it separately. The subscription is held against
            # the buyer and moves onto the shop when they name it, so the seats
            # they paid for are the seats the shop gets.
            scope_type, scope_id = "user", user["id"]
        else:
            if user["org_role"] != "owner":
                raise HTTPException(
                    status_code=403,
                    detail="Only the shop owner can subscribe to the Team plan",
                )
            scope_type, scope_id = "org", user["org_id"]
        line_quantity = quantity

    try:
        session = stripe.checkout.Session.create(
            mode="subscription",
            line_items=[{"price": price_id, "quantity": line_quantity}],
            customer_email=user["email"],
            success_url=success_url,
            cancel_url=cancel_url,
            # Stripe Checkout hides the "Add promotion code" field unless this
            # is set, so every coupon we issued was unredeemable: the customer
            # had nowhere to type the code. Note this accepts *promotion codes*,
            # not coupon IDs — a coupon needs a promotion code created against
            # it before anyone can enter it.
            allow_promotion_codes=True,
            # See STRIPE_MANAGED_PAYMENTS in config: our products carry no tax
            # code, which Managed Payments requires, so it must be opted out of
            # explicitly or Stripe rejects the session outright.
            managed_payments={"enabled": STRIPE_MANAGED_PAYMENTS},
            subscription_data={
                "metadata": {
                    "scope_type": scope_type,
                    "scope_id": str(scope_id),
                    "plan": plan,
                    # The effective pricing region, recorded so a subscription
                    # can be attributed to its rate without reverse-engineering
                    # the price id.
                    "region": pricing["region"],
                }
            },
        )
    except stripe.error.StripeError:
        logger.exception("Failed to create Stripe checkout session")
        raise HTTPException(status_code=502, detail="Could not start checkout with Stripe") from None

    if not session.url:
        raise HTTPException(status_code=502, detail="Stripe did not return a checkout URL")

    return session.url


def create_portal_session(*, user: dict, return_url: str) -> str:
    """Open the Stripe Billing Portal for whoever owns the subscription.

    Previously a customer could subscribe but had no way to cancel, change a
    card or fetch an invoice without emailing us. Stripe hosts all of that.
    """
    _validate_return_url(return_url, "return_url")
    if user["org_id"] is not None:
        if user["org_role"] != "owner":
            raise HTTPException(
                status_code=403,
                detail="Only the shop owner can manage the subscription",
            )
        sub = database.get_subscription("org", user["org_id"])
    else:
        sub = database.get_subscription("user", user["id"])

    if sub is None or not sub["stripe_customer_id"]:
        raise HTTPException(status_code=400, detail="No subscription to manage yet")

    try:
        session = stripe.billing_portal.Session.create(
            customer=sub["stripe_customer_id"],
            return_url=return_url,
        )
    except stripe.error.StripeError:
        logger.exception("Failed to create Stripe billing portal session")
        raise HTTPException(
            status_code=502, detail="Could not open the billing portal"
        ) from None

    if not session.url:
        raise HTTPException(status_code=502, detail="Stripe did not return a portal URL")
    return session.url


def _device_quota(user: dict) -> dict:
    """The device allowance for this account, for the subscription panel.

    Served from the billing status rather than a separate call because the app
    shows it on the plan card, right beside the seat count — a second round
    trip would leave that one line loading after the rest of the card had
    rendered.
    """
    return {
        "device_limit": devices.resolve_device_limit(user),
        "device_used": database.count_active_device_sessions(user["id"]),
    }


def get_billing_status(user: dict, country: Optional[str] = None) -> dict:
    # The advertised figures follow the caller's region, resolved fresh on each
    # read from the country the app sends. Stripe still charges whatever price
    # object the subscription was created with.
    pricing = regions.pricing_for_country(country)

    if user["org_id"] is not None:
        org = database.get_organization(user["org_id"])
        if org is None:
            return {"scope_type": "user", "status": None, "is_active": False}
        sub = database.get_subscription("org", org["id"])
        is_active = sub is not None and sub["status"] in ACTIVE_SUBSCRIPTION_STATUSES
        return {
            "scope_type": "org",
            "status": sub["status"] if sub else None,
            "is_active": is_active,
            "current_period_end": sub["current_period_end"] if sub else None,
            "seat_limit": org["seat_limit"],
            "seat_used": database.count_org_members(org["id"]),
            "plan": sub["plan"] if sub else "team",
            # The client renders the seat stepper against this rather than a
            # hardcoded 2, so the floor stays defined in one place.
            "min_seats": TEAM_MIN_SEATS,
            "team_min_seats": TEAM_MIN_SEATS,
            "price_per_seat": pricing["team_price_per_seat"],
            "individual_price": pricing["individual_price_per_month"],
            "team_price_per_seat": pricing["team_price_per_seat"],
            "region": pricing["region"],
            "needs_shop": False,
            "currency": BILLING_CURRENCY,
            "can_manage_seats": is_active and user["org_role"] == "owner",
            # Owner and employee sit on the same Team subscription and get
            # different device quotas, so this is resolved from the role rather
            # than from the plan. See devices.resolve_device_limit.
            **_device_quota(user),
        }

    sub = database.get_subscription("user", user["id"])
    is_active = sub is not None and sub["status"] in ACTIVE_SUBSCRIPTION_STATUSES
    plan = sub["plan"] if sub else "individual"
    # A Team subscription sitting at user scope was bought before the shop
    # existed. The seats are already paid for; the shop just has to be named.
    awaiting_shop = is_active and plan == "team"
    seats_bought = (sub["quantity"] if sub else None) or TEAM_MIN_SEATS
    return {
        "scope_type": "user",
        "status": sub["status"] if sub else None,
        "is_active": is_active,
        "current_period_end": sub["current_period_end"] if sub else None,
        "seat_limit": (seats_bought if awaiting_shop else 1) if is_active else None,
        "seat_used": 1 if is_active else None,
        "plan": plan,
        "min_seats": TEAM_MIN_SEATS if awaiting_shop else 1,
        # Unconditional, unlike min_seats: the plan picker shows the Team card
        # to users in every scope and its stepper floor must not depend on
        # which plan the caller happens to be on.
        "team_min_seats": TEAM_MIN_SEATS,
        # Tells the app to prompt for a shop name; it must not offer a seat
        # count there, because the count is whatever was purchased.
        "needs_shop": awaiting_shop,
        "price_per_seat": pricing["individual_price_per_month"],
        "individual_price": pricing["individual_price_per_month"],
        "team_price_per_seat": pricing["team_price_per_seat"],
        "region": pricing["region"],
        "currency": BILLING_CURRENCY,
        "can_manage_seats": False,
        **_device_quota(user),
    }


def _subscription_belongs_to(subscription, user: dict) -> bool:
    """True if this Stripe subscription is scoped to this user or their org."""
    metadata = _field(subscription, "metadata") or {}
    scope_type = _field(metadata, "scope_type")
    scope_id_raw = _field(metadata, "scope_id")
    if scope_id_raw is None:
        return False
    try:
        scope_id = int(scope_id_raw)
    except (TypeError, ValueError):
        return False

    if scope_type == "user":
        return scope_id == user["id"]
    if scope_type == "org":
        return user["org_id"] is not None and scope_id == user["org_id"]
    return False


def reconcile_from_stripe(user: dict) -> bool:
    """Ask Stripe directly for a subscription we have not recorded.

    The webhook is the normal path, but it is not a dependable one: Stripe
    cannot reach a local dev server at all, and in production a delivery can be
    missed, delayed or replayed against a server that was down. Until this
    existed, a completed checkout left the customer charged with nothing
    unlocked and no way to recover but to replay the event by hand.

    Returns True if anything was written.
    """
    email = user.get("email")
    if not email:
        return False

    try:
        customers = stripe.Customer.list(email=email, limit=10)
    except stripe.error.StripeError:
        logger.exception("Could not list Stripe customers for reconciliation")
        return False

    candidates = []
    for customer in _rows_of(customers):
        customer_id = _field(customer, "id")
        try:
            subscriptions = stripe.Subscription.list(
                customer=customer_id, status="all", limit=20
            )
        except stripe.error.StripeError:
            logger.exception("Could not list subscriptions for customer %s", customer_id)
            continue
        for subscription in _rows_of(subscriptions):
            if _subscription_belongs_to(subscription, user):
                candidates.append(subscription)

    if not candidates:
        return False

    # An account can carry a cancelled subscription alongside a live one. Sync
    # the live one so reconciliation can only ever unlock, never revoke.
    active = [
        s for s in candidates if _field(s, "status") in ACTIVE_SUBSCRIPTION_STATUSES
    ]
    chosen = active[0] if active else None
    if chosen is None:
        # Nothing live. Only record a terminal state if we have no row at all,
        # so this cannot clobber something the webhook already knows better.
        metadata = _field(candidates[0], "metadata") or {}
        scope_type = _field(metadata, "scope_type")
        try:
            scope_id = int(_field(metadata, "scope_id"))
        except (TypeError, ValueError):
            return False
        if database.get_subscription(scope_type, scope_id) is not None:
            return False
        chosen = candidates[0]

    _sync_subscription(chosen)
    return True


def pending_team_subscription(user: dict) -> Optional[dict]:
    """An active Team subscription bought before the buyer had a shop."""
    sub = database.get_subscription("user", user["id"])
    if (
        sub is not None
        and sub["plan"] == "team"
        and sub["status"] in ACTIVE_SUBSCRIPTION_STATUSES
    ):
        return sub
    return None


def attach_subscription_to_org(*, subscription: dict, org_id: int) -> None:
    """Move a user-scoped Team subscription onto the shop it paid for."""
    database.move_subscription_scope(
        from_scope_type="user",
        from_scope_id=subscription["scope_id"],
        to_scope_type="org",
        to_scope_id=org_id,
    )

    # The Stripe metadata is what routes future webhooks. Without repointing it,
    # the next subscription event would recreate the row back at user scope and
    # the shop would silently lose its seats.
    if subscription["stripe_subscription_id"]:
        try:
            stripe.Subscription.modify(
                subscription["stripe_subscription_id"],
                metadata={
                    "scope_type": "org",
                    "scope_id": str(org_id),
                    "plan": "team",
                },
            )
        except stripe.error.StripeError:
            logger.exception(
                "Could not repoint subscription %s at org %s; webhooks will "
                "still resolve to the buyer until this is corrected",
                subscription["stripe_subscription_id"],
                org_id,
            )


def update_team_seats(*, user: dict, quantity: int, country: Optional[str] = None) -> dict:
    """Change the seat count on an existing Team subscription.

    Purchasing seats was already possible at checkout, but the count was frozen
    afterwards — the owner had no way to hire or lose staff. This modifies the
    Stripe subscription item quantity and lets Stripe prorate the difference.
    """
    if user["org_id"] is None:
        raise HTTPException(status_code=400, detail="Seats apply to the Team plan only")
    if user["org_role"] != "owner":
        raise HTTPException(status_code=403, detail="Only the shop owner can change seats")
    if quantity < TEAM_MIN_SEATS:
        raise HTTPException(
            status_code=400,
            detail=f"The Team plan requires at least {TEAM_MIN_SEATS} seats",
        )

    sub = database.get_subscription("org", user["org_id"])
    if sub is None or sub["status"] not in ACTIVE_SUBSCRIPTION_STATUSES:
        raise HTTPException(status_code=400, detail="No active Team subscription to update")
    if not sub["stripe_subscription_id"]:
        raise HTTPException(status_code=400, detail="This subscription is not linked to Stripe")

    # Downgrading below the headcount would leave members without a seat, and
    # nothing else in the system evicts them — refuse instead of overselling.
    seats_used = database.count_org_members(user["org_id"])
    if quantity < seats_used:
        raise HTTPException(
            status_code=400,
            detail=f"{seats_used} seats are in use. Remove members before reducing to {quantity}.",
        )

    try:
        stripe_sub = stripe.Subscription.retrieve(sub["stripe_subscription_id"])
        items = _items_of(stripe_sub)
        if not items:
            raise HTTPException(status_code=502, detail="Stripe subscription has no line items")
        stripe.Subscription.modify(
            sub["stripe_subscription_id"],
            items=[{"id": _field(items[0], "id"), "quantity": quantity}],
            proration_behavior="create_prorations",
        )
    except stripe.error.StripeError:
        logger.exception("Failed to update Stripe subscription seats")
        raise HTTPException(status_code=502, detail="Could not update seats with Stripe") from None

    # customer.subscription.updated will land shortly and re-sync this, but the
    # webhook may lag or not be forwarded at all in local dev — write it now so
    # the response the owner sees already reflects the new count.
    database.set_org_seat_limit(user["org_id"], quantity)
    database.upsert_subscription(
        scope_type="org",
        scope_id=user["org_id"],
        stripe_subscription_id=sub["stripe_subscription_id"],
        stripe_customer_id=sub["stripe_customer_id"],
        plan=sub["plan"],
        status=sub["status"],
        quantity=quantity,
        current_period_end=sub["current_period_end"],
    )
    return get_billing_status(user, country)


def cancel_subscriptions_for_account(user: dict) -> list:
    """Cancel whatever this account is paying for, immediately.

    Called when an account is deleted. Without it the Stripe subscription
    outlives the account it belonged to and the customer keeps being charged for
    something they can no longer sign in to — the worst failure mode a paid
    product has, and one they cannot fix themselves afterwards.

    Best-effort by design: the deletion still goes through if Stripe is
    unreachable, because someone exercising their right to erasure cannot be made
    to wait on a third party. Returns the ids it cancelled so the caller can log
    them. A subscription left behind is recoverable from the Stripe dashboard; a
    refused deletion is not recoverable at all.
    """
    cancelled = []
    scopes = [("user", user["id"])]
    if user.get("org_id") is not None and user.get("org_role") == "owner":
        scopes.append(("org", user["org_id"]))

    for scope_type, scope_id in scopes:
        record = database.get_subscription(scope_type, scope_id)
        subscription_id = (record or {}).get("stripe_subscription_id")
        if not subscription_id:
            continue
        try:
            stripe.Subscription.delete(subscription_id)
            cancelled.append(subscription_id)
        except Exception:
            logger.exception(
                "Could not cancel subscription %s while deleting %s %s; "
                "it must be cancelled by hand in Stripe",
                subscription_id,
                scope_type,
                scope_id,
            )

    return cancelled


def handle_webhook_event(payload: bytes, sig_header: Optional[str]) -> str:
    try:
        event = stripe.Webhook.construct_event(payload, sig_header, STRIPE_WEBHOOK_SECRET)
    except (ValueError, stripe.error.SignatureVerificationError):
        raise HTTPException(status_code=400, detail="Invalid webhook signature") from None

    event_type = event["type"]
    if event_type in (
        "customer.subscription.created",
        "customer.subscription.updated",
        "customer.subscription.deleted",
    ):
        _sync_subscription(event["data"]["object"])
    elif event_type in ("invoice.payment_failed", "invoice.payment_succeeded"):
        # Without these, a subscription that lapses for non-payment kept
        # reporting its last known status until some other event arrived.
        _sync_from_invoice(event["data"]["object"], event_type)
    else:
        logger.info("Ignoring unhandled Stripe event: %s", event_type)

    return event_type


def _sync_from_invoice(invoice, event_type: str) -> None:
    """Re-read the subscription an invoice belongs to and store its status."""
    subscription_id = _field(invoice, "subscription")
    if not subscription_id:
        logger.info("Invoice %s has no subscription; ignoring", _field(invoice, "id"))
        return

    try:
        subscription = stripe.Subscription.retrieve(subscription_id)
    except stripe.error.StripeError:
        logger.exception("Could not re-read subscription %s after %s", subscription_id, event_type)
        return

    logger.info(
        "%s for subscription %s -> status %s",
        event_type,
        subscription_id,
        _field(subscription, "status"),
    )
    _sync_subscription(subscription)


def _sync_subscription(subscription) -> None:
    metadata = _field(subscription, "metadata") or {}
    scope_type = _field(metadata, "scope_type")
    scope_id_raw = _field(metadata, "scope_id")
    if scope_type not in ("user", "org") or scope_id_raw is None:
        logger.warning(
            "Subscription %s has no scope metadata; ignoring",
            _field(subscription, "id"),
        )
        return
    try:
        scope_id = int(scope_id_raw)
    except (TypeError, ValueError):
        logger.warning("Subscription %s has a non-numeric scope_id", _field(subscription, "id"))
        return

    items = _items_of(subscription)
    item = items[0] if items else None
    price_id = _field(_field(item, "price"), "id")
    plan = _field(metadata, "plan") or regions.plan_for_price_id(price_id)
    quantity = _field(item, "quantity")
    status = _field(subscription, "status") or "canceled"

    # Read before the upsert overwrites it — this is what tells a brand new
    # subscription apart from a renewal, proration or plan change firing the
    # same webhook event.
    previous = database.get_subscription(scope_type, scope_id)
    was_active = previous is not None and previous["status"] in ACTIVE_SUBSCRIPTION_STATUSES

    database.upsert_subscription(
        scope_type=scope_type,
        scope_id=scope_id,
        stripe_subscription_id=_field(subscription, "id"),
        stripe_customer_id=_field(subscription, "customer"),
        plan=plan,
        status=status,
        quantity=quantity,
        current_period_end=_iso_period_end(_field(subscription, "current_period_end")),
    )

    if (
        scope_type == "org"
        and plan == "team"
        and quantity is not None
        and status in ACTIVE_SUBSCRIPTION_STATUSES
    ):
        database.set_org_seat_limit(scope_id, quantity)

    is_active = status in ACTIVE_SUBSCRIPTION_STATUSES
    if is_active and not was_active:
        _notify_new_subscription(scope_type=scope_type, scope_id=scope_id, plan=plan, quantity=quantity)


def _notify_new_subscription(
    *, scope_type: str, scope_id: int, plan: str, quantity: Optional[int]
) -> None:
    """Email whoever pays for the subscription the moment it first goes live.

    Fires once per subscription — see the was_active/is_active check in
    _sync_subscription — not on every renewal or seat-count webhook.
    """
    if scope_type == "org":
        org = database.get_organization(scope_id)
        recipient = database.get_user_by_id(org["owner_user_id"]) if org else None
    else:
        recipient = database.get_user_by_id(scope_id)

    if recipient is None:
        logger.warning(
            "Could not find a recipient for the new %s subscription at %s %s",
            plan,
            scope_type,
            scope_id,
        )
        return

    email_service.send_subscription_confirmation(
        email=recipient["email"], plan=plan, seats=quantity
    )


def _iso_period_end(unix_ts: Optional[int]) -> Optional[str]:
    if not unix_ts:
        return None
    return datetime.fromtimestamp(int(unix_ts), tz=timezone.utc).isoformat()

import logging
from datetime import datetime, timezone
from typing import Optional

import stripe
from fastapi import HTTPException

import database
from config import (
    INDIVIDUAL_PRICE_ID,
    STRIPE_API_KEY,
    STRIPE_WEBHOOK_SECRET,
    TEAM_MIN_SEATS,
    TEAM_PRICE_ID,
)

logger = logging.getLogger(__name__)

ACTIVE_SUBSCRIPTION_STATUSES = {"active", "trialing"}

PLAN_PRICES = {
    "individual": INDIVIDUAL_PRICE_ID,
    "team": TEAM_PRICE_ID,
}


def init_stripe() -> None:
    stripe.api_key = STRIPE_API_KEY


def _plan_from_price(price_id: Optional[str]) -> str:
    if price_id == TEAM_PRICE_ID:
        return "team"
    if price_id == INDIVIDUAL_PRICE_ID:
        return "individual"
    return "unknown"


def create_checkout_session(
    *,
    plan: str,
    quantity: Optional[int],
    user: dict,
    success_url: str,
    cancel_url: str,
) -> str:
    if plan not in PLAN_PRICES:
        raise HTTPException(status_code=400, detail=f"Unknown plan: {plan}")

    if plan == "individual":
        if user["org_id"] is not None:
            raise HTTPException(
                status_code=400,
                detail="The Individual plan is for solo mechanics without a shop",
            )
        scope_type, scope_id, line_quantity = "user", user["id"], 1
    else:
        if user["org_id"] is None:
            raise HTTPException(
                status_code=400,
                detail="Create a shop first, then subscribe it to the Team plan",
            )
        if user["org_role"] != "owner":
            raise HTTPException(
                status_code=403,
                detail="Only the shop owner can subscribe to the Team plan",
            )
        if quantity is None:
            raise HTTPException(status_code=400, detail="quantity is required for the Team plan")
        if quantity < TEAM_MIN_SEATS:
            raise HTTPException(
                status_code=400,
                detail=f"The Team plan requires at least {TEAM_MIN_SEATS} seats",
            )
        scope_type, scope_id, line_quantity = "org", user["org_id"], quantity

    try:
        session = stripe.checkout.Session.create(
            mode="subscription",
            line_items=[{"price": PLAN_PRICES[plan], "quantity": line_quantity}],
            customer_email=user["email"],
            success_url=success_url,
            cancel_url=cancel_url,
            subscription_data={
                "metadata": {
                    "scope_type": scope_type,
                    "scope_id": str(scope_id),
                    "plan": plan,
                }
            },
        )
    except stripe.error.StripeError:
        logger.exception("Failed to create Stripe checkout session")
        raise HTTPException(status_code=502, detail="Could not start checkout with Stripe") from None

    if not session.url:
        raise HTTPException(status_code=502, detail="Stripe did not return a checkout URL")

    return session.url


def get_billing_status(user: dict) -> dict:
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
        }

    sub = database.get_subscription("user", user["id"])
    is_active = sub is not None and sub["status"] in ACTIVE_SUBSCRIPTION_STATUSES
    return {
        "scope_type": "user",
        "status": sub["status"] if sub else None,
        "is_active": is_active,
        "current_period_end": sub["current_period_end"] if sub else None,
        "seat_limit": 1 if is_active else None,
        "seat_used": 1 if is_active else None,
    }


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
    else:
        logger.info("Ignoring unhandled Stripe event: %s", event_type)

    return event_type


def _sync_subscription(subscription: dict) -> None:
    metadata = subscription.get("metadata") or {}
    scope_type = metadata.get("scope_type")
    scope_id_raw = metadata.get("scope_id")
    if scope_type not in ("user", "org") or scope_id_raw is None:
        logger.warning("Subscription %s has no scope metadata; ignoring", subscription.get("id"))
        return
    scope_id = int(scope_id_raw)

    items = (subscription.get("items") or {}).get("data") or []
    item = items[0] if items else None
    price_id = (item or {}).get("price", {}).get("id")
    plan = metadata.get("plan") or _plan_from_price(price_id)
    quantity = (item or {}).get("quantity")
    status = subscription.get("status") or "canceled"

    database.upsert_subscription(
        scope_type=scope_type,
        scope_id=scope_id,
        stripe_subscription_id=subscription.get("id"),
        stripe_customer_id=subscription.get("customer"),
        plan=plan,
        status=status,
        quantity=quantity,
        current_period_end=_iso_period_end(subscription.get("current_period_end")),
    )

    if (
        scope_type == "org"
        and plan == "team"
        and quantity is not None
        and status in ACTIVE_SUBSCRIPTION_STATUSES
    ):
        database.set_org_seat_limit(scope_id, quantity)


def _iso_period_end(unix_ts: Optional[int]) -> Optional[str]:
    if not unix_ts:
        return None
    return datetime.fromtimestamp(int(unix_ts), tz=timezone.utc).isoformat()

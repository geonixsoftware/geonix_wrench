"""Verify the advertised prices match what Stripe will actually charge.

The app and website display INDIVIDUAL_PRICE_PER_MONTH / TEAM_PRICE_PER_SEAT,
but Stripe bills whatever the price objects are set to in the dashboard. If the
two drift, a customer is quoted one amount and charged another.

Run after changing a price, in either place:

    python -m price_check

Exits non-zero on a mismatch so it can be wired into a deploy check.
"""

import sys

import stripe

from config import (
    BILLING_CURRENCY,
    INDIVIDUAL_PRICE_ID,
    INDIVIDUAL_PRICE_PER_MONTH,
    STRIPE_API_KEY,
    TEAM_PRICE_ID,
    TEAM_PRICE_PER_SEAT,
)


def _check(label: str, price_id: str, advertised: float) -> bool:
    if not price_id:
        print(f"  !! {label}: no price id configured")
        return False

    try:
        price = stripe.Price.retrieve(price_id)
    # Not stripe.error.StripeError: that alias was removed in stripe-python 8,
    # and naming it raised AttributeError *inside* the handler — turning a clean
    # "could not read this price" into a crash.
    except stripe.StripeError as e:
        print(f"  !! {label}: could not read {price_id} from Stripe — {e}")
        return False

    # Subscript, not .get(): a StripeObject is dict-like but does not implement
    # .get, and calling it raised AttributeError. That is why this script had
    # never produced a result — it crashed on its own first comparison, which
    # looked like "never run" rather than "broken".
    actual = (price["unit_amount"] or 0) / 100
    currency = (price["currency"] or "").upper()

    ok = abs(actual - advertised) < 0.005 and currency == BILLING_CURRENCY.upper()
    mark = "OK " if ok else "!! "
    print(f"  {mark}{label}: advertised {advertised:.2f} {BILLING_CURRENCY} / Stripe {actual:.2f} {currency}")
    if not ok:
        print(f"      -> fix the price in the Stripe dashboard, or change the value in config.py")
    return ok


def main() -> int:
    if not STRIPE_API_KEY:
        print("STRIPE_API_KEY is not set; cannot verify prices.")
        return 2

    stripe.api_key = STRIPE_API_KEY
    print("Comparing advertised prices with Stripe:")
    results = [
        _check("Individual (per month)", INDIVIDUAL_PRICE_ID, INDIVIDUAL_PRICE_PER_MONTH),
        _check("Team (per seat)", TEAM_PRICE_ID, TEAM_PRICE_PER_SEAT),
    ]

    if all(results):
        print("All advertised prices match Stripe.")
        return 0

    print("\nMISMATCH: customers would be quoted a different price than they are billed.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

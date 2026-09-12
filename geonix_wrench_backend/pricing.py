"""How a parts line becomes money on an invoice.

A part can be priced two ways, and only one of them used to exist. The line
amount was always `unit_price * quantity`, so a mechanic who knows the figure
that matters — "forty-eight euros of oil went into this car" — had to work
backwards to a per-litre price the invoice would multiply back up. That round
trip does not survive contact with cents:

    50.00 for 3 litres -> 16.666...  -> typed as 16.67 -> printed as 50.01

The customer is billed a cent more than the shop meant to charge, and no field
on the screen says 50.00 anywhere. Oils, coolants and other fluids are bought
and priced by the container, not the litre, so this is the normal case for
them rather than an edge case.

So a part now carries both figures and `total_price` wins where it is set:

    total_price is not None -> the line amount IS that number, untouched
    unit_price is not None  -> the line amount is unit_price * quantity
    neither                 -> nothing to bill yet (TBD)

The per-unit figure shown beside a total-priced line is *derived for display*
and never multiplied back up, which is what keeps the printed amount equal to
the number the mechanic actually typed.
"""

from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from typing import Any, Mapping, Optional

# Currency amounts are settled to cents once, here, so that a column of line
# amounts adds up to the printed subtotal. Rounding at render time instead lets
# the sum of what is shown differ from the total that is shown.
#
# Decimal, not round(): 3 x 16.665 is 49.995, and `round(49.995, 2)` is 49.99 —
# both because floats cannot hold 49.995 exactly and because round() breaks
# ties to even. An invoice rounds a half-cent up, the way the shop and the
# customer both expect, and neither of them cares about binary floating point.
_CENTS = Decimal("0.01")


def _to_decimal(value: Any) -> Optional[Decimal]:
    """A number as exact decimal digits, or None if it isn't one.

    Via str() so that 0.1 is the 0.1 someone typed rather than the binary
    fraction nearest to it.
    """
    if value is None or isinstance(value, bool):
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return None


def _settle(amount: Decimal) -> float:
    return float(amount.quantize(_CENTS, rounding=ROUND_HALF_UP))


def line_total(part: Mapping[str, Any]) -> Optional[float]:
    """What this line bills, or None when it is still unpriced.

    A stated total is authoritative: it is returned as given (settled to cents)
    rather than being re-derived from a rounded unit price.
    """
    total = _to_decimal(part.get("total_price"))
    if total is not None:
        return _settle(total)

    unit = _to_decimal(part.get("unit_price"))
    if unit is None:
        return None

    quantity = _to_decimal(part.get("quantity")) or Decimal(0)
    return _settle(unit * quantity)


def effective_unit_price(part: Mapping[str, Any]) -> Optional[float]:
    """The per-unit figure to show in the Rate column, or None.

    Derived from the total when that is what the shop entered, so the invoice
    still answers "what did one litre cost?" without that derived number ever
    feeding back into the amount. None when a total was given for a zero
    quantity — there is no meaningful per-unit price to print.
    """
    total = _to_decimal(part.get("total_price"))
    if total is None:
        unit = _to_decimal(part.get("unit_price"))
        return float(unit) if unit is not None else None

    quantity = _to_decimal(part.get("quantity")) or Decimal(0)
    if quantity <= 0:
        return None
    return float(total / quantity)


def format_quantity(value: Any) -> str:
    """A quantity as it belongs on an invoice.

    Whole amounts print bare — "4 litres", not "4.0 litres" — while fractional
    ones keep the precision the mechanic entered, trimmed of trailing zeros.
    """
    try:
        number = float(value)
    except (TypeError, ValueError):
        return str(value)

    if number == int(number):
        return str(int(number))
    # Three decimals is past anything a shop measures in and still short of
    # float noise ("4.199999999999999").
    return f"{number:.3f}".rstrip("0").rstrip(".")

"""What a parts line bills.

The bug these cover: the line amount was always `unit_price * quantity`, so a
shop that knew the total for a fill of oil had to divide it down to a per-litre
price the invoice then multiplied back up. The division does not survive cents,
and the customer was billed a figure that appeared nowhere on the job card.
"""

import pytest

from pricing import effective_unit_price, format_quantity, line_total


def _part(**overrides):
    part = {"part_name": "5W-30 oil", "quantity": 4}
    part.update(overrides)
    return part


# --------------------------------------------------------------- line amounts


def test_a_stated_total_is_billed_exactly():
    # The regression in one line: 50.00 across 3 litres is 16.666… per litre,
    # which rounds to 16.67 and multiplies back to 50.01. The shop said fifty.
    part = _part(quantity=3, total_price=50.00)
    assert line_total(part) == 50.00


def test_a_unit_price_still_multiplies_by_quantity():
    assert line_total(_part(quantity=4, unit_price=12.50)) == 50.00


def test_a_total_wins_when_both_prices_are_present():
    # Both can arrive together — an extraction that filled one and a mechanic
    # who typed the other. The figure entered for the whole job is the one the
    # customer was quoted.
    part = _part(quantity=4, unit_price=99.99, total_price=48.00)
    assert line_total(part) == 48.00


def test_an_unpriced_part_has_no_amount():
    assert line_total(_part()) is None


def test_a_fractional_quantity_bills_correctly():
    assert line_total(_part(quantity=0.5, unit_price=9.00)) == 4.50


def test_amounts_settle_to_cents():
    # 3 x 16.665 is 49.995. Rounding here rather than at render time is what
    # keeps a column of printed lines adding up to the printed subtotal.
    assert line_total(_part(quantity=3, unit_price=16.665)) == 50.00


def test_a_zero_quantity_with_a_total_still_bills_the_total():
    # A drum of something charged as one line, quantity not recorded. The money
    # is real even when the count is not.
    assert line_total(_part(quantity=0, total_price=30.00)) == 30.00


def test_junk_in_a_stored_row_does_not_crash_the_invoice():
    # parts_used is a JSON blob written by several client versions.
    assert line_total(_part(quantity="four", unit_price=10.00)) == 0.00
    assert line_total(_part(unit_price="free")) is None


# ------------------------------------------------------------- displayed rate


def test_the_rate_shown_for_a_total_priced_line_is_derived():
    part = _part(quantity=4, total_price=48.00)
    assert effective_unit_price(part) == 12.00


def test_the_derived_rate_is_never_multiplied_back_into_the_amount():
    # The whole point. 50.00 over 3 litres shows a rate that cannot be printed
    # exactly, while the amount stays the number the shop entered.
    part = _part(quantity=3, total_price=50.00)
    assert effective_unit_price(part) == pytest.approx(16.6666, rel=1e-3)
    assert line_total(part) == 50.00


def test_a_unit_priced_line_shows_the_price_as_entered():
    assert effective_unit_price(_part(unit_price=12.50)) == 12.50


def test_a_total_over_zero_quantity_has_no_meaningful_rate():
    assert effective_unit_price(_part(quantity=0, total_price=30.00)) is None


def test_an_unpriced_part_has_no_rate():
    assert effective_unit_price(_part()) is None


# ---------------------------------------------------------------- quantities


@pytest.mark.parametrize(
    "value,expected",
    [
        (4, "4"),
        (4.0, "4"),
        (0.5, "0.5"),
        (2.25, "2.25"),
        # Float noise must not reach an invoice as "4.199999999999999".
        (4.2, "4.2"),
        (0, "0"),
    ],
)
def test_quantities_print_the_way_a_shop_writes_them(value, expected):
    assert format_quantity(value) == expected

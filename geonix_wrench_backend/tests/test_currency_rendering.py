"""Money on a job card, in the money the shop actually charges in.

Two faults, both visible to a paying customer:

  * The PDF printed "Currency: USD" under the table while the app had already
    labelled each amount. A code tells the customer nothing the figures do not.

  * The backend knew six currencies and the app offered ten, overlapping on
    only EUR and GBP. Eight of the app's ten fell through to the USD default,
    so a Czech shop's invoice was priced in dollars — silently, with a "$" in
    front of koruna figures.
"""

import io

import pytest
from pypdf import PdfReader

import currency
from pdf_generator import generate_jobcard_pdf
from scoping import OwnerScope


def _card():
    return {
        "id": 7,
        "vehicle_info": "Skoda Octavia",
        "work_performed": "Brake pads replaced",
        "labor_hours": 2.0,
        "parts_used": [{"part_name": "Brake pads", "quantity": 2, "unit_price": 500.0}],
        "unbilled_items_flagged": [],
        "created_at": "2026-08-19T10:00:00+00:00",
    }


def _text(raw_currency):
    pdf = generate_jobcard_pdf(
        _card(), OwnerScope(org_id=None, user_id=1), currency=raw_currency, labor_rate=400.0
    )
    return "\n".join(page.extract_text() or "" for page in PdfReader(io.BytesIO(pdf)).pages)


# ── the app's list and the API's list must not drift ────────────────────

@pytest.mark.parametrize("code", currency.APP_CURRENCY_CODES)
def test_every_currency_the_app_offers_is_understood(code):
    # The regression this guards: CZK was absent, so it defaulted to USD.
    assert currency.is_supported(code), f"{code} is offered in the app but unknown here"
    assert currency.normalize(code) == code


@pytest.mark.parametrize(
    "code, symbol",
    [("EUR", "€"), ("CZK", "Kč"), ("PLN", "zł"), ("GBP", "£"),
     ("CHF", "Fr"), ("SEK", "kr"), ("HUF", "Ft"), ("RON", "lei")],
)
def test_symbols_match_the_flutter_client(code, symbol):
    assert currency.symbol_for(code) == symbol


# ── normalisation ───────────────────────────────────────────────────────

@pytest.mark.parametrize(
    "raw, expected",
    [("USD", "USD"), ("czk", "CZK"), ("  eur  ", "EUR"),
     ("currency: USD", "USD"), ("Currency = CZK", "CZK"), ("currency:EUR", "EUR"),
     ("€", "EUR"), ("Kč", "CZK"),
     ("", "EUR"), (None, "EUR"), ("bogus", "EUR")],
)
def test_normalize(raw, expected):
    assert currency.normalize(raw) == expected


def test_a_labelled_value_is_not_treated_as_unknown(raw="currency: CZK"):
    # Before, this fell to the default and repriced the invoice.
    assert currency.normalize(raw) == "CZK"
    assert currency.symbol_for(raw) == "Kč"


# ── placement and grouping ──────────────────────────────────────────────

def test_symbol_leads_where_that_is_the_convention():
    assert currency.format_amount(1234.5, "EUR") == "€1,234.50"
    assert currency.format_amount(1234.5, "USD") == "$1,234.50"


def test_symbol_trails_where_that_is_the_convention():
    # "Kč 1,234.50" is not how a Czech invoice reads.
    #
    # The separators are non-breaking spaces (U+00A0) on purpose: a plain space
    # lets reportlab wrap a total across two lines mid-number, and "1" at the
    # end of one line with "234,50 Kč" at the start of the next is a figure a
    # customer can misread.
    assert currency.format_amount(1234.5, "CZK") == "1\u00a0234,50\u00a0Kč"
    assert currency.format_amount(1234.5, "PLN") == "1\u00a0234,50\u00a0zł"
    assert currency.format_amount(1234.5, "SEK") == "1\u00a0234,50\u00a0kr"


def test_grouping_uses_a_non_breaking_space():
    assert "\u00a0" in currency.format_amount(1234.5, "CZK")
    # ...and the prefix currencies keep the comma grouping their locales use.
    assert currency.format_amount(1234.5, "EUR") == "€1,234.50"


# ── what actually lands in the PDF ──────────────────────────────────────

def test_no_three_letter_code_is_printed():
    text = _text("CZK")
    assert "Currency:" not in text
    for code in currency.APP_CURRENCY_CODES:
        assert code not in text, f"the PDF still prints the code {code}"


def test_amounts_carry_the_symbol():
    assert "Kč" in _text("CZK")
    assert "€" in _text("EUR")
    assert "zł" in _text("PLN")


def test_an_unknown_currency_does_not_silently_become_dollars():
    # EUR is the default now: the shops this is sold to are European, and a
    # wrong-but-plausible "$" was the worst possible failure here.
    assert currency.normalize("XYZ") == "EUR"
    assert "$" not in _text("XYZ")


def test_labour_rate_and_totals_all_use_it():
    text = _text("CZK")
    # rate line, line amount, subtotal — all three, not just the total
    assert text.count("Kč") >= 3

"""Turning a currency setting into something a customer can read on an invoice.

The job card used to print a three-letter code — "Currency: USD" under the
table, and amounts the app had already labelled with a symbol. A customer does
not want a code; they want to see what they are being asked to pay in the money
they pay in.

Two things made that worse than cosmetic:

  * The backend knew six currencies (USD, EUR, GBP, ZAR, AUD, CAD) while the
    app offered ten (EUR, CZK, PLN, GBP, CHF, SEK, NOK, DKK, HUF, RON). Only
    EUR and GBP were in both, so a shop that picked Czech koruna had its
    invoices silently priced in *dollars* — the unknown code fell back to the
    USD default and printed "$".

  * Kč, zł, kr, Ft and lei follow their amount rather than lead it. "Kč 1
    234,56" is not how a Czech invoice is written.
"""

from typing import Dict, NamedTuple


class Currency(NamedTuple):
    code: str
    symbol: str
    # True where the symbol is written after the amount, as it is across
    # central and northern Europe.
    suffix: bool


# Every currency the app can be set to, plus the ones the API already accepted.
# Symbols match AppCurrencyDetails.symbol in the Flutter client exactly; if one
# side gains a currency the other has to follow, or the fallback below silently
# reprices somebody's invoice.
_CURRENCIES: Dict[str, Currency] = {
    # In the app's picker
    "EUR": Currency("EUR", "€", suffix=False),
    "CZK": Currency("CZK", "Kč", suffix=True),
    "PLN": Currency("PLN", "zł", suffix=True),
    "GBP": Currency("GBP", "£", suffix=False),
    "CHF": Currency("CHF", "Fr", suffix=False),
    "SEK": Currency("SEK", "kr", suffix=True),
    "NOK": Currency("NOK", "kr", suffix=True),
    "DKK": Currency("DKK", "kr", suffix=True),
    "HUF": Currency("HUF", "Ft", suffix=True),
    "RON": Currency("RON", "lei", suffix=True),
    # Kept from the previous list so existing callers do not regress
    "USD": Currency("USD", "$", suffix=False),
    "ZAR": Currency("ZAR", "R", suffix=False),
    "AUD": Currency("AUD", "A$", suffix=False),
    "CAD": Currency("CAD", "C$", suffix=False),
}

DEFAULT_CURRENCY_CODE = "EUR"

# Codes the app offers, for the tests that keep the two lists in step.
APP_CURRENCY_CODES = ("EUR", "CZK", "PLN", "GBP", "CHF", "SEK", "NOK", "DKK", "HUF", "RON")


def normalize(raw: object) -> str:
    """Best-effort read of whatever arrived as the currency setting.

    Accepts a bare code, a symbol, or a labelled string. The label case is real:
    values have reached this layer as "currency: USD" and been treated as an
    unknown currency, which then fell back to the default and priced the invoice
    in the wrong money rather than failing visibly.
    """
    if raw is None:
        return DEFAULT_CURRENCY_CODE

    text = str(raw).strip()
    if not text:
        return DEFAULT_CURRENCY_CODE

    # "currency: USD", "Currency = CZK", "currency-EUR"
    for separator in (":", "="):
        if separator in text:
            text = text.rsplit(separator, 1)[-1].strip()

    candidate = text.upper()
    if candidate in _CURRENCIES:
        return candidate

    # A symbol rather than a code. Ambiguous ones (kr) resolve to the first
    # match, which is the best that can be done without more context.
    for entry in _CURRENCIES.values():
        if text == entry.symbol:
            return entry.code

    return DEFAULT_CURRENCY_CODE


def symbol_for(raw: object) -> str:
    return _CURRENCIES[normalize(raw)].symbol


def format_amount(value: float, raw: object) -> str:
    """An amount as it belongs on an invoice in that currency.

    Thousands are grouped with a non-breaking space and the decimal mark is a
    comma wherever the symbol trails the amount — that pairing is what those
    locales use, and a European invoice reading "1,234.56 Kč" looks like a
    mistake to the person paying it.
    """
    entry = _CURRENCIES[normalize(raw)]
    if entry.suffix:
        body = f"{value:,.2f}".replace(",", " ").replace(".", ",")
        return f"{body} {entry.symbol}"
    return f"{entry.symbol}{value:,.2f}"


def is_supported(raw: object) -> bool:
    """Whether this value was understood rather than silently defaulted."""
    if raw is None:
        return False
    text = str(raw).strip()
    for separator in (":", "="):
        if separator in text:
            text = text.rsplit(separator, 1)[-1].strip()
    return text.upper() in _CURRENCIES or any(
        text == c.symbol for c in _CURRENCIES.values()
    )

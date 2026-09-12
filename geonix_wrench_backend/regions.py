"""Which price a customer sees and pays, by where they are.

Five pricing regions, resolved from an ISO 3166-1 alpha-2 country code:

    na      North America — the baseline price
    eu      Europe
    au      Australia
    latam   Latin America and the Caribbean
    row     everywhere else

The app sends the device's locale country with every billing call and the
server resolves it here, so the mapping lives in exactly one place. The country
is client-reported, not verified: someone determined to pay the Latin America
price can send "BR" from Berlin. That is accepted deliberately — regional
pricing is a discount for markets that need it, not a security boundary, and an
IP-geolocation database is not worth carrying for it.

The invariant that IS enforced: the figure a customer is quoted and the Stripe
price they are charged always come from the same region. A region whose Stripe
price objects have not been created yet falls back to the baseline entirely —
ids and advertised figures together — rather than quoting its own figure and
charging the baseline's.
"""

from typing import Optional

import config

REGION_NA = "na"
REGION_EU = "eu"
REGION_AU = "au"
REGION_LATAM = "latam"
REGION_ROW = "row"

# The region an unknown, missing or malformed country resolves to, and the one
# whose prices stand in for any region not yet configured in Stripe. The most
# expensive region on purpose: nobody stumbles into a discount by accident.
BASELINE_REGION = REGION_NA

# The US, Canada and their neighbours in the North Atlantic. Mexico is
# deliberately absent: it belongs to the Latin America region below.
NORTH_AMERICA = {"BM", "CA", "GL", "PM", "US"}

# Europe, geographically: the EU, EFTA, the UK, the microstates, the Balkans
# and the European post-Soviet states.
EUROPE = {
    "AD", "AL", "AT", "BA", "BE", "BG", "BY", "CH", "CY", "CZ", "DE", "DK",
    "EE", "ES", "FI", "FO", "FR", "GB", "GG", "GI", "GR", "HR", "HU", "IE",
    "IM", "IS", "IT", "JE", "LI", "LT", "LU", "LV", "MC", "MD", "ME", "MK",
    "MT", "NL", "NO", "PL", "PT", "RO", "RS", "RU", "SE", "SI", "SJ", "SK",
    "SM", "UA", "VA", "XK",
}

# Australia and its external territories. New Zealand is not included — it
# resolves to rest-of-world until it is deliberately priced.
AUSTRALIA = {"AU", "CC", "CX", "HM", "NF"}

# Latin America and the Caribbean, the UN grouping: Mexico, Central America,
# South America and the Caribbean islands.
LATIN_AMERICA = {
    "AG", "AI", "AR", "AW", "BB", "BL", "BO", "BQ", "BR", "BS", "BZ", "CL",
    "CO", "CR", "CU", "CW", "DM", "DO", "EC", "FK", "GD", "GF", "GP", "GT",
    "GY", "HN", "HT", "JM", "KN", "KY", "LC", "MF", "MQ", "MS", "MX", "NI",
    "PA", "PE", "PR", "PY", "SR", "SV", "SX", "TC", "TT", "UY", "VC", "VE",
    "VG", "VI",
}


def region_for_country(country: Optional[str]) -> str:
    """The pricing region for a country code, tolerant of what clients send.

    Anything that is not a recognisable two-letter code — missing, empty, or
    malformed — resolves to the baseline. An older app build that sends no
    country must get the standard price, not stumble into a discount.
    """
    if not country:
        return BASELINE_REGION
    code = country.strip().upper()
    if len(code) != 2 or not code.isalpha():
        return BASELINE_REGION
    if code in NORTH_AMERICA:
        return REGION_NA
    if code in EUROPE:
        return REGION_EU
    if code in AUSTRALIA:
        return REGION_AU
    if code in LATIN_AMERICA:
        return REGION_LATAM
    return REGION_ROW


def pricing_for_region(region: str) -> dict:
    """The price ids and advertised figures that apply to `region`.

    Returns the baseline entry when the region is unknown or its Stripe price
    ids are not configured yet — never a mixture. The entry's own "region" key
    names the region that actually applied, so callers report the effective
    one rather than the requested one.
    """
    baseline = config.REGION_PRICING[BASELINE_REGION]
    entry = config.REGION_PRICING.get(region)
    if entry is None:
        return baseline
    if not entry["individual_price_id"] or not entry["team_price_id"]:
        return baseline
    return entry


def pricing_for_country(country: Optional[str]) -> dict:
    return pricing_for_region(region_for_country(country))


def plan_for_price_id(price_id: Optional[str]) -> str:
    """Which plan a Stripe price id belongs to, across every region."""
    if not price_id:
        return "unknown"
    for entry in config.REGION_PRICING.values():
        if price_id == entry["team_price_id"]:
            return "team"
        if price_id == entry["individual_price_id"]:
            return "individual"
    return "unknown"

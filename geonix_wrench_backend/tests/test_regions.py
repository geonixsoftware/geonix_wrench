"""Regional pricing: country -> region -> the price quoted and charged.

The contract under test, exactly as specified:

    North America (baseline)    Individual €35   Team €60 / seat
    Europe                      Individual €29   Team €50 / seat
    Australia                   Individual €35   Team €60 / seat
    Latin America               Individual €10   Team €18 / seat
    Rest of world               Individual €10   Team €18 / seat

and the invariant that the quoted figure and the charged Stripe price always
come from the same region — a region without its own price objects falls back
to the baseline entirely.
"""

from fastapi.testclient import TestClient

import auth
import billing
import config
import database
import regions
from config import INDIVIDUAL_PRICE_ID, TEAM_PRICE_ID
from main import app


def _override_for(user_id):
    def _get_current_user():
        return database.get_user_by_id(user_id)

    return _get_current_user


def _make_client(temp_db, user_id):
    app.dependency_overrides[auth.get_current_user] = _override_for(user_id)
    return TestClient(app)


def _make_user(email):
    return database.get_or_create_user(firebase_uid=f"uid-{email}", email=email)


def _clear_overrides():
    app.dependency_overrides.clear()


class _FakeSession:
    url = "https://checkout.stripe.com/test"


def _patch_session_create(monkeypatch):
    captured = {}

    def fake_create(**kwargs):
        captured.update(kwargs)
        return _FakeSession()

    monkeypatch.setattr(billing.stripe.checkout.Session, "create", staticmethod(fake_create))
    return captured


def _checkout_body(plan, **overrides):
    body = {
        "plan": plan,
        "success_url": "https://geonix.site/billing/success/",
        "cancel_url": "https://geonix.site/billing/cancel/",
    }
    body.update(overrides)
    return body


def _configure_region(monkeypatch, region, individual_id, team_id):
    monkeypatch.setitem(config.REGION_PRICING[region], "individual_price_id", individual_id)
    monkeypatch.setitem(config.REGION_PRICING[region], "team_price_id", team_id)


# ---------------------------------------------------------- country -> region


def test_north_america_maps_to_the_baseline():
    for country in ("US", "CA", "GL", "BM"):
        assert regions.region_for_country(country) == regions.REGION_NA
    assert regions.BASELINE_REGION == regions.REGION_NA


def test_europe_maps_to_eu():
    for country in ("DE", "FR", "CZ", "GB", "NO", "CH"):
        assert regions.region_for_country(country) == regions.REGION_EU


def test_australia_maps_to_au():
    for country in ("AU", "CX", "NF"):
        assert regions.region_for_country(country) == regions.REGION_AU


def test_latin_america_maps_to_latam():
    # Mexico belongs here, not in "North America" — the tier follows the
    # market, not the continental plate.
    for country in ("MX", "BR", "AR", "CO", "CL", "CU", "DO"):
        assert regions.region_for_country(country) == regions.REGION_LATAM


def test_everywhere_else_maps_to_rest_of_world():
    # NZ included deliberately: the Australia region is Australia and its
    # territories only, until New Zealand is priced on purpose.
    for country in ("IN", "ZA", "JP", "NZ", "TR", "NG"):
        assert regions.region_for_country(country) == regions.REGION_ROW


def test_missing_or_malformed_country_gets_the_baseline():
    # An older app build sends no country at all; it must get the standard
    # price, not stumble into a discount.
    for country in (None, "", "  ", "X", "USA", "1A"):
        assert regions.region_for_country(country) == regions.BASELINE_REGION


def test_country_codes_are_case_and_whitespace_insensitive():
    assert regions.region_for_country("br") == regions.REGION_LATAM
    assert regions.region_for_country(" de ") == regions.REGION_EU
    assert regions.region_for_country("au ") == regions.REGION_AU


# ------------------------------------------------------------- exact figures


def test_the_advertised_figures_match_the_pricing_spec():
    spec = {
        regions.REGION_NA: (35.0, 60.0),
        regions.REGION_EU: (29.0, 50.0),
        regions.REGION_AU: (35.0, 60.0),
        regions.REGION_LATAM: (10.0, 18.0),
        regions.REGION_ROW: (10.0, 18.0),
    }
    assert set(spec) == set(config.REGION_PRICING)
    for region, (individual, per_seat) in spec.items():
        entry = config.REGION_PRICING[region]
        assert entry["individual_price_per_month"] == individual
        assert entry["team_price_per_seat"] == per_seat


# ----------------------------------------------------------------- fallback


def test_unconfigured_region_falls_back_to_the_baseline_entirely(monkeypatch):
    # Ids AND figures together: quoting €29 while charging the €35 price
    # object is the drift this fallback exists to make impossible.
    _configure_region(monkeypatch, regions.REGION_EU, "", "")
    entry = regions.pricing_for_region(regions.REGION_EU)
    assert entry is config.REGION_PRICING[regions.BASELINE_REGION]


def test_configured_region_serves_its_own_prices(monkeypatch):
    _configure_region(monkeypatch, regions.REGION_EU, "price_eu_ind", "price_eu_team")
    entry = regions.pricing_for_region(regions.REGION_EU)
    assert entry["individual_price_id"] == "price_eu_ind"
    assert entry["individual_price_per_month"] == 29.0
    assert entry["team_price_per_seat"] == 50.0


def test_every_regional_price_id_resolves_to_its_plan(monkeypatch):
    _configure_region(monkeypatch, regions.REGION_ROW, "price_row_ind", "price_row_team")
    _configure_region(monkeypatch, regions.REGION_AU, "price_au_ind", "price_au_team")
    assert regions.plan_for_price_id("price_row_ind") == "individual"
    assert regions.plan_for_price_id("price_row_team") == "team"
    assert regions.plan_for_price_id("price_au_team") == "team"
    assert regions.plan_for_price_id(INDIVIDUAL_PRICE_ID) == "individual"
    assert regions.plan_for_price_id("price_unrelated") == "unknown"


# ----------------------------------------------------------------- checkout


def test_checkout_from_europe_charges_the_eu_price(temp_db, monkeypatch):
    _configure_region(monkeypatch, regions.REGION_EU, "price_eu_ind", "price_eu_team")
    captured = _patch_session_create(monkeypatch)
    user = _make_user("eu@example.com")
    client = _make_client(temp_db, user["id"])

    resp = client.post(
        "/api/billing/checkout-session", json=_checkout_body("individual", country="DE")
    )
    assert resp.status_code == 200
    assert captured["line_items"] == [{"price": "price_eu_ind", "quantity": 1}]
    assert captured["subscription_data"]["metadata"]["region"] == "eu"
    _clear_overrides()


def test_checkout_from_latin_america_charges_the_latam_price(temp_db, monkeypatch):
    _configure_region(monkeypatch, regions.REGION_LATAM, "price_latam_ind", "price_latam_team")
    captured = _patch_session_create(monkeypatch)
    user = _make_user("latam@example.com")
    client = _make_client(temp_db, user["id"])

    resp = client.post(
        "/api/billing/checkout-session", json=_checkout_body("individual", country="BR")
    )
    assert resp.status_code == 200
    assert captured["line_items"] == [{"price": "price_latam_ind", "quantity": 1}]
    assert captured["subscription_data"]["metadata"]["region"] == "latam"
    _clear_overrides()


def test_team_checkout_from_australia_charges_the_au_price(temp_db, monkeypatch):
    _configure_region(monkeypatch, regions.REGION_AU, "price_au_ind", "price_au_team")
    captured = _patch_session_create(monkeypatch)
    owner = _make_user("auteam@example.com")
    database.create_organization(owner["id"], "Shop", seat_limit=2)
    client = _make_client(temp_db, owner["id"])

    resp = client.post(
        "/api/billing/checkout-session", json=_checkout_body("team", quantity=3, country="AU")
    )
    assert resp.status_code == 200
    assert captured["line_items"] == [{"price": "price_au_team", "quantity": 3}]
    assert captured["subscription_data"]["metadata"]["region"] == "au"
    _clear_overrides()


def test_checkout_from_north_america_charges_the_baseline_price(temp_db, monkeypatch):
    captured = _patch_session_create(monkeypatch)
    user = _make_user("baseline@example.com")
    client = _make_client(temp_db, user["id"])

    resp = client.post(
        "/api/billing/checkout-session", json=_checkout_body("individual", country="US")
    )
    assert resp.status_code == 200
    assert captured["line_items"] == [{"price": INDIVIDUAL_PRICE_ID, "quantity": 1}]
    assert captured["subscription_data"]["metadata"]["region"] == "na"
    _clear_overrides()


def test_checkout_without_a_country_charges_the_baseline_price(temp_db, monkeypatch):
    # The request an older app build sends: no country field at all.
    captured = _patch_session_create(monkeypatch)
    owner = _make_user("nocountry@example.com")
    database.create_organization(owner["id"], "Shop", seat_limit=2)
    client = _make_client(temp_db, owner["id"])

    resp = client.post("/api/billing/checkout-session", json=_checkout_body("team", quantity=2))
    assert resp.status_code == 200
    assert captured["line_items"] == [{"price": TEAM_PRICE_ID, "quantity": 2}]
    _clear_overrides()


def test_checkout_from_unconfigured_region_charges_the_baseline_price(temp_db, monkeypatch):
    _configure_region(monkeypatch, regions.REGION_LATAM, "", "")
    captured = _patch_session_create(monkeypatch)
    user = _make_user("latamfallback@example.com")
    client = _make_client(temp_db, user["id"])

    resp = client.post(
        "/api/billing/checkout-session", json=_checkout_body("individual", country="BR")
    )
    assert resp.status_code == 200
    assert captured["line_items"] == [{"price": INDIVIDUAL_PRICE_ID, "quantity": 1}]
    assert captured["subscription_data"]["metadata"]["region"] == "na"
    _clear_overrides()


# ------------------------------------------------------------------- status


def test_status_quotes_the_regional_prices(temp_db, monkeypatch):
    _configure_region(monkeypatch, regions.REGION_EU, "price_eu_ind", "price_eu_team")
    _configure_region(monkeypatch, regions.REGION_LATAM, "price_latam_ind", "price_latam_team")
    user = _make_user("regionstatus@example.com")
    client = _make_client(temp_db, user["id"])

    body = client.get("/api/billing/status?country=DE").json()
    assert body["individual_price"] == 29.0
    assert body["team_price_per_seat"] == 50.0
    assert body["region"] == "eu"

    body = client.get("/api/billing/status?country=MX").json()
    assert body["individual_price"] == 10.0
    assert body["team_price_per_seat"] == 18.0
    assert body["region"] == "latam"
    _clear_overrides()


def test_status_quotes_the_baseline_when_the_region_is_unconfigured(temp_db, monkeypatch):
    # The figure shown must be the figure charged: with no EU price objects
    # the customer is charged the baseline, so €35/€60 is what they must see.
    _configure_region(monkeypatch, regions.REGION_EU, "", "")
    user = _make_user("eustatusfb@example.com")
    client = _make_client(temp_db, user["id"])

    body = client.get("/api/billing/status?country=DE").json()
    assert body["individual_price"] == config.INDIVIDUAL_PRICE_PER_MONTH
    assert body["team_price_per_seat"] == config.TEAM_PRICE_PER_SEAT
    assert body["region"] == "na"
    _clear_overrides()


def test_status_without_a_country_quotes_the_baseline(temp_db):
    user = _make_user("basestatus@example.com")
    client = _make_client(temp_db, user["id"])

    body = client.get("/api/billing/status").json()
    assert body["individual_price"] == config.INDIVIDUAL_PRICE_PER_MONTH
    assert body["team_price_per_seat"] == config.TEAM_PRICE_PER_SEAT
    assert body["region"] == "na"
    _clear_overrides()

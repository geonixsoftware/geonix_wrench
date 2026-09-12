"""The admin portal is private and its writes cannot be driven from elsewhere.

It used to have no authentication at all, on the reasoning that it listened
only on loopback. A browser does not treat loopback as a boundary: any page
open on the operator's machine could post to the hide/unhide routes or fetch
the subscriber list. Every route now needs the portal password, the posts
refuse cross-site requests, and the CSV exports cannot smuggle a spreadsheet
formula in a customer-chosen shop name.
"""

import base64

import pytest
from fastapi.testclient import TestClient

import admin
import admin_portal
import config
import database

PASSWORD = "correct-horse-battery-staple"


def _auth(password=PASSWORD):
    token = base64.b64encode(f"admin:{password}".encode()).decode()
    return {"Authorization": f"Basic {token}"}


@pytest.fixture()
def portal(temp_db, monkeypatch):
    monkeypatch.setattr(config, "ADMIN_PORTAL_PASSWORD", PASSWORD)
    admin.init_portal_db()
    return TestClient(admin_portal.app)


def test_every_route_needs_the_password(portal):
    assert portal.get("/").status_code == 401
    assert "www-authenticate" in portal.get("/").headers
    assert portal.get("/export/organizations.csv").status_code == 401
    assert portal.get("/export/individual-subscribers.csv").status_code == 401
    assert portal.post("/hide/organization/1").status_code == 401

    assert portal.get("/", headers=_auth("wrong")).status_code == 401
    assert portal.get("/", headers=_auth()).status_code == 200


def test_serves_openly_when_no_password_is_configured(temp_db, monkeypatch):
    # The operator's choice for a tool on their own machine.
    monkeypatch.setattr(config, "ADMIN_PORTAL_PASSWORD", "")
    admin.init_portal_db()
    client = TestClient(admin_portal.app)
    assert client.get("/").status_code == 200
    # The cross-site guard on writes does not depend on the password.
    resp = client.post("/hide/organization/1", headers={"Origin": "https://evil.example"})
    assert resp.status_code == 403


def test_hide_refuses_a_cross_site_post(portal):
    headers = {**_auth(), "Origin": "https://evil.example"}
    assert portal.post("/hide/organization/1", headers=headers).status_code == 403

    headers = {**_auth(), "Sec-Fetch-Site": "cross-site"}
    assert portal.post("/hide/organization/1", headers=headers).status_code == 403

    # Our own form: same-origin, and it goes through (303 back to the page).
    headers = {**_auth(), "Sec-Fetch-Site": "same-origin"}
    resp = portal.post("/hide/organization/1", headers=headers, follow_redirects=False)
    assert resp.status_code == 303
    assert 1 in admin._hidden_ids(admin.HIDDEN_KIND_ORG)


def test_csv_export_neutralises_formulas(portal):
    owner = database.get_or_create_user(firebase_uid="uid-csv", email="=HYPERLINK(\"x\")@x.test")
    database.create_organization(owner["id"], "=cmd|' /C calc'!A0", 2)

    import csv as csv_module
    import io as io_module

    body = portal.get("/export/organizations.csv", headers=_auth()).text
    rows = list(csv_module.reader(io_module.StringIO(body)))
    header, row = rows[0], rows[1]
    name = row[header.index("name")]
    email = row[header.index("owner_email")]
    assert name.startswith("'=cmd|")
    assert email.startswith("'=HYPERLINK")
    for cell in row:
        assert not cell or cell[0] not in "=+-@", cell

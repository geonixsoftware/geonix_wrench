"""Hardening headers on every response this process sends.

These live in the app rather than in a reverse proxy because there is not
always one: the same code serves the API behind nginx in one deployment and
serves the website itself in another. A header that only exists when a
particular proxy happens to be in front is one nothing can depend on.
"""

import pytest
from fastapi.testclient import TestClient

from main import app


@pytest.fixture
def client():
    app.dependency_overrides.clear()
    return TestClient(app)


BASE = {
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "referrer-policy": "no-referrer",
    "cross-origin-opener-policy": "same-origin",
}


@pytest.mark.parametrize("header, value", BASE.items())
def test_present_on_a_json_response(client, header, value):
    resp = client.get("/health")
    assert resp.headers.get(header) == value


@pytest.mark.parametrize("header, value", BASE.items())
def test_present_on_an_error_response(client, header, value):
    # An error path still has to carry them; a 401 body is a response like any
    # other and used to be produced by a different code path entirely.
    resp = client.get("/api/auth/me")
    assert resp.status_code == 401
    assert resp.headers.get(header) == value


def test_present_on_a_cors_preflight(client):
    # CORSMiddleware answers OPTIONS itself without calling inward, so this
    # only passes while the security layer stays registered last (outermost).
    resp = client.options(
        "/api/auth/me",
        headers={
            "Origin": "https://geonix.site",
            "Access-Control-Request-Method": "GET",
        },
    )
    assert resp.headers.get("x-content-type-options") == "nosniff"


def test_json_gets_a_deny_everything_policy(client):
    csp = client.get("/health").headers.get("content-security-policy", "")
    assert "default-src 'none'" in csp
    assert "frame-ancestors 'none'" in csp


def test_hsts_only_when_the_request_arrived_over_https(client):
    # TLS ends at Cloudflare, so the forwarded header is the only honest
    # signal. Sending HSTS over plaintext is meaningless and browsers ignore it.
    plain = client.get("/health")
    assert "strict-transport-security" not in plain.headers

    fwd = client.get("/health", headers={"X-Forwarded-Proto": "https"})
    assert "max-age=31536000" in fwd.headers.get("strict-transport-security", "")


def test_a_route_that_sets_its_own_policy_keeps_it(monkeypatch):
    # The shop-logo route serves SVGs under a sandboxed, much tighter CSP.
    # Overwriting that with the generic one would re-enable script execution
    # inside an uploaded logo, which is the whole thing it defends against.
    from security_headers import SecurityHeadersMiddleware

    async def app_with_own_csp(scope, receive, send):
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [
                (b"content-type", b"image/svg+xml"),
                (b"content-security-policy", b"default-src 'none'; sandbox"),
            ],
        })
        await send({"type": "http.response.body", "body": b"<svg/>"})

    sent = []

    async def send(message):
        sent.append(message)

    async def receive():
        return {"type": "http.request", "body": b""}

    import asyncio

    mw = SecurityHeadersMiddleware(app_with_own_csp)
    asyncio.run(mw({"type": "http", "scheme": "http", "headers": []}, receive, send))

    headers = dict(sent[0]["headers"])
    assert headers[b"content-security-policy"] == b"default-src 'none'; sandbox"
    # ...while the headers it did not set are still added.
    assert headers[b"x-content-type-options"] == b"nosniff"


def test_a_304_is_left_without_a_policy_of_its_own():
    # A 304 has no body and no Content-Type, so the HTML/non-HTML choice cannot
    # be made from it — and a browser merges a 304's headers into the copy it
    # already holds. Adding the deny-everything policy here replaced the real
    # one on the cached home page, and every reload after that blocked the
    # site's own stylesheet, script and favicon.
    import asyncio

    from security_headers import SecurityHeadersMiddleware

    async def app_returning_304(scope, receive, send):
        await send({
            "type": "http.response.start",
            "status": 304,
            "headers": [(b"etag", b'"abc"')],
        })
        await send({"type": "http.response.body", "body": b""})

    sent = []

    async def send(message):
        sent.append(message)

    async def receive():
        return {"type": "http.request", "body": b""}

    mw = SecurityHeadersMiddleware(app_returning_304)
    asyncio.run(mw(
        {"type": "http", "scheme": "http", "path": "/", "query_string": b"", "headers": []},
        receive,
        send,
    ))

    headers = dict(sent[0]["headers"])
    assert b"content-security-policy" not in headers
    # The headers that do not depend on the body are still added.
    assert headers[b"x-content-type-options"] == b"nosniff"


def test_a_200_page_still_gets_the_html_policy():
    # The counterpart to the 304 case above: the policy a browser stores comes
    # from here, so this is the one that has to be right.
    import asyncio

    from security_headers import SecurityHeadersMiddleware

    async def app_returning_html(scope, receive, send):
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"text/html; charset=utf-8")],
        })
        await send({"type": "http.response.body", "body": b"<!doctype html>"})

    sent = []

    async def send(message):
        sent.append(message)

    async def receive():
        return {"type": "http.request", "body": b""}

    mw = SecurityHeadersMiddleware(app_returning_html)
    asyncio.run(mw(
        {"type": "http", "scheme": "http", "path": "/", "query_string": b"", "headers": []},
        receive,
        send,
    ))

    csp = dict(sent[0]["headers"])[b"content-security-policy"]
    assert b"default-src 'self'" in csp
    assert b"style-src 'self' 'unsafe-inline'" in csp

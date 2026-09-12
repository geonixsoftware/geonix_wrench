"""The 401/403 split the app's session handling depends on.

The desktop app used to show "Can't reach Geonix Wrench" for an expired
session, because a rejected token and a dead socket were indistinguishable by
the time they reached the UI. Fixing that means the client signs out on 401 —
which only works if 401 means exactly one thing.

It did not. HTTPBearer answers a missing or malformed Authorization header with
403, the same status every permission check uses, so "your session is over" and
"only the shop owner can do this" arrived identically. These tests pin the
split: 401 for anything wrong with the credentials, 403 reserved for a caller
who is authenticated and still not allowed.
"""

import pytest
from fastapi.testclient import TestClient

from main import app


@pytest.fixture
def client():
    app.dependency_overrides.clear()
    return TestClient(app)


@pytest.mark.parametrize(
    "headers, case",
    [
        ({}, "no Authorization header at all"),
        ({"Authorization": "Basic dXNlcjpwYXNz"}, "wrong scheme"),
        ({"Authorization": "Bearer"}, "scheme with no token"),
        ({"Authorization": "Bearer "}, "scheme with an empty token"),
        ({"Authorization": "Bearer not-a-real-jwt"}, "a token Firebase rejects"),
    ],
)
def test_every_authentication_failure_answers_401(client, headers, case):
    resp = client.get("/api/auth/me", headers=headers)

    assert resp.status_code == 401, f"{case} should be 401, got {resp.status_code}"
    assert resp.json() == {"detail": "Invalid or expired token"}, case


def test_401_carries_the_challenge_header(client):
    # A 401 without WWW-Authenticate is malformed per RFC 9110.
    resp = client.get("/api/auth/me")
    assert resp.headers.get("www-authenticate") == "Bearer"


def test_the_failure_message_does_not_say_which_way_it_failed(client):
    # Absent, malformed and expired must be indistinguishable to a caller
    # probing for a way in.
    bodies = {
        client.get("/api/auth/me", headers=h).text
        for h in ({}, {"Authorization": "Bearer junk"}, {"Authorization": "Basic x"})
    }
    assert len(bodies) == 1, f"responses differ between failure modes: {bodies}"


def test_health_stays_open(client):
    # The one route with no credentials, used by the proxy's probe.
    assert client.get("/health").status_code == 200

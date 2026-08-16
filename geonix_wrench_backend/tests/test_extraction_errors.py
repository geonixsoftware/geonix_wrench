"""Provider-error classification for job card extraction.

Every provider failure used to collapse into one 502 "Job card extraction
failed", so a permanent account problem — an unverified organization, a
rejected key — was presented to the mechanic as a transient one with a Retry
button that could never succeed.
"""

import anthropic
import httpx
import pytest

import extraction
from extraction import ExtractionError


def _status_error(cls, status_code, message):
    """Build a real SDK exception the way the SDK itself would."""
    request = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    response = httpx.Response(status_code, request=request, json={
        "type": "error",
        "error": {"type": "invalid_request_error", "message": message},
    })
    return cls(message, response=response, body={"error": {"message": message}})


def _raise_from_anthropic(monkeypatch, error):
    class _Messages:
        def create(self, **kwargs):
            raise error

    class _FakeClient:
        def __init__(self, *args, **kwargs):
            self.messages = _Messages()

    monkeypatch.setattr(extraction, "Anthropic", _FakeClient)
    monkeypatch.setattr(extraction, "LLM_PROVIDER", "anthropic")


def test_identity_verification_is_permanent_not_retryable(monkeypatch):
    # The exact failure seen in production: HTTP 400 with an account-state
    # message. It is resolved in the Anthropic Console, never by retrying.
    _raise_from_anthropic(
        monkeypatch,
        _status_error(
            anthropic.BadRequestError, 400, "Identity verification is required to continue."
        ),
    )

    with pytest.raises(ExtractionError) as excinfo:
        extraction.extract_jobcard("Replaced the serpentine belt.")

    assert excinfo.value.retryable is False
    # The provider's own wording reaches the operator rather than being swallowed.
    assert "Identity verification is required" in excinfo.value.message


def test_rejected_credentials_are_permanent(monkeypatch):
    _raise_from_anthropic(
        monkeypatch, _status_error(anthropic.AuthenticationError, 401, "invalid x-api-key")
    )

    with pytest.raises(ExtractionError) as excinfo:
        extraction.extract_jobcard("Oil change.")

    assert excinfo.value.retryable is False
    # The key itself must never be echoed back to the client.
    assert "x-api-key" not in excinfo.value.message


def test_rate_limit_is_retryable(monkeypatch):
    _raise_from_anthropic(
        monkeypatch, _status_error(anthropic.RateLimitError, 429, "rate limited")
    )

    with pytest.raises(ExtractionError) as excinfo:
        extraction.extract_jobcard("Oil change.")

    assert excinfo.value.retryable is True


def test_provider_outage_is_retryable(monkeypatch):
    _raise_from_anthropic(
        monkeypatch, _status_error(anthropic.InternalServerError, 529, "overloaded")
    )

    with pytest.raises(ExtractionError) as excinfo:
        extraction.extract_jobcard("Oil change.")

    assert excinfo.value.retryable is True


def test_unreachable_provider_is_retryable(monkeypatch):
    request = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    _raise_from_anthropic(monkeypatch, anthropic.APIConnectionError(request=request))

    with pytest.raises(ExtractionError) as excinfo:
        extraction.extract_jobcard("Oil change.")

    assert excinfo.value.retryable is True

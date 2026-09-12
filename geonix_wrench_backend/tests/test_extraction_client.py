"""The provider client is built once, not once per job card.

`_extract_with_anthropic` used to call `Anthropic(api_key=...)` inside the
request path. A fresh client is a fresh connection pool, so every recording
paid for a new TCP connection and a TLS handshake before the prompt went out —
latency in front of a call a mechanic is already waiting on, on every single
job card.

The timeout matters for the same reason from the other direction: the SDK
defaults to a 10-minute timeout with 2 retries and retries timeouts, so an
unresponsive provider could hold a worker for half an hour on a request whose
client gave up after 180 seconds.
"""

import pytest

import extraction
from config import ANTHROPIC_MAX_RETRIES, ANTHROPIC_TIMEOUT_SECONDS
from schemas import PartUsed


class _FakeClient:
    instances = []

    def __init__(self, *args, **kwargs):
        self.kwargs = kwargs
        _FakeClient.instances.append(self)


@pytest.fixture(autouse=True)
def _fresh_clients(monkeypatch):
    _FakeClient.instances = []
    extraction.reset_clients()
    yield
    extraction.reset_clients()


def test_the_anthropic_client_is_reused_across_calls(monkeypatch):
    monkeypatch.setattr(extraction, "Anthropic", _FakeClient)

    first = extraction._get_anthropic_client()
    second = extraction._get_anthropic_client()

    assert first is second
    assert len(_FakeClient.instances) == 1


def test_the_client_is_bounded_by_an_explicit_timeout_and_retry_budget(monkeypatch):
    monkeypatch.setattr(extraction, "Anthropic", _FakeClient)

    client = extraction._get_anthropic_client()

    # Worst case has to stay inside the app's own 180s upload timeout, or the
    # server keeps working on a job card nobody is waiting for.
    assert client.kwargs["timeout"] == ANTHROPIC_TIMEOUT_SECONDS
    assert client.kwargs["max_retries"] == ANTHROPIC_MAX_RETRIES
    assert ANTHROPIC_TIMEOUT_SECONDS * (ANTHROPIC_MAX_RETRIES + 1) < 180


def test_a_patched_client_class_is_not_served_a_stale_cached_client(monkeypatch):
    """Guards the test seam itself.

    Caching on "is it None" alone would hand every later test whichever client
    the first one happened to build, and the provider-error tests would then
    exercise a client they never patched.
    """
    monkeypatch.setattr(extraction, "Anthropic", _FakeClient)
    first = extraction._get_anthropic_client()

    class _OtherClient(_FakeClient):
        pass

    monkeypatch.setattr(extraction, "Anthropic", _OtherClient)
    second = extraction._get_anthropic_client()

    assert second is not first
    assert isinstance(second, _OtherClient)


def test_the_ollama_client_is_reused_across_calls():
    assert extraction._get_ollama_client() is extraction._get_ollama_client()


def test_a_stated_total_survives_the_schema():
    # parts_used is stored as a JSON blob, so a new optional field needs no
    # migration — but it does need to round-trip.
    part = PartUsed.model_validate(
        {"part_name": "5W-30 oil", "quantity": 4.5, "total_price": 48.0}
    )
    assert part.total_price == 48.0
    assert part.unit_price is None
    assert part.quantity == 4.5
    assert part.model_dump()["total_price"] == 48.0


def test_rows_written_before_total_price_existed_still_load():
    part = PartUsed.model_validate(
        {"part_name": "Oil filter", "quantity": 1, "unit_price": 12.5}
    )
    assert part.total_price is None
    assert part.quantity == 1.0

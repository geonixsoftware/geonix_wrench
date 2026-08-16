import asyncio
import io

import pytest
from fastapi import HTTPException, UploadFile
from starlette.datastructures import Headers

import limits
from config import MAX_AUDIO_SIZE_BYTES, MAX_FIELD_CHARS, MAX_TRANSCRIPT_CHARS
from limits import enforce_rate_limit, read_upload_capped, reset_rate_limits


@pytest.fixture(autouse=True)
def _clear_counters():
    reset_rate_limits()
    yield
    reset_rate_limits()


def _upload(data: bytes, *, declared_length=None) -> UploadFile:
    headers = Headers({"content-length": str(declared_length)}) if declared_length else None
    return UploadFile(filename="clip.m4a", file=io.BytesIO(data), headers=headers)


# --------------------------------------------------------------- rate limit


def test_rate_limit_allows_up_to_the_budget():
    for _ in range(5):
        enforce_rate_limit("audio", "user-1", 5)


def test_rate_limit_rejects_past_the_budget():
    for _ in range(5):
        enforce_rate_limit("audio", "user-1", 5)

    with pytest.raises(HTTPException) as exc:
        enforce_rate_limit("audio", "user-1", 5)
    assert exc.value.status_code == 429
    assert "Retry-After" in exc.value.headers


def test_rate_limit_is_per_identity():
    for _ in range(5):
        enforce_rate_limit("audio", "user-1", 5)
    # A second user must not inherit the first one's exhausted budget.
    enforce_rate_limit("audio", "user-2", 5)


def test_rate_limit_is_per_bucket():
    for _ in range(5):
        enforce_rate_limit("audio", "user-1", 5)
    # Burning the tight audio budget must not lock the user out of everything.
    enforce_rate_limit("general", "user-1", 5)


def test_rate_limit_window_expires(monkeypatch):
    clock = {"t": 1000.0}
    monkeypatch.setattr(limits.time, "monotonic", lambda: clock["t"])

    for _ in range(3):
        enforce_rate_limit("audio", "user-1", 3)
    with pytest.raises(HTTPException):
        enforce_rate_limit("audio", "user-1", 3)

    clock["t"] += limits.RATE_LIMIT_WINDOW_SECONDS + 1
    enforce_rate_limit("audio", "user-1", 3)


# ------------------------------------------------------------ upload caps


def test_upload_within_cap_is_written():
    sink = bytearray()
    written = asyncio.run(read_upload_capped(_upload(b"x" * 2048), 4096, sink.extend))
    assert written == 2048
    assert len(sink) == 2048


def test_upload_over_cap_is_rejected():
    sink = bytearray()
    with pytest.raises(HTTPException) as exc:
        asyncio.run(read_upload_capped(_upload(b"x" * 9000), 4096, sink.extend))
    assert exc.value.status_code == 413


def test_oversized_content_length_rejected_before_reading():
    # The point of the pre-check: refuse without pulling the body through.
    sink = bytearray()
    with pytest.raises(HTTPException) as exc:
        asyncio.run(read_upload_capped(
            _upload(b"x" * 10, declared_length=MAX_AUDIO_SIZE_BYTES + 1),
            MAX_AUDIO_SIZE_BYTES,
            sink.extend,
        ))
    assert exc.value.status_code == 413
    assert sink == bytearray()


def test_a_lying_content_length_is_still_caught_while_streaming():
    # Content-Length is client-supplied, so the streaming counter is what
    # actually enforces the cap.
    sink = bytearray()
    with pytest.raises(HTTPException) as exc:
        asyncio.run(read_upload_capped(_upload(b"x" * 9000, declared_length=10), 4096, sink.extend))
    assert exc.value.status_code == 413


def test_empty_upload_rejected():
    with pytest.raises(HTTPException) as exc:
        asyncio.run(read_upload_capped(_upload(b""), 4096, bytearray().extend))
    assert exc.value.status_code == 400


# ---------------------------------------------------------------- text caps


def test_transcript_is_capped_before_the_prompt(monkeypatch):
    import extraction

    seen = {}

    def fake(transcript):
        seen["len"] = len(transcript)
        return "ok"

    monkeypatch.setattr(extraction, "LLM_PROVIDER", "ollama")
    monkeypatch.setattr(extraction, "_extract_with_ollama", fake)

    extraction.extract_jobcard("a" * (MAX_TRANSCRIPT_CHARS + 5000))
    assert seen["len"] == MAX_TRANSCRIPT_CHARS


def test_pdf_field_clipping():
    from pdf_generator import _clip

    assert _clip("short") == "short"

    long = _clip("a" * (MAX_FIELD_CHARS + 500))
    assert len(long) <= MAX_FIELD_CHARS
    assert long.endswith("…")

    # Control characters can break reportlab layout; newlines are legitimate.
    assert _clip("a\x00b\x07c") == "abc"
    assert "\n" in _clip("a\nb")
    assert _clip(None) == ""

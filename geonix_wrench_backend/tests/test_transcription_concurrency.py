"""Concurrency behaviour of the transcription stage.

`process_audio` is `async def` and used to call blocking `transcribe_audio()`
inline, so a ~20s CPU burn ran *on the event loop* — every other request in the
process (auth, billing status, health) stalled behind a single recording, and
ten simultaneous uploads queued without bound until every client timed out.

These drive the coroutines with `asyncio.run` rather than a marker, so they run
on a stock pytest with no async plugin installed. A skipped concurrency test is
worse than none — it reports green while proving nothing.
"""

import asyncio
import queue
import time

import pytest

import transcription
from transcription import TranscriptionBusy


@pytest.fixture(autouse=True)
def _reset_pool(monkeypatch):
    """Reset the per-loop semaphore and in-flight counter between tests."""
    monkeypatch.setattr(transcription, "_in_flight", 0)
    monkeypatch.setattr(transcription, "_slots", None)
    yield


def _fake_transcribe(duration=0.2):
    def _run(path):
        time.sleep(duration)
        return f"transcript of {path}"

    return _run


def test_transcription_does_not_block_the_event_loop(monkeypatch):
    monkeypatch.setattr(transcription, "transcribe_audio", _fake_transcribe(0.3))

    gaps = []

    async def scenario():
        async def heartbeat():
            """Stands in for every other request the server should still serve."""
            last = time.perf_counter()
            for _ in range(60):
                await asyncio.sleep(0.01)
                now = time.perf_counter()
                gaps.append(now - last)
                last = now

        # The heartbeat has to already be ticking before transcription starts,
        # and outlast it. Handing both to gather() lets the blocking version run
        # to completion before the heartbeat takes its first measurement, which
        # hides the very stall this is looking for.
        beat = asyncio.create_task(heartbeat())
        await asyncio.sleep(0.05)
        await transcription.transcribe_audio_async("a.wav")
        await beat

    asyncio.run(scenario())

    # Counting completed ticks is not enough: blocking the loop only *delays*
    # them, so the count still reaches 20 either way. What a blocked loop
    # actually looks like is one long stall, so assert on the worst gap —
    # inline transcription would park the loop for the full 0.3s.
    assert max(gaps) < 0.15, f"event loop stalled for {max(gaps):.2f}s"


def test_queue_sheds_load_once_full(monkeypatch):
    monkeypatch.setattr(transcription, "transcribe_audio", _fake_transcribe(0.3))
    monkeypatch.setattr(transcription, "WHISPER_MAX_CONCURRENT", 1)
    monkeypatch.setattr(transcription, "WHISPER_MAX_QUEUED", 1)

    async def scenario():
        # Two fill capacity (1 running + 1 queued); the third must be rejected
        # immediately rather than joining an unbounded queue.
        first = asyncio.create_task(transcription.transcribe_audio_async("a.wav"))
        second = asyncio.create_task(transcription.transcribe_audio_async("b.wav"))
        await asyncio.sleep(0.05)

        with pytest.raises(TranscriptionBusy) as excinfo:
            await transcription.transcribe_audio_async("c.wav")

        assert excinfo.value.retry_after_seconds > 0
        assert await first == "transcript of a.wav"
        assert await second == "transcript of b.wav"

    asyncio.run(scenario())


def test_concurrency_is_capped_at_the_configured_slots(monkeypatch):
    monkeypatch.setattr(transcription, "WHISPER_MAX_CONCURRENT", 1)
    monkeypatch.setattr(transcription, "WHISPER_MAX_QUEUED", 8)

    concurrent = 0
    peak = 0

    def _run(path):
        nonlocal concurrent, peak
        concurrent += 1
        peak = max(peak, concurrent)
        time.sleep(0.1)
        concurrent -= 1
        return "ok"

    monkeypatch.setattr(transcription, "transcribe_audio", _run)

    async def scenario():
        await asyncio.gather(
            *(transcription.transcribe_audio_async(f"{i}.wav") for i in range(5))
        )

    asyncio.run(scenario())

    # Serialised, so the CPU is never oversubscribed and no two calls share a
    # model instance.
    assert peak == 1


def test_in_flight_returns_to_zero_after_a_failure(monkeypatch):
    def _boom(path):
        raise RuntimeError("decode failed")

    monkeypatch.setattr(transcription, "transcribe_audio", _boom)

    async def scenario():
        with pytest.raises(RuntimeError):
            await transcription.transcribe_audio_async("a.wav")

    asyncio.run(scenario())

    # A leaked slot would permanently shrink capacity until restart.
    assert transcription.queue_depth() == 0


def test_pool_holds_one_model_per_concurrent_slot(monkeypatch):
    built = []

    def _build():
        built.append(object())
        return built[-1]

    monkeypatch.setattr(transcription, "_build_model", _build)
    monkeypatch.setattr(transcription, "WHISPER_MAX_CONCURRENT", 3)
    monkeypatch.setattr(transcription, "_models_created", 0)
    monkeypatch.setattr(transcription, "_pool", queue.Queue())

    transcription.preload_model()

    # Concurrent calls must not share one model — transcribe() keeps per-call
    # state, so a shared instance is not safe.
    assert len(built) == 3

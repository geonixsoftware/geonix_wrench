"""Whisper transcription, bounded so concurrent uploads queue instead of thrash.

Transcription is CPU-bound and runs at roughly 1x real time on the medium model.
Three things had to be true for concurrent uploads to work, and none of them
were:

1. It must not run on the event loop. `process_audio` is `async def` and called
   `transcribe_audio()` directly, so a 20-second CPU burn blocked the entire
   server — auth, billing status and every other request stalled behind one
   recording. It now runs in a dedicated executor.

2. Two requests must not share one model. `WhisperModel.transcribe` keeps
   per-call state, so concurrent calls against a single cached instance are not
   safe. Each concurrent slot now owns its own model.

3. A burst must not queue without bound. Ten simultaneous uploads on one core
   do not take 20 seconds each — they take minutes, every client times out and
   retries, and the server keeps working on recordings nobody is waiting for.
   Work beyond the queue ceiling is now rejected immediately with Retry-After.
"""

import asyncio
import logging
import queue
import threading
from concurrent.futures import ThreadPoolExecutor
from typing import Optional

from faster_whisper import WhisperModel

from config import (
    WHISPER_BEAM_SIZE,
    WHISPER_COMPUTE_TYPE,
    WHISPER_CPU_THREADS,
    WHISPER_DEVICE,
    WHISPER_LANGUAGE,
    WHISPER_MAX_CONCURRENT,
    WHISPER_MAX_QUEUED,
    WHISPER_MODEL_SIZE,
    WHISPER_SECONDS_PER_JOB,
)

logger = logging.getLogger(__name__)

# Biases Whisper's decoding toward auto-repair vocabulary it otherwise mishears
# (e.g. "Volkswagen Golf" -> "Svabun"), since it has no domain fine-tuning.
VOCABULARY_PROMPT = (
    "Auto repair shop job notes. Vehicle makes: Volkswagen, Toyota, Honda, Ford, "
    "Chevrolet, Nissan, BMW, Mercedes-Benz, Audi, Hyundai, Kia, Mazda, Subaru, "
    "Jeep, Ram, GMC, Chrysler, Dodge, Volvo, Land Rover, Porsche, Tesla. Models: "
    "Golf, Civic, Corolla, Camry, Accord, Fusion, F-150, Silverado. Oil viscosity "
    "grades: 0W-20, 5W-20, 5W-30, 5W-40, 10W-30, 10W-40, full synthetic, "
    "conventional, high mileage. Quantities in liters or quarts."
)


class TranscriptionBusy(Exception):
    """Every transcription slot is taken and the queue is full.

    Carries the seconds a client should wait, so the caller can send a
    Retry-After rather than leaving the client to guess.
    """

    def __init__(self, retry_after_seconds: int):
        super().__init__("Transcription queue is full")
        self.retry_after_seconds = retry_after_seconds


# ------------------------------------------------------------------ model pool

_pool: "queue.Queue[WhisperModel]" = queue.Queue()
_pool_lock = threading.Lock()
_models_created = 0


def _build_model() -> WhisperModel:
    return WhisperModel(
        WHISPER_MODEL_SIZE,
        device=WHISPER_DEVICE,
        compute_type=WHISPER_COMPUTE_TYPE,
        # Without this each instance claims every core, so four concurrent
        # transcriptions oversubscribe the CPU several times over and all four
        # finish later than they would have run one after another.
        cpu_threads=WHISPER_CPU_THREADS,
    )


def _acquire_model() -> WhisperModel:
    """Take a model from the pool, creating one if the pool is under quota."""
    global _models_created
    with _pool_lock:
        if _pool.empty() and _models_created < WHISPER_MAX_CONCURRENT:
            _models_created += 1
            return _build_model()
    # Blocks until a slot frees. The semaphore in `transcribe_audio_async`
    # already bounds how many callers can reach this point.
    return _pool.get()


def _release_model(model: WhisperModel) -> None:
    _pool.put(model)


def preload_model() -> None:
    # Downloading/loading the model can take far longer than a request's
    # timeout budget, so this is called once at server startup instead of
    # letting the first upload request pay that cost. One model per concurrent
    # slot, all loaded up front.
    global _models_created
    with _pool_lock:
        while _models_created < WHISPER_MAX_CONCURRENT:
            _pool.put(_build_model())
            _models_created += 1


# ------------------------------------------------------------------- execution

_executor = ThreadPoolExecutor(
    max_workers=WHISPER_MAX_CONCURRENT, thread_name_prefix="whisper"
)

# Bounds how many requests are inside transcription at once. Created lazily so
# it binds to the running event loop rather than import-time state.
_slots: Optional[asyncio.Semaphore] = None
_in_flight = 0


def _get_slots() -> asyncio.Semaphore:
    global _slots
    if _slots is None:
        _slots = asyncio.Semaphore(WHISPER_MAX_CONCURRENT)
    return _slots


def queue_depth() -> int:
    """Requests currently transcribing or waiting to."""
    return _in_flight


def transcribe_audio(file_path: str) -> str:
    """Blocking transcription. Call `transcribe_audio_async` from request code."""
    model = _acquire_model()
    try:
        segments, _info = model.transcribe(
            file_path,
            beam_size=WHISPER_BEAM_SIZE,
            # Strips silence before decoding — on a typical shop recording this
            # alone removes a second or more of work.
            vad_filter=True,
            initial_prompt=VOCABULARY_PROMPT,
            language=WHISPER_LANGUAGE,
            condition_on_previous_text=False,
        )
        return " ".join(segment.text.strip() for segment in segments).strip()
    finally:
        _release_model(model)


async def transcribe_audio_async(file_path: str) -> str:
    """Transcribe off the event loop, rejecting work once the queue is full."""
    global _in_flight

    capacity = WHISPER_MAX_CONCURRENT + WHISPER_MAX_QUEUED
    if _in_flight >= capacity:
        # Rejecting immediately beats accepting work that will outlive the
        # client's own timeout.
        logger.warning(
            "Transcription queue full (%d in flight, capacity %d) - shedding request",
            _in_flight,
            capacity,
        )
        raise TranscriptionBusy(
            retry_after_seconds=capacity * WHISPER_SECONDS_PER_JOB // WHISPER_MAX_CONCURRENT
        )

    _in_flight += 1
    try:
        async with _get_slots():
            loop = asyncio.get_running_loop()
            return await loop.run_in_executor(_executor, transcribe_audio, file_path)
    finally:
        _in_flight -= 1

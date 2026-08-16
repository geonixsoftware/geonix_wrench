"""Request limits: per-caller rate limiting and bounded upload reads.

Deliberately dependency-free. A fixed-window counter in process memory is
enough for a single-instance deployment and adds no new packages to audit. If
the API is ever run behind more than one worker, move this to Redis — the
counters are per-process and each worker would allow the full budget.
"""

import time
from collections import defaultdict
from threading import Lock
from typing import Dict, List, Optional, Tuple

from fastapi import HTTPException, UploadFile

from config import (
    RATE_LIMIT_WINDOW_SECONDS,
    UPLOAD_CHUNK_BYTES,
)

_hits: Dict[Tuple[str, str], List[float]] = defaultdict(list)
_lock = Lock()


def enforce_rate_limit(bucket: str, identity: str, limit: int) -> None:
    """Allow `limit` calls per window for (bucket, identity), else 429."""
    if limit <= 0:
        return

    now = time.monotonic()
    cutoff = now - RATE_LIMIT_WINDOW_SECONDS
    key = (bucket, identity)

    with _lock:
        recent = [t for t in _hits[key] if t > cutoff]
        if len(recent) >= limit:
            retry_after = max(1, int(RATE_LIMIT_WINDOW_SECONDS - (now - recent[0])))
            _hits[key] = recent
            raise HTTPException(
                status_code=429,
                detail="Too many requests. Please slow down.",
                headers={"Retry-After": str(retry_after)},
            )
        recent.append(now)
        _hits[key] = recent


def reset_rate_limits() -> None:
    """Test hook: forget every counter."""
    with _lock:
        _hits.clear()


async def read_upload_capped(file: UploadFile, max_bytes: int, sink) -> int:
    """Stream `file` into `sink`, aborting past `max_bytes`.

    Replaces `await file.read()`, which materialised the whole body before any
    size check could run — so an oversized upload cost full memory even when it
    was about to be rejected.

    Returns the number of bytes written. Raises 413 if the cap is passed.
    """
    # Trust Content-Length only to reject early; it is client-supplied, so the
    # streaming counter below is what actually enforces the cap.
    declared = _declared_length(file)
    if declared is not None and declared > max_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"File is too large (limit {max_bytes // (1024 * 1024)} MB)",
        )

    written = 0
    while True:
        chunk = await file.read(UPLOAD_CHUNK_BYTES)
        if not chunk:
            break
        written += len(chunk)
        if written > max_bytes:
            raise HTTPException(
                status_code=413,
                detail=f"File is too large (limit {max_bytes // (1024 * 1024)} MB)",
            )
        sink(chunk)

    if written == 0:
        raise HTTPException(status_code=400, detail="Uploaded file is empty")

    return written


def _declared_length(file: UploadFile) -> Optional[int]:
    headers = getattr(file, "headers", None)
    if not headers:
        return None
    raw = headers.get("content-length")
    try:
        return int(raw) if raw is not None else None
    except (TypeError, ValueError):
        return None

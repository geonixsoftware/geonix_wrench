# Ollama switch — handoff prompt

Paste everything below the line into a fresh Claude Code session, run from the
repo root, **once the backend is on the server**. It is deliberately written as
a brief rather than a set of instructions: the code path already exists, and the
real work is hardening and verifying it.

Not for the laptop — Whisper and the LLM would compete for the same cores.

---

Switch the Geonix Wrench backend from the Anthropic API to a local Ollama model
for job-card extraction, and harden the Ollama path so it is production-ready.

## Context

`geonix_wrench_backend/` is a FastAPI service. `POST /api/process-audio` takes a
recording, transcribes it with faster-whisper, then sends the transcript to an
LLM to extract structured job-card fields. Only that second stage is in scope —
**do not touch transcription, and do not touch the Flutter app.**

The provider switch already exists and is a single env var:

| Setting | Where | Default | Notes |
|---|---|---|---|
| `LLM_PROVIDER` | `config.py:8` | `ollama` | `ollama` or `anthropic`; `.env` currently overrides to `anthropic` |
| `OLLAMA_BASE_URL` | `config.py:10` | `http://localhost:11434` | |
| `OLLAMA_MODEL` | `config.py:11` | `llama3.1:8b` | Re-evaluate — see below |

`extract_jobcard` (`extraction.py:84`) branches on `LLM_PROVIDER` to either
`_extract_with_anthropic` (`extraction.py:100`) or `_extract_with_ollama`
(`extraction.py:172`). The Ollama function is written but has **never been run**,
so treat it as untested code, not as a working feature.

## Why we're moving

The Anthropic path is blocked on an account-level gate — every request, even a
trivial one, returns `400 invalid_request_error: "Identity verification is
required to continue."`. That is an Anthropic Console matter, not a code fault.
Moving to a local model also removes the per-request cost and keeps customer
transcripts on our own hardware.

Keep the Anthropic path intact and working as a fallback. This is a change of
default, not a removal.

## The work

### 1. Error classification — the main gap

`_extract_with_anthropic` has a careful exception taxonomy: it raises
`ExtractionError` (`extraction.py:23`) with a `retryable` flag, and
`main.py:229` turns that into `502 if e.retryable else 500`. The Flutter client
now honours that distinction — a 500 shows an error screen with **no Retry
button**, a 502 offers one — so misclassifying a fault is directly visible to
the mechanic.

`_extract_with_ollama` has **no error handling at all**. It calls
`resp.raise_for_status()` (`extraction.py:189`) and lets everything escape to
the generic `except Exception` in `main.py`, which returns 502 unconditionally.
So a permanently misconfigured or unreachable Ollama looks like a transient
blip forever, and the app will keep inviting the user to retry something that
cannot succeed.

Give the Ollama path the same taxonomy. At minimum:

| Failure | Should be |
|---|---|
| `httpx.ConnectError` — Ollama not running / wrong URL | permanent (500) — an operator has to fix it |
| HTTP 404 from Ollama — model not pulled | permanent (500) |
| `httpx.TimeoutException` | retryable (502) |
| HTTP 5xx from Ollama | retryable (502) |
| Response JSON fails `JobCardExtraction.model_validate` | see below |

`tests/test_extraction_errors.py` already covers this taxonomy for the
Anthropic path, one test per failure mode asserting the `retryable` flag.
Mirror it for Ollama — same structure, same granularity.

### 2. Schema reliability

The Anthropic path forces the output shape with `tool_choice` and a JSON
schema, so `tool_use.input` is structurally guaranteed. The Ollama path only
sets `"format": "json"`, then falls back to a regex that pulls the first
`{...}` block out of the response (`_extract_json_block`, `extraction.py:195`),
then validates against `JobCardExtraction` (`schemas.py`).

Small local models routinely get the *types* wrong even when the JSON parses —
`labor_hours` as `"2 hours"` instead of `2.0`, `quantity` as `1.5`, a bare
object where a list is expected. Today any of those raises `ValidationError`
straight into the generic 502.

Check whether the installed Ollama version accepts a **JSON schema** as the
`format` value rather than the string `"json"` (recent versions do). If it
does, pass the schema derived from `JobCardExtraction` — that removes most of
this class of failure and makes the regex fallback dead code. If it doesn't,
add one repair retry that feeds the validation error back to the model, and
only then fail.

### 3. Model choice and timeout

`llama3.1:8b` is a placeholder, not a decision. Evaluate candidates on the real
task (structured extraction from noisy speech-to-text, with the vocabulary
prompt in `SYSTEM_PROMPT`). Consider that the extraction prompt embeds the full
transcript, capped at `MAX_TRANSCRIPT_CHARS` (20 000 chars, `config.py:91`).

The httpx timeout is 120 s (`extraction.py:179`). The Flutter client gives the
whole request 180 s, and transcription has already spent some of that before
extraction starts. A cold Ollama model load can take tens of seconds on first
call — pre-warm the model at startup (as `preload_model()` already does for
Whisper) rather than paying it on a mechanic's first recording.

### 4. Server sizing

Whisper and the LLM will share the box. Whisper is configured for
`WHISPER_MAX_CONCURRENT=4` slots (`config.py:43`), each with its own model
instance and `WHISPER_CPU_THREADS` threads (`config.py:63`, defaults to
cores ÷ concurrency). Adding a CPU-bound LLM on top will make both slower and
can push requests past the client's timeout.

Decide explicitly: GPU for the LLM, or separate hosts, or lower
`WHISPER_MAX_CONCURRENT`. Measure end-to-end latency under two concurrent
uploads before calling it done.

## How to verify

There is a known-good real recording to test against. Transcribe any shop
recording, or use this transcript directly — it is genuine output from the
Whisper path and exercises every field:

> Diagnosed on engine squeal on a BMW 3 Series 2018. The serpentine belt is
> cracked and the belt tensioner pulley is failing. Replace the serpentine belt
> and the tensioner assembly. Total labor duration 2 hours.

A correct extraction has `vehicle_info` naming the BMW, `labor_hours` = 2.0 as
a **number**, `work_performed` describing the belt and tensioner replacement,
and `parts_used` listing both parts with integer quantities.

Done means:

- [ ] `LLM_PROVIDER=ollama` produces a valid `JobCardExtraction` on that transcript
- [ ] Ollama stopped → request returns **500**, not 502
- [ ] Model not pulled → request returns **500**
- [ ] Ollama slow → request returns 502
- [ ] Malformed model output → fails with a clear log line, not a bare `ValidationError` traceback
- [ ] `LLM_PROVIDER=anthropic` still works unchanged
- [ ] Two concurrent uploads both finish within the client's 180 s budget
- [ ] New tests in `tests/test_extraction_errors.py` cover each Ollama failure mode
- [ ] Full backend suite still passes (102 tests as of this writing)

Report which model you chose and the measured end-to-end latency for a
~30-second recording.

import json
import logging
import re
import threading
from typing import Any, Dict, Optional

import anthropic
import httpx
from anthropic import Anthropic

from config import (
    MAX_TRANSCRIPT_CHARS,
    ANTHROPIC_API_KEY,
    ANTHROPIC_MAX_RETRIES,
    ANTHROPIC_MODEL,
    ANTHROPIC_TIMEOUT_SECONDS,
    LLM_PROVIDER,
    OLLAMA_BASE_URL,
    OLLAMA_KEEP_ALIVE,
    OLLAMA_MODEL,
)
from schemas import JobCardExtraction
from stub_extraction import extract_jobcard_offline

logger = logging.getLogger(__name__)


class ExtractionError(Exception):
    """Job card extraction failed.

    `retryable` separates transient faults (rate limits, provider outages,
    network blips) from permanent ones (a rejected API key, an unverified
    account, a malformed request). Both used to surface as an identical 502,
    so the app offered the mechanic a Retry button for failures that could
    only ever fail again — and the real cause was buried in a stack trace.
    """

    def __init__(self, message: str, *, retryable: bool = True):
        super().__init__(message)
        self.message = message
        self.retryable = retryable

SYSTEM_PROMPT = (
    "You are an assistant for an auto repair shop. Extract structured job card "
    "data from a mechanic's spoken transcript. Flag any parts or labor mentioned "
    "in passing that are not clearly itemized, since these are commonly forgotten "
    "on the final invoice. The transcript comes from speech-to-text and may "
    "contain garbled or misheard words, especially vehicle makes/models. If the "
    "vehicle make or model is unclear or garbled, do NOT substitute a different, "
    "unrelated make or model just because it sounds plausible — keep the text as "
    "transcribed (or use <UNKNOWN> if it's unreadable) and add an entry to "
    "unbilled_items_flagged asking the mechanic to verify the exact vehicle."
    "\n\n"
    "Prices are recorded the way they were spoken, never converted:\n"
    "- A price given for the whole quantity — 'forty-eight euros of oil', "
    "'the pads were ninety for the set' — goes in total_price, exactly as "
    "stated. Leave unit_price null.\n"
    "- A price given per item — 'twelve euros each', 'thirty a litre' — goes in "
    "unit_price. Leave total_price null.\n"
    "- Never divide a total into a per-unit price, and never multiply a "
    "per-unit price into a total. Dividing loses cents that the invoice then "
    "bills back to the customer at the wrong figure.\n"
    "- If no price was mentioned for a part, leave both null. Do not guess a "
    "price from what parts usually cost."
)

JSON_SCHEMA: Dict[str, Any] = {
    "type": "object",
    "properties": {
        "vehicle_info": {"type": "string", "description": "Year Make Model or VIN"},
        "labor_hours": {"type": "number"},
        "work_performed": {"type": "string"},
        "parts_used": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "part_name": {"type": "string"},
                    "quantity": {
                        "type": "number",
                        "description": (
                            "How many were used — litres for a fluid, pieces "
                            "otherwise. May be fractional (0.5 litres)."
                        ),
                    },
                    # Both optional and mutually exclusive by instruction: the
                    # model records whichever figure was actually spoken. See
                    # the pricing rules in SYSTEM_PROMPT.
                    "unit_price": {
                        "type": ["number", "null"],
                        "description": (
                            "Price of ONE unit, only when a per-item price was "
                            "stated. Never derived from a total."
                        ),
                    },
                    "total_price": {
                        "type": ["number", "null"],
                        "description": (
                            "Price of the WHOLE quantity, when a combined figure "
                            "was stated. Record it exactly as spoken; never "
                            "divide it into a unit price."
                        ),
                    },
                },
                "required": ["part_name", "quantity"],
                "additionalProperties": False,
            },
        },
        "unbilled_items_flagged": {
            "type": "array",
            "items": {"type": "string"},
        },
    },
    "required": [
        "vehicle_info",
        "labor_hours",
        "work_performed",
        "parts_used",
        "unbilled_items_flagged",
    ],
    "additionalProperties": False,
}


def extract_jobcard(transcript: str) -> JobCardExtraction:
    # The transcript goes into the prompt verbatim, so an unbounded one costs
    # unbounded tokens. Cap it before it reaches either provider.
    if len(transcript) > MAX_TRANSCRIPT_CHARS:
        logger.warning(
            "Transcript truncated from %d to %d characters",
            len(transcript),
            MAX_TRANSCRIPT_CHARS,
        )
        transcript = transcript[:MAX_TRANSCRIPT_CHARS]

    # Dispatch is exhaustive on purpose. This used to be an `if anthropic /
    # else ollama`, so a typo like LLM_PROVIDER=anthropi silently sent every
    # request to Ollama instead — a misconfiguration that looks like a provider
    # outage. An unknown value is now a permanent, self-describing failure.
    if LLM_PROVIDER == "anthropic":
        return _extract_with_anthropic(transcript)
    if LLM_PROVIDER == "ollama":
        return _extract_with_ollama(transcript)
    if LLM_PROVIDER == "stub":
        return extract_jobcard_offline(transcript)
    raise ExtractionError(
        f"LLM_PROVIDER is set to {LLM_PROVIDER!r}, which is not one of "
        "'anthropic', 'ollama' or 'stub'.",
        retryable=False,
    )


# ------------------------------------------------------------------- clients
#
# Both providers are reached through a long-lived client rather than one built
# per request. A fresh client is a fresh connection pool, so every job card was
# paying for a new TCP connection and a full TLS handshake to the provider
# before the first byte of the prompt went out — pure latency in front of a
# call the mechanic is already waiting on. Reusing the client keeps the
# connection warm between recordings.

_anthropic_client: Optional[Anthropic] = None
# The class this client was built from. Tests monkeypatch `extraction.Anthropic`
# with a fake, and a cache keyed only on "is it None" would hand them whichever
# client an earlier test happened to build first.
_anthropic_client_cls: Optional[type] = None
_client_lock = threading.Lock()

_ollama_client: Optional[httpx.Client] = None


def _get_anthropic_client() -> Anthropic:
    global _anthropic_client, _anthropic_client_cls
    with _client_lock:
        if _anthropic_client is None or _anthropic_client_cls is not Anthropic:
            _anthropic_client = Anthropic(
                api_key=ANTHROPIC_API_KEY,
                timeout=ANTHROPIC_TIMEOUT_SECONDS,
                max_retries=ANTHROPIC_MAX_RETRIES,
            )
            _anthropic_client_cls = Anthropic
        return _anthropic_client


def _get_ollama_client() -> httpx.Client:
    global _ollama_client
    with _client_lock:
        if _ollama_client is None:
            _ollama_client = httpx.Client(timeout=120.0)
        return _ollama_client


def reset_clients() -> None:
    """Drop the cached clients. Test hook; the server never calls this."""
    global _anthropic_client, _anthropic_client_cls, _ollama_client
    with _client_lock:
        _anthropic_client = None
        _anthropic_client_cls = None
        if _ollama_client is not None:
            _ollama_client.close()
        _ollama_client = None


def _extract_with_anthropic(transcript: str) -> JobCardExtraction:
    client = _get_anthropic_client()
    tool_name = "extract_jobcard"
    try:
        response = client.messages.create(
            model=ANTHROPIC_MODEL,
            max_tokens=2048,
            system=SYSTEM_PROMPT,
            tools=[
                {
                    "name": tool_name,
                    "description": "Record the structured job card extracted from the transcript.",
                    "input_schema": JSON_SCHEMA,
                }
            ],
            tool_choice={"type": "tool", "name": tool_name},
            messages=[{"role": "user", "content": transcript}],
        )
    # Most specific first. Everything in this first group is a problem with our
    # account or our request, not with the mechanic's recording — retrying is
    # guaranteed to fail, so say so rather than inviting another attempt.
    except anthropic.AuthenticationError as e:
        logger.error("Anthropic rejected the API key: %s", e.message)
        raise ExtractionError(
            "The processing server's AI credentials were rejected.", retryable=False
        ) from None
    except anthropic.PermissionDeniedError as e:
        logger.error("Anthropic denied permission: %s", e.message)
        raise ExtractionError(
            "The processing server's AI account lacks access to this model.",
            retryable=False,
        ) from None
    except anthropic.NotFoundError as e:
        logger.error("Anthropic model %r not found: %s", ANTHROPIC_MODEL, e.message)
        raise ExtractionError(
            f"The configured AI model ({ANTHROPIC_MODEL}) does not exist.",
            retryable=False,
        ) from None
    except anthropic.BadRequestError as e:
        # Covers account-state problems as well as malformed requests — e.g.
        # "Identity verification is required to continue.", which is resolved in
        # the Anthropic Console and never by retrying.
        logger.error("Anthropic rejected the request: %s", e.message)
        raise ExtractionError(
            f"The AI provider rejected the request: {e.message}", retryable=False
        ) from None
    except anthropic.RateLimitError as e:
        logger.warning("Anthropic rate limited the request: %s", e.message)
        raise ExtractionError("The AI provider is rate limiting us.") from None
    except anthropic.APIStatusError as e:
        # 5xx and 529 overloaded are worth another attempt; any other unmapped
        # 4xx is a client-side problem and is not.
        retryable = e.status_code >= 500
        logger.error("Anthropic returned %s: %s", e.status_code, e.message)
        raise ExtractionError(
            f"The AI provider returned an error ({e.status_code}).", retryable=retryable
        ) from None
    # Before the generic connection case: a timeout is now a deliberate ceiling
    # of ours (ANTHROPIC_TIMEOUT_SECONDS), not an unreachable provider, and an
    # operator reading "could not reach the AI provider" would go looking for a
    # network fault that isn't there. APITimeoutError subclasses
    # APIConnectionError, so this has to be matched first.
    except anthropic.APITimeoutError:
        logger.warning(
            "Anthropic did not respond within %.0fs (%d attempt(s))",
            ANTHROPIC_TIMEOUT_SECONDS,
            ANTHROPIC_MAX_RETRIES + 1,
        )
        raise ExtractionError("The AI provider took too long to respond.") from None
    except anthropic.APIConnectionError as e:
        logger.warning("Could not reach Anthropic: %s", e)
        raise ExtractionError("Could not reach the AI provider.") from None

    tool_use = next((block for block in response.content if block.type == "tool_use"), None)
    if tool_use is None:
        # tool_choice forces the tool, so this means the turn stopped early —
        # a refusal or a max_tokens truncation rather than a normal answer.
        logger.error(
            "Anthropic returned no tool_use block (stop_reason=%s)", response.stop_reason
        )
        raise ExtractionError("The AI provider returned no job card data.")
    return JobCardExtraction.model_validate(tool_use.input)


def _extract_with_ollama(transcript: str) -> JobCardExtraction:
    prompt = (
        f"{SYSTEM_PROMPT}\n\n"
        f"Transcript:\n{transcript}\n\n"
        "Respond with ONLY a JSON object matching this schema, no other text:\n"
        f"{json.dumps(JSON_SCHEMA)}"
    )
    client = _get_ollama_client()
    resp = client.post(
        f"{OLLAMA_BASE_URL}/api/generate",
        json={
            "model": OLLAMA_MODEL,
            "prompt": prompt,
            "format": "json",
            "stream": False,
            # Ollama unloads the model after five idle minutes by default, so a
            # shop with a quiet hour pays a full model load on its next job
            # card. Holding it resident is the single biggest win available on
            # the local-model path.
            "keep_alive": OLLAMA_KEEP_ALIVE,
        },
    )
    resp.raise_for_status()
    raw_response = resp.json()["response"]

    return JobCardExtraction.model_validate(json.loads(_extract_json_block(raw_response)))


def _extract_json_block(text: str) -> str:
    # Local models occasionally wrap JSON in prose or code fences despite
    # format="json"; pull out the first top-level {...} block defensively.
    match = re.search(r"\{.*\}", text, re.DOTALL)
    return match.group(0) if match else text

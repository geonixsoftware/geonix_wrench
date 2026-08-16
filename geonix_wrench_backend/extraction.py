import json
import logging
import re
from typing import Any, Dict

import anthropic
import httpx
from anthropic import Anthropic

from config import (
    MAX_TRANSCRIPT_CHARS,
    ANTHROPIC_API_KEY,
    ANTHROPIC_MODEL,
    LLM_PROVIDER,
    OLLAMA_BASE_URL,
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
                    "quantity": {"type": "integer"},
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


def _extract_with_anthropic(transcript: str) -> JobCardExtraction:
    client = Anthropic(api_key=ANTHROPIC_API_KEY)
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
    with httpx.Client(timeout=120.0) as client:
        resp = client.post(
            f"{OLLAMA_BASE_URL}/api/generate",
            json={
                "model": OLLAMA_MODEL,
                "prompt": prompt,
                "format": "json",
                "stream": False,
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

import json
import re
from typing import Any, Dict

import httpx
from anthropic import Anthropic

from config import (
    ANTHROPIC_API_KEY,
    ANTHROPIC_MODEL,
    LLM_PROVIDER,
    OLLAMA_BASE_URL,
    OLLAMA_MODEL,
)
from schemas import JobCardExtraction

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
    if LLM_PROVIDER == "anthropic":
        return _extract_with_anthropic(transcript)
    return _extract_with_ollama(transcript)


def _extract_with_anthropic(transcript: str) -> JobCardExtraction:
    client = Anthropic(api_key=ANTHROPIC_API_KEY)
    tool_name = "extract_jobcard"
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
    tool_use = next((block for block in response.content if block.type == "tool_use"), None)
    if tool_use is None:
        raise RuntimeError("Anthropic response did not include a tool_use block")
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

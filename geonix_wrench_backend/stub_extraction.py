"""Offline job-card extraction — no LLM, no network, no model weights.

This exists so the app can be developed and demoed end to end (record →
transcribe → job card → review → PDF) when no AI provider is reachable: the
Anthropic account is not cleared for inference, and a local model is not
viable on every dev machine.

It is deliberately dumb. It reads the transcript with regular expressions and
a fixed shop vocabulary, and makes no attempt to understand anything. It will
miss parts it has no word for and will not infer intent. That is the trade:
extraction drops from a multi-second provider round trip to well under a
millisecond, and works on a plane.

Every job card it produces carries a flag in `unbilled_items_flagged` saying
it was machine-guessed offline, so a stub card can never be mistaken for a
real extraction in the review screen or on a printed PDF.

Never enable this in production — `LLM_PROVIDER=stub` is dev-only and the
server logs a warning on every startup while it is active.
"""

import logging
import re
from typing import List, Optional

from schemas import JobCardExtraction, PartUsed

logger = logging.getLogger(__name__)

# Kept in step with the vocabulary bias in `transcription.VOCABULARY_PROMPT` —
# these are the makes Whisper is already primed to transcribe correctly.
VEHICLE_MAKES = (
    "Volkswagen", "Toyota", "Honda", "Ford", "Chevrolet", "Nissan", "BMW",
    "Mercedes-Benz", "Mercedes", "Audi", "Hyundai", "Kia", "Mazda", "Subaru",
    "Jeep", "Ram", "GMC", "Chrysler", "Dodge", "Volvo", "Land Rover",
    "Porsche", "Tesla",
)

# Multi-word entries must precede any single-word entry they contain, so that
# "serpentine belt" wins over a bare "belt" when both would match.
PART_NAMES = (
    "serpentine belt", "timing belt", "belt tensioner pulley",
    "tensioner assembly", "tensioner pulley", "tensioner",
    "brake pads", "brake discs", "brake rotors", "brake fluid",
    "oil filter", "air filter", "cabin filter", "fuel filter",
    "spark plugs", "glow plugs", "ignition coil",
    "water pump", "fuel pump", "radiator", "thermostat", "alternator",
    "starter motor", "battery", "clutch", "shock absorbers", "wiper blades",
    "engine oil", "coolant", "gearbox oil",
)

_NUMBER_WORDS = {
    "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "twelve": 12,
}

# Verbs that mark a sentence as describing work rather than diagnosis chatter.
_WORK_VERBS = (
    "replace", "replaced", "repair", "repaired", "fit", "fitted", "install",
    "installed", "change", "changed", "top up", "topped up", "flush",
    "flushed", "adjust", "adjusted", "clean", "cleaned", "service", "serviced",
    "diagnose", "diagnosed", "inspect", "inspected", "check", "checked",
)

STUB_NOTICE = (
    "Generated offline without AI — every field is a guess from keyword "
    "matching. Verify the vehicle, parts and labour time before invoicing."
)


def extract_jobcard_offline(transcript: str) -> JobCardExtraction:
    """Best-effort structured job card from `transcript`, with no model."""
    text = " ".join(transcript.split())

    parts = _find_parts(text)
    flags = [STUB_NOTICE]
    flags.extend(_find_flags(text, parts))

    return JobCardExtraction(
        vehicle_info=_find_vehicle(text) or "<UNKNOWN>",
        labor_hours=_find_labor_hours(text) or 0.0,
        work_performed=_find_work_performed(text),
        parts_used=parts,
        unbilled_items_flagged=flags,
    )


def _find_vehicle(text: str) -> Optional[str]:
    """Assemble "<year> <make> <model>" from whatever of the three is present."""
    make_match = None
    for make in VEHICLE_MAKES:
        match = re.search(rf"\b{re.escape(make)}\b", text, re.IGNORECASE)
        # Prefer the earliest mention so a later passing reference to another
        # make (e.g. "unlike the Audi") does not win.
        if match and (make_match is None or match.start() < make_match[1].start()):
            make_match = (make, match)
    if make_match is None:
        return None

    make, match = make_match

    # A model year anywhere in the sentence, 1980..2099 to avoid swallowing
    # part numbers or quantities.
    year = None
    for candidate in re.findall(r"\b(19[89]\d|20\d\d)\b", text):
        year = candidate
        break

    # A model is the capitalised or numeric words immediately after the make —
    # "3 Series", "Golf", "F-150" — stopping at the first lowercase word. A
    # bare year is skipped rather than ending the run, because speech puts it
    # on either side ("BMW 3 Series 2018") and it is prepended separately;
    # without this the year lands in the string twice.
    tail = text[match.end():].lstrip()
    model_words: List[str] = []
    for word in tail.split()[:4]:
        cleaned = word.strip(".,;:!?")
        # Punctuation ends the vehicle phrase. Without this the run continues
        # into the next sentence and captures its opening word, turning
        # "…Golf. Replaced the oil…" into "Volkswagen Golf Replaced".
        ends_clause = word != cleaned
        if cleaned and not re.fullmatch(r"19[89]\d|20\d\d", cleaned):
            if not (cleaned[0].isupper() or cleaned[0].isdigit()):
                break
            model_words.append(cleaned)
        if ends_clause:
            break

    pieces = [p for p in (year, make, " ".join(model_words).strip()) if p]
    return " ".join(pieces).strip() or None


def _find_labor_hours(text: str) -> Optional[float]:
    """Hours worked, preferring a figure explicitly tied to labour."""
    # "2 hours", "2.5 hrs", "half an hour", "90 minutes", "two hours"
    patterns = [
        (r"(\d+(?:\.\d+)?)\s*(?:hours?|hrs?)\b", lambda m: float(m.group(1))),
        (r"\b(half an hour|half hour)\b", lambda m: 0.5),
        (r"(\d+)\s*minutes?\b", lambda m: round(int(m.group(1)) / 60, 2)),
        (
            rf"\b({'|'.join(w for w in _NUMBER_WORDS if len(w) > 2)})\s+(?:hours?|hrs?)\b",
            lambda m: float(_NUMBER_WORDS[m.group(1).lower()]),
        ),
    ]

    matches: List[tuple[int, float]] = []
    for pattern, convert in patterns:
        for match in re.finditer(pattern, text, re.IGNORECASE):
            matches.append((match.start(), convert(match)))
    if not matches:
        return None

    # "Total labor duration 2 hours" is more authoritative than an offhand
    # "took about 3 hours last time", so a figure near a labour cue wins.
    for position, value in matches:
        window = text[max(0, position - 40):position].lower()
        if any(cue in window for cue in ("labor", "labour", "total", "billable")):
            return value
    return matches[0][1]


def _find_parts(text: str) -> List[PartUsed]:
    lowered = text.lower()
    found: List[PartUsed] = []
    claimed: List[tuple[int, int]] = []

    for name in PART_NAMES:
        for match in re.finditer(rf"\b{re.escape(name)}\b", lowered):
            span = match.span()
            # Skip a part already covered by a longer name matched earlier
            # ("belt" inside "serpentine belt").
            if any(start <= span[0] and span[1] <= end for start, end in claimed):
                continue
            claimed.append(span)
            found.append(
                PartUsed(part_name=name, quantity=_quantity_before(lowered, span[0]))
            )
            break  # one line per part, however often it is mentioned

    return found


def _quantity_before(lowered: str, position: int) -> int:
    """The count immediately preceding a part name; 1 when unstated."""
    window = lowered[max(0, position - 24):position]
    match = re.search(r"(\d+|" + "|".join(_NUMBER_WORDS) + r")\s+(?:new\s+|\w+\s+)?$", window)
    if not match:
        return 1
    token = match.group(1)
    if token.isdigit():
        value = int(token)
        # A year or a viscosity grade is not a quantity.
        return value if 1 <= value <= 99 else 1
    return _NUMBER_WORDS.get(token, 1)


def _find_work_performed(text: str) -> str:
    """Sentences that describe work, falling back to the whole transcript."""
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]
    relevant = [
        s for s in sentences
        if any(re.search(rf"\b{verb}\b", s, re.IGNORECASE) for verb in _WORK_VERBS)
    ]
    return " ".join(relevant) if relevant else text


def _find_flags(text: str, parts: List[PartUsed]) -> List[str]:
    """Things a mechanic commonly forgets to bill, spotted by keyword."""
    flags: List[str] = []
    lowered = text.lower()

    if not parts:
        flags.append("No parts were recognised in the recording — add them manually.")
    if re.search(r"\b(also|while I was in there|noticed|might need|should be replaced)\b", lowered):
        flags.append(
            "The recording mentions extra work in passing — check it is itemised."
        )
    if re.search(r"\b(topped up|top up|fluid|coolant|oil)\b", lowered) and not any(
        p.part_name in ("engine oil", "coolant", "brake fluid", "gearbox oil") for p in parts
    ):
        flags.append("Fluids are mentioned but not itemised as parts.")
    return flags

"""Offline (no-AI) extractor.

The stub only has to be predictable and honest — it is keyword matching, not
understanding. These tests pin the behaviour that the review screen depends on:
plausible fields, correct quantities, and a flag on every card saying it was
guessed.
"""

import pytest

from schemas import JobCardExtraction
from stub_extraction import STUB_NOTICE, extract_jobcard_offline

BMW = (
    "Diagnosed on engine squeal on a BMW 3 Series 2018. The serpentine belt is "
    "cracked and the belt tensioner pulley is failing. Replace the serpentine "
    "belt and the tensioner assembly. Total labor duration 2 hours."
)


def test_returns_a_valid_jobcard_extraction():
    assert isinstance(extract_jobcard_offline(BMW), JobCardExtraction)


def test_every_card_is_flagged_as_machine_guessed():
    # The review screen and the PDF both surface these flags — this is what
    # stops a stub card being mistaken for a real extraction.
    assert extract_jobcard_offline(BMW).unbilled_items_flagged[0] == STUB_NOTICE


@pytest.mark.parametrize(
    "transcript,expected",
    [
        (BMW, "2018 BMW 3 Series"),
        ("Oil change on a 2019 Volkswagen Golf. Replaced the oil.", "2019 Volkswagen Golf"),
        ("Changed the brake pads on the Ford F-150. Also checked tyres.", "Ford F-150"),
        ("Worked on the 2021 Mazda CX-5, replaced the battery.", "2021 Mazda CX-5"),
    ],
)
def test_vehicle_is_assembled_from_year_make_model(transcript, expected):
    assert extract_jobcard_offline(transcript).vehicle_info == expected


def test_vehicle_phrase_stops_at_the_sentence_boundary():
    # Regression: stripping the full stop used to let the run continue into the
    # next sentence, producing "Volkswagen Golf Replaced".
    result = extract_jobcard_offline("Serviced a 2019 Volkswagen Golf. Replaced the oil.")
    assert result.vehicle_info == "2019 Volkswagen Golf"


def test_model_year_is_not_repeated_when_it_trails_the_model():
    # Regression: speech puts the year on either side of the model, and the
    # year was being both prepended and captured as a model word.
    assert extract_jobcard_offline(BMW).vehicle_info.count("2018") == 1


def test_unknown_vehicle_is_marked_not_invented():
    assert extract_jobcard_offline("There is a rattle somewhere.").vehicle_info == "<UNKNOWN>"


@pytest.mark.parametrize(
    "transcript,expected_hours",
    [
        ("Replaced the belt. Total labor duration 2 hours.", 2.0),
        ("Replaced the oil. Took about half an hour.", 0.5),
        ("Serviced the car. 90 minutes.", 1.5),
        ("Changed the pads. Labour three hours.", 3.0),
        ("Replaced the clutch. 2.5 hrs.", 2.5),
    ],
)
def test_labor_hours_are_parsed_from_several_phrasings(transcript, expected_hours):
    assert extract_jobcard_offline(transcript).labor_hours == expected_hours


def test_labor_figure_wins_over_an_offhand_duration():
    result = extract_jobcard_offline(
        "The same job took 5 hours last time. Total labor duration 2 hours."
    )
    assert result.labor_hours == 2.0


def test_missing_hours_default_to_zero_rather_than_guessing():
    assert extract_jobcard_offline("Replaced the battery.").labor_hours == 0.0


def test_quantities_are_read_from_digits_and_words():
    parts = {p.part_name: p.quantity for p in extract_jobcard_offline(
        "Changed four brake pads and two brake discs."
    ).parts_used}
    assert parts == {"brake pads": 4, "brake discs": 2}


def test_quantity_defaults_to_one_when_unstated():
    parts = extract_jobcard_offline("Replaced the battery.").parts_used
    assert [(p.part_name, p.quantity) for p in parts] == [("battery", 1)]


def test_a_year_is_never_read_as_a_quantity():
    parts = {p.part_name: p.quantity for p in extract_jobcard_offline(
        "On the 2019 Volkswagen Golf, fitted an oil filter."
    ).parts_used}
    assert parts["oil filter"] == 1


def test_longer_part_names_win_over_the_words_inside_them():
    # "serpentine belt" must not also register as a bare "belt", and
    # "belt tensioner pulley" must not double up with "tensioner".
    names = [p.part_name for p in extract_jobcard_offline(BMW).parts_used]
    assert "serpentine belt" in names
    assert names.count("serpentine belt") == 1
    assert "belt" not in names


def test_a_part_mentioned_repeatedly_appears_once():
    names = [p.part_name for p in extract_jobcard_offline(
        "The serpentine belt was cracked so I replaced the serpentine belt."
    ).parts_used]
    assert names == ["serpentine belt"]


def test_work_performed_prefers_action_sentences():
    result = extract_jobcard_offline(BMW)
    assert "Replace the serpentine belt" in result.work_performed
    assert "is cracked" not in result.work_performed


def test_work_performed_falls_back_to_the_whole_transcript():
    transcript = "Rattle from somewhere near the front."
    assert extract_jobcard_offline(transcript).work_performed == transcript


def test_recordings_with_no_recognisable_parts_are_flagged():
    flags = extract_jobcard_offline("There is a rattle somewhere.").unbilled_items_flagged
    assert any("No parts were recognised" in f for f in flags)


def test_work_mentioned_in_passing_is_flagged():
    flags = extract_jobcard_offline(
        "Changed the brake pads. Also noticed the wiper blades are worn."
    ).unbilled_items_flagged
    assert any("in passing" in f for f in flags)


def test_empty_transcript_does_not_crash():
    result = extract_jobcard_offline("")
    assert result.vehicle_info == "<UNKNOWN>"
    assert result.labor_hours == 0.0
    assert result.parts_used == []

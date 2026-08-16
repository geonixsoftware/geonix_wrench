"""PDF export coverage.

There was none before, which is how `_build_header_image()` shipped calling
`get_active_logo_path()` with no argument: every single job card export raised
TypeError, so the headline "PDF export for every job" feature was dead for both
plans. These tests exercise the whole document build so a signature change in
the logo lookup can never break the export silently again.
"""

import pdf_generator
from scoping import OwnerScope

_PDF_MAGIC = b"%PDF-"


def _jobcard(**overrides):
    jobcard = {
        "id": 7,
        "created_at": "2026-08-15T10:00:00+00:00",
        "vehicle_info": "VW Golf 1.6 TDI",
        "work_performed": "Oil and filter change",
        "parts_used": [
            {"part_name": "Oil filter", "quantity": 1, "unit_price": 12.5},
            {"part_name": "5W-30 oil", "quantity": 5, "unit_price": None},
        ],
        "labor_hours": 1.5,
        "labor_rate": 60.0,
        "notes": "Next service in 15000 km",
        "unbilled_items_flagged": 0,
        "transcript": "irrelevant to the PDF",
    }
    jobcard.update(overrides)
    return jobcard


def test_generates_a_pdf_for_a_personal_scope():
    data = pdf_generator.generate_jobcard_pdf(
        _jobcard(), OwnerScope(org_id=None, user_id=1)
    )
    assert data.startswith(_PDF_MAGIC)
    assert len(data) > 1000


def test_generates_a_pdf_for_an_org_scope():
    data = pdf_generator.generate_jobcard_pdf(
        _jobcard(), OwnerScope(org_id=3, user_id=1)
    )
    assert data.startswith(_PDF_MAGIC)


def test_header_uses_the_owners_logo(monkeypatch):
    # The owner scope has to reach the logo lookup, otherwise a shop's uploaded
    # logo silently never appears on its paperwork.
    from config import DEFAULT_LOGO_PATH

    seen = {}

    def fake_lookup(owner):
        seen["owner"] = owner
        return DEFAULT_LOGO_PATH

    monkeypatch.setattr(pdf_generator, "get_active_logo_path", fake_lookup)

    owner = OwnerScope(org_id=42, user_id=9)
    pdf_generator.generate_jobcard_pdf(_jobcard(), owner)
    assert seen["owner"] == owner


def test_date_is_rendered_readably_not_as_a_raw_timestamp():
    assert pdf_generator._format_date("2026-08-15T10:00:00+00:00") == "15 August 2026"
    assert pdf_generator._format_date("2026-01-02") == "2 January 2026"


def test_date_falls_back_to_the_raw_value_when_unparseable():
    # Better a stored oddity on the invoice than no date at all.
    assert pdf_generator._format_date("last tuesday") == "last tuesday"
    assert pdf_generator._format_date(None) == ""


def test_handles_a_jobcard_with_no_parts():
    data = pdf_generator.generate_jobcard_pdf(
        _jobcard(parts_used=[]), OwnerScope(org_id=None, user_id=1)
    )
    assert data.startswith(_PDF_MAGIC)

"""Job card text cannot inject markup into a customer's invoice.

reportlab's Paragraph parses a small HTML-like markup — <b>, <br/>,
<font color=...>. The vehicle and work-performed fields come back from a model
reading a customer's recording, so their contents are outside anyone's control
here, and they were passed in unescaped. Two consequences, both reproduced
below before the fix: a stray "<" aborted the render so the job produced no PDF
at all, and well-formed markup was honoured, letting extracted text restyle the
invoice a shop hands to a customer.
"""

import pytest

from pdf_generator import _user_paragraph
from reportlab.lib.styles import getSampleStyleSheet


@pytest.fixture
def style():
    return getSampleStyleSheet()["BodyText"]


@pytest.mark.parametrize(
    "text",
    [
        "Part <unknown",                      # aborted the whole render
        "Torque < 90 Nm",                     # ordinary speech
        "<b>PAID IN FULL</b>",                # forged emphasis
        "<font color='white'>hidden</font>",  # text invisible on the invoice
        "AC & heater unit",                   # bare ampersand
        "<<<>>>&&&",
        "</para><para>",                      # breaking out of the element
    ],
)
def test_hostile_field_text_still_renders(text, style):
    para = _user_paragraph(text, style)
    para.wrap(400, 200)  # the step that used to raise


def test_markup_is_shown_not_interpreted(style):
    para = _user_paragraph("<b>PAID IN FULL</b>", style)
    # The escaped source is what reportlab receives, so the tags reach the page
    # as characters a reader can see rather than as formatting.
    assert "&lt;b&gt;" in para.text
    assert "<b>" not in para.text


def test_ampersand_survives_as_itself(style):
    assert "&amp;" in _user_paragraph("AC & heater unit", style).text


def test_length_cap_still_counts_real_characters(style):
    # Escaping after truncation matters: doing it the other way round makes
    # "&amp;" eat five characters of a shop's budget and can cut an entity in
    # half, which reportlab then rejects.
    para = _user_paragraph("&" * 50, style, limit=10)
    assert para.text.count("&amp;") == 9
    para.wrap(400, 200)

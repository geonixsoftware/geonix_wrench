import io
from datetime import datetime
from typing import Any, Dict
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (
    Image,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)
from PIL import Image as PILImage
from svglib.svglib import svg2rlg

from config import (
    DEFAULT_CURRENCY,
    DEFAULT_LABOR_RATE,
    DEFAULT_LOGO_PATH,
    MAX_FIELD_CHARS,
    MAX_PARTS_PER_JOBCARD,
    SUPPORTED_CURRENCIES,
)
from currency import format_amount, normalize as normalize_currency
from pdf_fonts import register_fonts
from pricing import effective_unit_price, format_quantity, line_total
from logo_storage import SVG_EXTENSION, get_active_logo_path
from scoping import OwnerScope

BRAND_COLOR = colors.HexColor("#1F3A5F")
ACCENT_COLOR = colors.HexColor("#F2A900")


def _clip(text: object, limit: int = MAX_FIELD_CHARS) -> str:
    """Bound a field before it reaches reportlab.

    Long or control-character-laden strings can stall or break Paragraph
    layout, and nothing upstream constrained these — they come from an LLM
    reading a user's speech.
    """
    value = "" if text is None else str(text)
    value = "".join(ch for ch in value if ch == "\n" or ch >= " ")
    if len(value) > limit:
        value = value[: limit - 1].rstrip() + "\u2026"
    return value



def _user_paragraph(text: object, style: ParagraphStyle, limit: int = MAX_FIELD_CHARS) -> Paragraph:
    """Build a Paragraph from text the shop did not write.

    Paragraph parses a small HTML-like markup — <b>, <br/>, <font color=...>.
    These fields come back from a model reading a customer's recording, so
    their content is ultimately outside anyone's control here, and unescaped
    they cause two separate problems:

      - a stray "<" ("Part <unknown") aborts the render with a paraparser
        ValueError, so the job card produces no PDF at all; and
      - well-formed markup is honoured, which lets extracted text restyle a
        customer-facing invoice — <font color='white'> hides a line outright.

    Escaping happens after _clip so the character limit still counts real
    characters and cannot slice an entity in half.

    Table cells deliberately do not come through here. reportlab draws those
    strings literally rather than parsing them, so escaping a part name would
    print "AC &amp; heater" on the invoice.
    """
    return Paragraph(escape(_clip(text, limit)), style)


def _format_date(value: Any) -> str:
    """Render a stored timestamp as a readable date.

    The header printed `created_at` verbatim, so every customer-facing job card
    carried a raw ISO timestamp ("2026-08-15T10:00:00+00:00") where a date
    belongs. Unparseable values fall back to the original string rather than
    dropping the date from an invoice.
    """
    if not value:
        return ""
    try:
        parsed = datetime.fromisoformat(str(value))
    except ValueError:
        return str(value)
    # Day first, spelled-out month: unambiguous for the European shops this is
    # sold to, unlike a numeric-only format.
    return f"{parsed.day} {parsed.strftime('%B %Y')}"


def _format_labor_time(hours: float) -> str:
    total_minutes = round(hours * 60)
    h, m = divmod(total_minutes, 60)
    if h and m:
        return f"{h}h {m}m"
    if h:
        return f"{h}h"
    return f"{m}m"


LOGO_MAX_HEIGHT = 0.5 * inch
LOGO_MAX_WIDTH = 2.5 * inch


def _build_header_image(owner: OwnerScope):
    """The shop's logo, fitted into the header box.

    A stored SVG is drawn as vector rather than as a picture of one: it goes
    into the story as a reportlab Drawing, so it prints at the printer's
    resolution instead of the 1000px cap raster uploads carry.
    """
    logo_path = get_active_logo_path(owner)

    if logo_path.lower().endswith(SVG_EXTENSION):
        drawing = svg2rlg(logo_path)
        if drawing is not None and drawing.width and drawing.height:
            scale = min(LOGO_MAX_HEIGHT / drawing.height, LOGO_MAX_WIDTH / drawing.width)
            drawing.width *= scale
            drawing.height *= scale
            drawing.scale(scale, scale)
            drawing.hAlign = "LEFT"
            return drawing
        # A logo that stopped parsing must not cost the shop its job card; fall
        # through to the packaged default.
        logo_path = DEFAULT_LOGO_PATH

    with PILImage.open(logo_path) as img:
        width_px, height_px = img.size
    scale = min(LOGO_MAX_HEIGHT / height_px, LOGO_MAX_WIDTH / width_px)
    return Image(logo_path, width=width_px * scale, height=height_px * scale, hAlign="LEFT")


def generate_jobcard_pdf(
    jobcard: Dict[str, Any],
    owner: OwnerScope,
    currency: str = DEFAULT_CURRENCY,
    labor_rate: float = DEFAULT_LABOR_RATE,
) -> bytes:
    # Normalised rather than looked up directly: values have arrived here as
    # "currency: USD" and as a bare symbol, and an unrecognised one used to
    # fall through to the default — which priced a Czech shop's invoice in
    # dollars instead of failing visibly. See currency.normalize.
    currency_code = normalize_currency(currency)

    def money(value: float) -> str:
        return format_amount(value, currency_code)

    regular_font, bold_font = register_fonts()

    buffer = io.BytesIO()
    doc = SimpleDocTemplate(
        buffer,
        pagesize=letter,
        topMargin=0.6 * inch,
        bottomMargin=0.6 * inch,
        leftMargin=0.6 * inch,
        rightMargin=0.6 * inch,
    )
    styles = getSampleStyleSheet()
    # Every style is pinned to the registered font. Leaving any of them on the
    # stylesheet default would put Helvetica back on that run of text, and the
    # missing glyph would reappear only in whichever paragraph was overlooked.
    subtitle_style = ParagraphStyle(
        "Subtitle", parent=styles["Normal"], textColor=colors.grey, fontSize=10,
        fontName=regular_font,
    )
    section_style = ParagraphStyle(
        "Section", parent=styles["Heading2"], textColor=BRAND_COLOR, fontSize=13,
        spaceBefore=14, spaceAfter=6, fontName=bold_font,
    )
    body_style = ParagraphStyle(
        "Body", parent=styles["BodyText"], fontName=regular_font
    )

    elements = []
    elements.append(_build_header_image(owner))
    elements.append(Spacer(1, 0.15 * inch))
    elements.append(Paragraph(f"Estimate / Invoice — Job Card #{jobcard['id']}", subtitle_style))
    elements.append(
        Paragraph(f"Date: {_format_date(jobcard['created_at'])}", subtitle_style)
    )
    elements.append(Spacer(1, 0.25 * inch))

    elements.append(Paragraph("Vehicle Information", section_style))
    elements.append(_user_paragraph(jobcard["vehicle_info"], body_style))

    elements.append(Paragraph("Work Performed", section_style))
    elements.append(_user_paragraph(jobcard["work_performed"], body_style))

    elements.append(Paragraph("Labor & Parts", section_style))

    labor_cost = jobcard["labor_hours"] * labor_rate
    line_items = [["Description", "Qty", "Rate", "Amount"]]
    line_items.append([
        "Labor",
        _format_labor_time(jobcard["labor_hours"]),
        f"{money(labor_rate)}/hr",
        money(labor_cost),
    ])

    parts_total = 0.0
    has_tbd_parts = False
    # Cap the row count as well as each field; an LLM can return an
    # arbitrarily long parts list.
    for part in jobcard["parts_used"][:MAX_PARTS_PER_JOBCARD]:
        name = _clip(part["part_name"], 200)
        quantity = format_quantity(part.get("quantity"))
        amount = line_total(part)

        if amount is None:
            has_tbd_parts = True
            line_items.append([name, quantity, "TBD", "TBD"])
            continue

        # The rate is presentational only. Where the shop entered a total for
        # the whole quantity this is derived from it — printing money(amount)
        # from the *stated* total rather than from rate * quantity is what
        # stops a 50.00 fill of oil being invoiced as 50.01.
        rate = effective_unit_price(part)
        parts_total += amount
        line_items.append([
            name,
            quantity,
            money(rate) if rate is not None else "—",
            money(amount),
        ])

    subtotal = labor_cost + parts_total
    line_items.append(["", "", "Subtotal", money(subtotal)])

    table = Table(line_items, colWidths=[3.0 * inch, 1.0 * inch, 1.3 * inch, 1.3 * inch])
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), BRAND_COLOR),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                ("FONTNAME", (0, 0), (-1, 0), bold_font),
                ("FONTNAME", (0, 1), (-1, -1), regular_font),
                ("FONTSIZE", (0, 0), (-1, -1), 9.5),
                ("ALIGN", (1, 0), (-1, -1), "RIGHT"),
                ("ROWBACKGROUNDS", (0, 1), (-1, -2), [colors.white, colors.whitesmoke]),
                ("LINEBELOW", (0, 0), (-1, 0), 1, BRAND_COLOR),
                ("LINEABOVE", (0, -1), (-1, -1), 1, ACCENT_COLOR),
                ("FONTNAME", (0, -1), (-1, -1), bold_font),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
                ("RIGHTPADDING", (0, 0), (-1, -1), 12),
            ]
        )
    )
    elements.append(table)

    elements.append(Spacer(1, 0.4 * inch))
    # The "Currency: USD" line that used to sit here is gone. Every amount above
    # now carries its own symbol, so a bare three-letter code told the customer
    # nothing the figures did not already say.
    if has_tbd_parts:
        elements.append(Paragraph("Parts pricing marked TBD requires manual entry before final invoicing.", subtitle_style))

    doc.build(elements)
    return buffer.getvalue()

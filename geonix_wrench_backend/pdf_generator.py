import io
from datetime import datetime
from typing import Any, Dict

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

from config import (
    DEFAULT_CURRENCY,
    DEFAULT_LABOR_RATE,
    MAX_FIELD_CHARS,
    MAX_PARTS_PER_JOBCARD,
    SUPPORTED_CURRENCIES,
)
from logo_storage import get_active_logo_path
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


def _build_header_image(owner: OwnerScope) -> Image:
    logo_path = get_active_logo_path(owner)
    with PILImage.open(logo_path) as img:
        width_px, height_px = img.size
    max_height = 0.5 * inch
    max_width = 2.5 * inch
    scale = min(max_height / height_px, max_width / width_px)
    return Image(logo_path, width=width_px * scale, height=height_px * scale, hAlign="LEFT")


def generate_jobcard_pdf(
    jobcard: Dict[str, Any],
    owner: OwnerScope,
    currency: str = DEFAULT_CURRENCY,
    labor_rate: float = DEFAULT_LABOR_RATE,
) -> bytes:
    currency = currency.upper() if currency.upper() in SUPPORTED_CURRENCIES else DEFAULT_CURRENCY
    symbol = SUPPORTED_CURRENCIES[currency]

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
    subtitle_style = ParagraphStyle(
        "Subtitle", parent=styles["Normal"], textColor=colors.grey, fontSize=10
    )
    section_style = ParagraphStyle(
        "Section", parent=styles["Heading2"], textColor=BRAND_COLOR, fontSize=13, spaceBefore=14, spaceAfter=6
    )
    body_style = styles["BodyText"]

    elements = []
    elements.append(_build_header_image(owner))
    elements.append(Spacer(1, 0.15 * inch))
    elements.append(Paragraph(f"Estimate / Invoice — Job Card #{jobcard['id']}", subtitle_style))
    elements.append(
        Paragraph(f"Date: {_format_date(jobcard['created_at'])}", subtitle_style)
    )
    elements.append(Spacer(1, 0.25 * inch))

    elements.append(Paragraph("Vehicle Information", section_style))
    elements.append(Paragraph(_clip(jobcard["vehicle_info"]), body_style))

    elements.append(Paragraph("Work Performed", section_style))
    elements.append(Paragraph(_clip(jobcard["work_performed"]), body_style))

    elements.append(Paragraph("Labor & Parts", section_style))

    labor_cost = jobcard["labor_hours"] * labor_rate
    line_items = [["Description", "Qty", "Rate", "Amount"]]
    line_items.append([
        "Labor",
        _format_labor_time(jobcard["labor_hours"]),
        f"{symbol} {labor_rate:,.2f}/hr",
        f"{symbol} {labor_cost:,.2f}",
    ])

    parts_total = 0.0
    has_tbd_parts = False
    # Cap the row count as well as each field; an LLM can return an
    # arbitrarily long parts list.
    for part in jobcard["parts_used"][:MAX_PARTS_PER_JOBCARD]:
        unit_price = part.get("unit_price")
        if unit_price is None:
            has_tbd_parts = True
            line_items.append([_clip(part["part_name"], 200), str(part["quantity"]), "TBD", "TBD"])
        else:
            amount = unit_price * part["quantity"]
            parts_total += amount
            line_items.append([
                _clip(part["part_name"], 200),
                str(part["quantity"]),
                f"{symbol} {unit_price:,.2f}",
                f"{symbol} {amount:,.2f}",
            ])

    subtotal = labor_cost + parts_total
    line_items.append(["", "", "Subtotal", f"{symbol} {subtotal:,.2f}"])

    table = Table(line_items, colWidths=[3.0 * inch, 1.0 * inch, 1.3 * inch, 1.3 * inch])
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), BRAND_COLOR),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                ("FONTSIZE", (0, 0), (-1, -1), 9.5),
                ("ALIGN", (1, 0), (-1, -1), "RIGHT"),
                ("ROWBACKGROUNDS", (0, 1), (-1, -2), [colors.white, colors.whitesmoke]),
                ("LINEBELOW", (0, 0), (-1, 0), 1, BRAND_COLOR),
                ("LINEABOVE", (0, -1), (-1, -1), 1, ACCENT_COLOR),
                ("FONTNAME", (0, -1), (-1, -1), "Helvetica-Bold"),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
                ("RIGHTPADDING", (0, 0), (-1, -1), 12),
            ]
        )
    )
    elements.append(table)

    elements.append(Spacer(1, 0.4 * inch))
    elements.append(Paragraph(f"Currency: {currency}", subtitle_style))
    if has_tbd_parts:
        elements.append(Paragraph("Parts pricing marked TBD requires manual entry before final invoicing.", subtitle_style))

    doc.build(elements)
    return buffer.getvalue()

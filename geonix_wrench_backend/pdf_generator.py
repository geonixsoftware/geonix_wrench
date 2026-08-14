import io
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

from config import DEFAULT_CURRENCY, DEFAULT_LABOR_RATE, SUPPORTED_CURRENCIES
from logo_storage import get_active_logo_path

BRAND_COLOR = colors.HexColor("#1F3A5F")
ACCENT_COLOR = colors.HexColor("#F2A900")


def _format_labor_time(hours: float) -> str:
    total_minutes = round(hours * 60)
    h, m = divmod(total_minutes, 60)
    if h and m:
        return f"{h}h {m}m"
    if h:
        return f"{h}h"
    return f"{m}m"


def _build_header_image() -> Image:
    logo_path = get_active_logo_path()
    with PILImage.open(logo_path) as img:
        width_px, height_px = img.size
    max_height = 0.5 * inch
    max_width = 2.5 * inch
    scale = min(max_height / height_px, max_width / width_px)
    return Image(logo_path, width=width_px * scale, height=height_px * scale, hAlign="LEFT")


def generate_jobcard_pdf(jobcard: Dict[str, Any], currency: str = DEFAULT_CURRENCY, labor_rate: float = DEFAULT_LABOR_RATE) -> bytes:
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
    elements.append(_build_header_image())
    elements.append(Spacer(1, 0.15 * inch))
    elements.append(Paragraph(f"Estimate / Invoice — Job Card #{jobcard['id']}", subtitle_style))
    elements.append(Paragraph(f"Date: {jobcard['created_at']}", subtitle_style))
    elements.append(Spacer(1, 0.25 * inch))

    elements.append(Paragraph("Vehicle Information", section_style))
    elements.append(Paragraph(jobcard["vehicle_info"], body_style))

    elements.append(Paragraph("Work Performed", section_style))
    elements.append(Paragraph(jobcard["work_performed"], body_style))

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
    for part in jobcard["parts_used"]:
        unit_price = part.get("unit_price")
        if unit_price is None:
            has_tbd_parts = True
            line_items.append([part["part_name"], str(part["quantity"]), "TBD", "TBD"])
        else:
            amount = unit_price * part["quantity"]
            parts_total += amount
            line_items.append([
                part["part_name"],
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

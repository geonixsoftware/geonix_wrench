"""A PDF font that can actually draw the characters on these invoices.

reportlab's built-in Helvetica is a Type1 font using WinAnsiEncoding, which is
Latin-1. That covers €, £ and German umlauts, but *not* Latin Extended-A — so
the moment a currency symbol became Kč or zł, or a Czech mechanic described a
job containing ř or ě, the glyph was missing and the invoice printed a blank or
a black box. Verified rather than assumed: 'ccaron' and 'lslash' are absent
from reportlab's WinAnsiEncoding table.

Resolution order, best coverage first:

  1. DejaVu Sans from the system. Full Latin Extended-A, standard on Debian —
     which is what the API runs on.
  2. Bitstream Vera, which ships inside reportlab itself, so it is always
     available. Covers č, ł and € but not ř or ą.
  3. Helvetica. No registration, the previous behaviour, so a font problem
     degrades to "some accents are wrong" rather than "no PDF at all".
"""

import os
from typing import Optional, Tuple

from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

import logging

logger = logging.getLogger(__name__)

_REGULAR = "GeonixSans"
_BOLD = "GeonixSans-Bold"

# (regular, bold) candidates in order of preference.
_CANDIDATES: Tuple[Tuple[str, str], ...] = (
    (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ),
    (
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    ),
    (
        "/Library/Fonts/DejaVuSans.ttf",
        "/Library/Fonts/DejaVuSans-Bold.ttf",
    ),
)

_resolved: Optional[Tuple[str, str]] = None


def _reportlab_vera() -> Optional[Tuple[str, str]]:
    try:
        import reportlab

        base = os.path.join(os.path.dirname(reportlab.__file__), "fonts")
        regular = os.path.join(base, "Vera.ttf")
        bold = os.path.join(base, "VeraBd.ttf")
        if os.path.isfile(regular) and os.path.isfile(bold):
            return regular, bold
    except Exception:  # pragma: no cover - only if reportlab moves its fonts
        pass
    return None


def register_fonts() -> Tuple[str, str]:
    """Register the best available pair and return (regular, bold) font names.

    Cached: registering the same TTF for every job card would re-parse and
    re-embed it on each render.
    """
    global _resolved
    if _resolved is not None:
        return _resolved

    candidates = list(_CANDIDATES)
    vera = _reportlab_vera()
    if vera:
        candidates.append(vera)

    for regular_path, bold_path in candidates:
        if not (os.path.isfile(regular_path) and os.path.isfile(bold_path)):
            continue
        try:
            pdfmetrics.registerFont(TTFont(_REGULAR, regular_path))
            pdfmetrics.registerFont(TTFont(_BOLD, bold_path))
            pdfmetrics.registerFontFamily(_REGULAR, normal=_REGULAR, bold=_BOLD)
            logger.info("PDF font: %s", os.path.basename(regular_path))
            _resolved = (_REGULAR, _BOLD)
            return _resolved
        except Exception as e:  # pragma: no cover - corrupt font file
            logger.warning("PDF font %s unusable: %s", regular_path, e)

    logger.warning(
        "No Unicode PDF font found - falling back to Helvetica. Currency "
        "symbols outside Latin-1 (Kc, zl) and Czech or Polish accents will not "
        "render correctly."
    )
    _resolved = ("Helvetica", "Helvetica-Bold")
    return _resolved

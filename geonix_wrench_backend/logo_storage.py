import io
import os
import re

from PIL import Image, UnidentifiedImageError

try:  # Optional: HEIC/HEIF is what an iPhone camera produces by default.
    from pillow_heif import register_heif_opener

    register_heif_opener()
except ImportError:  # pragma: no cover - depends on the deployment's wheels
    pass

from config import DEFAULT_LOGO_PATH, LOGO_STORAGE_DIR, MAX_LOGO_DIMENSION_PX
from scoping import OwnerScope


class InvalidLogoError(Exception):
    pass


# A raster upload is flattened to PNG; an SVG is kept as SVG. It is not
# rasterised because it does not need to be: reportlab draws the vector
# straight into the PDF header (see pdf_generator), so the logo stays sharp at
# any print size, and the server needs no native rasteriser to deploy.
PNG_EXTENSION = ".png"
SVG_EXTENSION = ".svg"
_STORED_EXTENSIONS = (PNG_EXTENSION, SVG_EXTENSION)

# An SVG is XML, and XML that a stranger uploads is an attack surface before it
# is a picture. Rather than trusting a parser's defaults, anything that could
# make it reach outside the document — a doctype or entity declaration (XXE), a
# remote reference — or that could execute where it is displayed — a script, an
# event handler, embedded HTML — is refused before it is ever parsed or stored.
# A shop logo needs none of these.
_SVG_SNIFF_BYTES = 2048
_SVG_FORBIDDEN = re.compile(rb"<!DOCTYPE|<!ENTITY|<script|<foreignObject", re.IGNORECASE)
_SVG_REMOTE_REF = re.compile(
    rb"""(?:xlink:)?href\s*=\s*["']?\s*(?:https?:|ftp:|file:|//)""", re.IGNORECASE
)
_SVG_EVENT_HANDLER = re.compile(rb"""\son[a-z]+\s*=\s*["']""", re.IGNORECASE)


def _logo_path(owner: OwnerScope, extension: str) -> str:
    stem = f"org_{owner.org_id}" if owner.org_id is not None else f"user_{owner.user_id}"
    return os.path.join(LOGO_STORAGE_DIR, f"{stem}{extension}")


def _stored_logo_path(owner: OwnerScope) -> str | None:
    for extension in _STORED_EXTENSIONS:
        path = _logo_path(owner, extension)
        if os.path.isfile(path):
            return path
    return None


def has_custom_logo(owner: OwnerScope) -> bool:
    return _stored_logo_path(owner) is not None


def get_active_logo_path(owner: OwnerScope) -> str:
    return _stored_logo_path(owner) or DEFAULT_LOGO_PATH


def looks_like_svg(data: bytes) -> bool:
    head = data[:_SVG_SNIFF_BYTES].lstrip()
    return head.startswith(b"<?xml") or head.startswith(b"<svg") or b"<svg" in head


def _validated_svg(data: bytes) -> bytes:
    if (
        _SVG_FORBIDDEN.search(data)
        or _SVG_REMOTE_REF.search(data)
        or _SVG_EVENT_HANDLER.search(data)
    ):
        raise InvalidLogoError(
            "SVG logos cannot contain doctypes, scripts, or references to other files"
        )

    try:
        from svglib.svglib import svg2rlg
    except ImportError:  # pragma: no cover - depends on the deployment's wheels
        raise InvalidLogoError("This server cannot accept SVG logos") from None

    # Parsed here and thrown away: proving the file renders at upload time is
    # what stops a broken logo from taking down every later PDF instead.
    try:
        drawing = svg2rlg(io.BytesIO(data))
    except Exception:
        raise InvalidLogoError("Uploaded file is not a valid SVG") from None

    if drawing is None or not drawing.width or not drawing.height:
        raise InvalidLogoError("Uploaded file is not a valid SVG")

    return data


def save_shop_logo(data: bytes, owner: OwnerScope) -> None:
    if looks_like_svg(data):
        stored = _validated_svg(data)
        extension = SVG_EXTENSION
    else:
        stored = _flattened_raster(data)
        extension = PNG_EXTENSION

    os.makedirs(LOGO_STORAGE_DIR, exist_ok=True)
    with open(_logo_path(owner, extension), "wb") as handle:
        handle.write(stored)

    # A shop has one logo. Replacing a PNG with an SVG (or the reverse) must not
    # leave the old file behind for get_active_logo_path to keep finding.
    for other in _STORED_EXTENSIONS:
        if other != extension:
            _remove_if_present(_logo_path(owner, other))


def _flattened_raster(data: bytes) -> bytes:
    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except UnidentifiedImageError:
        raise InvalidLogoError("Uploaded file is not a valid image") from None
    except OSError:
        # A truncated or otherwise broken file of a format Pillow does
        # recognise: still not a logo, and still the uploader's problem to fix.
        raise InvalidLogoError("Uploaded image could not be read") from None

    if image.mode not in ("RGB", "RGBA"):
        image = image.convert("RGBA")
    # The logo is only ever rendered at up to 0.5in tall in the PDF header, so
    # storing (and re-embedding on every PDF) at full upload resolution — a
    # phone photo can be 3000px+ — bloats every generated PDF for no visual
    # benefit. Cap it once here instead.
    if max(image.size) > MAX_LOGO_DIMENSION_PX:
        image.thumbnail((MAX_LOGO_DIMENSION_PX, MAX_LOGO_DIMENSION_PX), Image.LANCZOS)

    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def delete_shop_logo(owner: OwnerScope) -> None:
    for extension in _STORED_EXTENSIONS:
        _remove_if_present(_logo_path(owner, extension))


def _remove_if_present(path: str) -> None:
    if os.path.isfile(path):
        os.remove(path)

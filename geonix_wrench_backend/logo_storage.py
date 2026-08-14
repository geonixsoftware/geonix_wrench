import io
import os

from PIL import Image, UnidentifiedImageError

from config import DEFAULT_LOGO_PATH, LOGO_STORAGE_DIR, MAX_LOGO_DIMENSION_PX
from scoping import OwnerScope


class InvalidLogoError(Exception):
    pass


def _logo_filename(owner: OwnerScope) -> str:
    name = f"org_{owner.org_id}.png" if owner.org_id is not None else f"user_{owner.user_id}.png"
    return os.path.join(LOGO_STORAGE_DIR, name)


def has_custom_logo(owner: OwnerScope) -> bool:
    return os.path.isfile(_logo_filename(owner))


def get_active_logo_path(owner: OwnerScope) -> str:
    return _logo_filename(owner) if has_custom_logo(owner) else DEFAULT_LOGO_PATH


def save_shop_logo(data: bytes, owner: OwnerScope) -> None:
    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except UnidentifiedImageError:
        raise InvalidLogoError("Uploaded file is not a valid image") from None

    os.makedirs(LOGO_STORAGE_DIR, exist_ok=True)
    if image.mode not in ("RGB", "RGBA"):
        image = image.convert("RGBA")
    # The logo is only ever rendered at up to 0.5in tall in the PDF header, so
    # storing (and re-embedding on every PDF) at full upload resolution — a
    # phone photo can be 3000px+ — bloats every generated PDF for no visual
    # benefit. Cap it once here instead.
    if max(image.size) > MAX_LOGO_DIMENSION_PX:
        image.thumbnail((MAX_LOGO_DIMENSION_PX, MAX_LOGO_DIMENSION_PX), Image.LANCZOS)
    image.save(_logo_filename(owner), format="PNG")


def delete_shop_logo(owner: OwnerScope) -> None:
    path = _logo_filename(owner)
    if os.path.isfile(path):
        os.remove(path)

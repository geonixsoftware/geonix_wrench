"""Shop logo intake.

Uploads used to be PNG/JPG/WebP only and were always flattened to PNG, which
rejected the one format a shop is most likely to have been given its logo in.
SVG is now stored as SVG and drawn as vector on the job card — which means the
server is storing a document a stranger wrote, so what it refuses matters as
much as what it accepts.
"""

import io

import pytest
from PIL import Image

import logo_storage
from scoping import OwnerScope

_SVG = b"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="60" viewBox="0 0 240 60">
  <rect width="240" height="60" fill="#1F3A5F"/>
  <circle cx="30" cy="30" r="18" fill="#F2A900"/>
</svg>"""


@pytest.fixture()
def storage(tmp_path, monkeypatch):
    monkeypatch.setattr(logo_storage, "LOGO_STORAGE_DIR", str(tmp_path))
    return OwnerScope(org_id=None, user_id=1)


def _png(size=(120, 40), mode="RGB"):
    buffer = io.BytesIO()
    Image.new(mode, size, "white").save(buffer, format="PNG")
    return buffer.getvalue()


def test_svg_is_stored_as_svg_not_flattened(storage):
    logo_storage.save_shop_logo(_SVG, storage)

    path = logo_storage.get_active_logo_path(storage)
    assert path.endswith(".svg")
    assert logo_storage.has_custom_logo(storage)
    with open(path, "rb") as handle:
        assert b"<svg" in handle.read()


def test_raster_upload_is_still_flattened_to_png(storage):
    logo_storage.save_shop_logo(_png(), storage)

    path = logo_storage.get_active_logo_path(storage)
    assert path.endswith(".png")
    with Image.open(path) as image:
        assert image.format == "PNG"


def test_oversized_raster_is_capped(storage):
    logo_storage.save_shop_logo(_png(size=(4000, 1000)), storage)

    with Image.open(logo_storage.get_active_logo_path(storage)) as image:
        assert max(image.size) == logo_storage.MAX_LOGO_DIMENSION_PX


def test_replacing_a_logo_leaves_only_the_new_one(storage):
    # Both files share a stem, so an orphaned old one would keep winning the
    # lookup and the shop would never see its new logo.
    logo_storage.save_shop_logo(_SVG, storage)
    logo_storage.save_shop_logo(_png(), storage)
    assert logo_storage.get_active_logo_path(storage).endswith(".png")

    logo_storage.save_shop_logo(_SVG, storage)
    assert logo_storage.get_active_logo_path(storage).endswith(".svg")


def test_delete_removes_every_stored_form(storage):
    logo_storage.save_shop_logo(_SVG, storage)
    logo_storage.delete_shop_logo(storage)

    assert not logo_storage.has_custom_logo(storage)
    # Falls back to the packaged default rather than a missing path.
    assert logo_storage.get_active_logo_path(storage).endswith("default_logo.png")


@pytest.mark.parametrize(
    "name,payload",
    [
        (
            "external entity",
            b'<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]>'
            b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">&x;</svg>',
        ),
        (
            "remote reference",
            b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
            b'<image xlink:href="https://example.invalid/x.png"/></svg>',
        ),
        (
            "inline script",
            b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
            b"<script>alert(1)</script></svg>",
        ),
        (
            "event handler",
            b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" '
            b'onload="alert(1)"><rect width="5" height="5"/></svg>',
        ),
    ],
)
def test_hostile_svg_is_refused(storage, name, payload):
    with pytest.raises(logo_storage.InvalidLogoError):
        logo_storage.save_shop_logo(payload, storage)
    assert not logo_storage.has_custom_logo(storage)


def test_unparseable_svg_is_refused(storage):
    with pytest.raises(logo_storage.InvalidLogoError):
        logo_storage.save_shop_logo(b"<svg not really markup", storage)


def test_non_image_is_refused(storage):
    with pytest.raises(logo_storage.InvalidLogoError):
        logo_storage.save_shop_logo(b"\x00\x01\x02 not an image", storage)


@pytest.mark.parametrize(
    "name, payload",
    [
        (
            # No quotes around the handler value: valid markup, and the old
            # pattern required a quote so this walked straight past it.
            "unquoted_event_handler",
            b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" '
            b"onload=alert(1)><rect width=\"5\" height=\"5\"/></svg>",
        ),
        (
            "javascript_href",
            b'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
            b'width="10" height="10"><a xlink:href="javascript:alert(1)">'
            b'<rect width="5" height="5"/></a></svg>',
        ),
        (
            "data_href",
            b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
            b'<image href="data:text/html,<script>alert(1)</script>"/></svg>',
        ),
    ],
)
def test_hostile_svg_variants_are_refused(storage, name, payload):
    with pytest.raises(logo_storage.InvalidLogoError):
        logo_storage.save_shop_logo(payload, storage)


def test_a_png_that_mentions_svg_in_its_metadata_is_still_a_png(storage):
    # looks_like_svg used to accept "<svg" anywhere in the first 2 KB, which
    # sent a perfectly good raster down the SVG path to be rejected.
    from PIL import PngImagePlugin

    image = Image.new("RGB", (10, 10), "white")
    meta = PngImagePlugin.PngInfo()
    meta.add_text("Comment", "exported from <svg> source")
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", pnginfo=meta)
    data = buffer.getvalue()
    assert b"<svg" in data[:2048]

    assert not logo_storage.looks_like_svg(data)
    logo_storage.save_shop_logo(data, storage)
    assert logo_storage.get_active_logo_path(storage).endswith(".png")

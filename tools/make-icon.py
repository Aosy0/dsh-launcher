#!/usr/bin/env python3
"""Generate src/DshLauncher/app.ico from the launcher's visual language.

Graphite rounded square with the DSH wordmark. The earlier `>_` prompt glyph read as a
terminal emulator, so the icon is now a plain letter mark.
Requires Pillow (`python -m pip install pillow`).

usage: python tools/make-icon.py
"""

from __future__ import annotations

import io
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT_FILE = ROOT / "src" / "DshLauncher" / "app.ico"
PREVIEW_FILE = Path(__file__).resolve().parent / "icon-preview.png"
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]

SUPERSAMPLE = 8
WORDMARK = "DSH"
FONT_CANDIDATES = [
    "C:/Windows/Fonts/segoeuib.ttf",   # Segoe UI Bold
    "C:/Windows/Fonts/seguisb.ttf",   # Segoe UI Semibold
    "C:/Windows/Fonts/arialbd.ttf",
]


def _font(px: int) -> ImageFont.FreeTypeFont:
    for candidate in FONT_CANDIDATES:
        if Path(candidate).is_file():
            return ImageFont.truetype(candidate, px)
    return ImageFont.load_default(px)


def render(size: int) -> Image.Image:
    """Draw the icon at `size` px. Everything is drawn on a supersampled canvas."""
    ss = size * SUPERSAMPLE
    image = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    pad = max(1.0, ss * 0.055)
    draw.rounded_rectangle(
        [pad, pad, ss - pad, ss - pad],
        radius=ss * 0.22,
        fill=(0x1E, 0x1E, 0x21, 0xFF),
        outline=(0x46, 0x46, 0x4A, 0xFF),
        width=max(1, round(ss * 0.014)),
    )

    ink = (0xED, 0xED, 0xED, 0xFF)
    font = _font(max(8, round(ss * 0.40)))
    box = draw.textbbox((0, 0), WORDMARK, font=font)
    width, height = box[2] - box[0], box[3] - box[1]
    target_width = ss * 0.64
    if width > target_width:
        font = _font(max(8, round(font.size * target_width / width)))
        box = draw.textbbox((0, 0), WORDMARK, font=font)
        width, height = box[2] - box[0], box[3] - box[1]
    draw.text(((ss - width) / 2 - box[0], (ss - height) / 2 - box[1]), WORDMARK, font=font, fill=ink)

    return image.resize((size, size), Image.LANCZOS)


def bmp_bytes(image: Image.Image) -> bytes:
    """32bpp DIB (BITMAPINFOHEADER + BGRA rows + 1bpp AND mask) for an .ico entry."""
    image = image.convert("RGBA")
    width, height = image.size
    mask_stride = ((width + 31) // 32) * 4

    xor = bytearray()
    for y in range(height - 1, -1, -1):
        for x in range(width):
            r, g, b, a = image.getpixel((x, y))
            xor += bytes((b, g, r, a))

    mask = bytes(mask_stride * height)
    header = struct.pack(
        "<IiiHHIIiiII", 40, width, height * 2, 1, 32, 0, len(xor) + len(mask), 0, 0, 0, 0
    )
    return header + bytes(xor) + mask


def write_ico(path: Path, frames: list[tuple[int, Image.Image]]) -> None:
    """Write a multi-size .ico. BMP entries only: System.Drawing.Icon cannot read PNG entries."""
    entries = [(size, bmp_bytes(image)) for size, image in frames]

    out = bytearray(struct.pack("<HHH", 0, 1, len(entries)))
    offset = 6 + 16 * len(entries)
    for size, data in entries:
        dimension = 0 if size >= 256 else size
        out += struct.pack(
            "<BBBBHHII", dimension, dimension, 0, 0, 1, 32, len(data), offset
        )
        offset += len(data)
    for _, data in entries:
        out += data
    path.write_bytes(bytes(out))


def main() -> int:
    try:
        import PIL  # noqa: F401
    except ImportError:
        print("Pillow is required: python -m pip install pillow", file=sys.stderr)
        return 1

    frames = [(size, render(size)) for size in SIZES]
    write_ico(OUT_FILE, frames)
    frames[-1][1].save(PREVIEW_FILE, format="PNG")
    print(f"wrote {OUT_FILE} ({OUT_FILE.stat().st_size} bytes, {len(SIZES)} sizes)")
    print(f"preview {PREVIEW_FILE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

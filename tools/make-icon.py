#!/usr/bin/env python3
"""Generate src/DshLauncher/app.ico from the launcher's visual language.

Graphite rounded square, a `>_` prompt glyph, and the running-state dot.
Requires Pillow (`python -m pip install pillow`).

usage: python tools/make-icon.py
"""

from __future__ import annotations

import io
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT_FILE = ROOT / "src" / "DshLauncher" / "app.ico"
PREVIEW_FILE = Path(__file__).resolve().parent / "icon-preview.png"
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]

SUPERSAMPLE = 8


def render(size: int) -> Image.Image:
    """Draw the icon at `size` px. Everything is drawn on a supersampled canvas."""
    ss = size * SUPERSAMPLE
    image = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    def u(value: float) -> float:
        return value * ss

    pad = max(1.0, ss * 0.055)
    radius = ss * 0.22
    draw.rounded_rectangle(
        [pad, pad, ss - pad, ss - pad],
        radius=radius,
        fill=(0x1E, 0x1E, 0x21, 0xFF),
        outline=(0x46, 0x46, 0x4A, 0xFF),
        width=max(1, round(ss * 0.014)),
    )

    stroke = max(1.0, ss * 0.095)
    prompt = (0xED, 0xED, 0xED, 0xFF)

    def line(points: list[tuple[float, float]]) -> None:
        draw.line(points, fill=prompt, width=max(1, round(stroke)), joint="curve")
        cap = stroke / 2
        for x, y in points:
            draw.ellipse([x - cap, y - cap, x + cap, y + cap], fill=prompt)

    line([(u(0.255), u(0.335)), (u(0.395), u(0.500)), (u(0.255), u(0.665))])
    line([(u(0.515), u(0.672)), (u(0.715), u(0.672))])

    dot = max(1.0, ss * 0.072)
    draw.ellipse(
        [u(0.795) - dot, u(0.245) - dot, u(0.795) + dot, u(0.245) + dot],
        fill=(0x4C, 0xC3, 0x8A, 0xFF),
    )

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

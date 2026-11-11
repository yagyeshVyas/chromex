#!/usr/bin/env python3
"""Generate the CHROMEX app icon deterministically.

Black-graphite field, an electric-blue to violet diamond ring, and a solid core.
Run:  python tools/make_icon.py
"""
from __future__ import annotations

import math
import pathlib

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUT = pathlib.Path(__file__).resolve().parent.parent / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))  # type: ignore[return-value]


def build() -> Image.Image:
    base = Image.new("RGB", (SIZE, SIZE), (5, 7, 11))
    draw = ImageDraw.Draw(base)

    # Vertical graphite gradient.
    top, bottom = (6, 9, 15), (18, 22, 33)
    for y in range(SIZE):
        draw.line([(0, y), (SIZE, y)], fill=lerp(top, bottom, y / SIZE))

    # Radial electric-blue glow behind the mark.
    glow = Image.new("RGB", (SIZE, SIZE), (0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    for r in range(560, 0, -8):
        t = 1.0 - r / 560
        alpha = int(46 * t * t)
        gdraw.ellipse(
            [SIZE // 2 - r, SIZE // 2 - r, SIZE // 2 + r, SIZE // 2 + r],
            fill=(int(46 * t), int(107 * t), int(255 * t)),
        )
    glow = glow.filter(ImageFilter.GaussianBlur(90))
    base = Image.blend(base, Image.blend(base, glow, 0.0), 0.0)
    base = Image.composite(Image.blend(base, glow, 0.55), base, Image.new("L", (SIZE, SIZE), 255))

    # Diamond ring: four edges, each coloured along a blue -> violet arc.
    cx = cy = SIZE / 2
    rad = 300
    points = [
        (cx, cy - rad),
        (cx + rad, cy),
        (cx, cy + rad),
        (cx - rad, cy),
    ]
    blue = (46, 107, 255)
    violet = (139, 92, 246)
    ring = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rdraw = ImageDraw.Draw(ring)
    width = 46
    for edge in range(4):
        x1, y1 = points[edge]
        x2, y2 = points[(edge + 1) % 4]
        steps = 220
        for s in range(steps):
            t0, t1 = s / steps, (s + 1) / steps
            # Colour cycles around the diamond: blue at top, violet at bottom.
            phase = (edge + t0) / 4.0
            colour = lerp(blue, violet, 0.5 - 0.5 * math.cos(phase * 2 * math.pi))
            rdraw.line(
                [x1 + (x2 - x1) * t0, y1 + (y2 - y1) * t0, x1 + (x2 - x1) * t1, y1 + (y2 - y1) * t1],
                fill=(*colour, 255),
                width=width,
            )
    # Soft outer bloom of the ring itself.
    bloom = ring.filter(ImageFilter.GaussianBlur(26))
    base = Image.alpha_composite(base.convert("RGBA"), bloom)
    base = Image.alpha_composite(base, ring)

    # Solid core diamond with a cool white highlight.
    core = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    cdraw = ImageDraw.Draw(core)
    inner = 132
    cdraw.polygon(
        [(cx, cy - inner), (cx + inner, cy), (cx, cy + inner), (cx - inner, cy)],
        fill=(77, 139, 255, 255),
    )
    cdraw.polygon(
        [(cx, cy - inner + 26), (cx + inner - 40, cy - 6), (cx, cy + 6), (cx - inner + 40, cy - 6)],
        fill=(226, 236, 255, 70),
    )
    core_bloom = core.filter(ImageFilter.GaussianBlur(34))
    base = Image.alpha_composite(base, core_bloom)
    base = Image.alpha_composite(base, core)

    return base.convert("RGB")


def main() -> None:
    icon = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUT, format="PNG", optimize=True)
    print(f"wrote {OUT} ({icon.size[0]}x{icon.size[1]})")


if __name__ == "__main__":
    main()

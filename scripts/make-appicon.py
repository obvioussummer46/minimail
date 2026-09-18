#!/usr/bin/env python3
"""Render the app icon from the three-dot mark.

Two outputs share the geometry below: AppIcon.png, the flat 1024 px rendering in
the asset catalog, and the vector layers of minimail.icon, the Icon Composer
bundle the build uses. The layers have the glass effect off, so iOS 26 draws the
dots round instead of lighting a flat bitmap. actool renders the iOS 17 and 18
bitmaps from the bundle as well; AppIcon.png is compiled in only if
ASSETCATALOG_COMPILER_APPICON_NAME in project.yml points back at AppIcon.

The mark is minimail's wordmark reduced to its three tittles. minimal carries
two; minimail carries three, and the one the name gained takes the accent --
the same colour ThreadRowView paints an unread thread's dot.

The dots sit over letters 2, 4 and 7 of the wordmark, so the gaps run
short-then-long. Geometry below keeps that 2:3 ratio; spacing them evenly is
what would turn the mark into a loading indicator.

Authored on a 240-unit grid (the canvas in docs/logo) and scaled to 1024. The
PNG is opaque and square with no corner rounding: iOS applies the mask itself.

Usage: python3 scripts/make-appicon.py [out.png [layer-dir]]
"""

import struct
import sys
import zlib

SIZE = 1024
GRID = 240.0
SCALE = SIZE / GRID

FIELD = (0xFF, 0xFF, 0xFF)
DOT_IDLE = (0xC7, 0xC7, 0xCC)  # systemGray4
DOT_ACCENT = (0x00, 0x7A, 0xFF)  # AccentColor.colorset, light

# (centre x, centre y, radius) on the 240 grid; gaps of 52 and 78 -> 2:3.
DOTS = [
    ((55.0, 120.0, 21.0), DOT_IDLE),
    ((107.0, 120.0, 21.0), DOT_IDLE),
    ((185.0, 120.0, 21.0), DOT_ACCENT),
]


def render():
    """One bytearray of RGB rows, flat field with analytically anti-aliased dots."""
    rows = [bytearray(FIELD * SIZE) for _ in range(SIZE)]

    for (gx, gy, gr), colour in DOTS:
        cx, cy, r = gx * SCALE, gy * SCALE, gr * SCALE
        cr, cg, cb = colour
        # Only the disc's bounding box can differ from the field.
        y0, y1 = max(0, int(cy - r - 2)), min(SIZE, int(cy + r + 2) + 1)
        x0, x1 = max(0, int(cx - r - 2)), min(SIZE, int(cx + r + 2) + 1)
        for y in range(y0, y1):
            row = rows[y]
            dy2 = (y + 0.5 - cy) ** 2
            for x in range(x0, x1):
                dx = x + 0.5 - cx
                dist = (dx * dx + dy2) ** 0.5
                # A one-pixel-wide ramp across the edge; 0 outside, 1 inside.
                cover = r - dist + 0.5
                if cover <= 0.0:
                    continue
                i = x * 3
                if cover >= 1.0:
                    row[i], row[i + 1], row[i + 2] = cr, cg, cb
                else:
                    inv = 1.0 - cover
                    row[i] = int(cr * cover + row[i] * inv + 0.5)
                    row[i + 1] = int(cg * cover + row[i + 1] * inv + 0.5)
                    row[i + 2] = int(cb * cover + row[i + 2] * inv + 0.5)
    return rows


def chunk(tag, payload):
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def write_png(path, rows):
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter type 0 (None); the image is near-flat, so it packs anyway
        raw += row
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8-bit RGB, non-interlaced
    with open(path, "wb") as handle:
        handle.write(
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b"")
        )


def write_svg(path, dots):
    """Some of the dots on a transparent canvas; minimail.icon's fill supplies the field."""
    circles = "".join(
        '  <circle cx="{:g}" cy="{:g}" r="{:g}" fill="#{:02X}{:02X}{:02X}"/>\n'.format(
            gx * SCALE, gy * SCALE, gr * SCALE, *colour
        )
        for (gx, gy, gr), colour in dots
    )
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}"'
            f' viewBox="0 0 {SIZE} {SIZE}">\n{circles}</svg>\n'
        )


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else (
        "minimail/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    )
    layers = sys.argv[2] if len(sys.argv) > 2 else "minimail/Resources/minimail.icon/Assets"
    write_png(out, render())
    print(f"wrote {out} ({SIZE}x{SIZE})")
    # The accent dot is its own layer so icon.json can give it the dark accent.
    for name, colour in (("dots-idle.svg", DOT_IDLE), ("dot-accent.svg", DOT_ACCENT)):
        write_svg(f"{layers}/{name}", [dot for dot in DOTS if dot[1] == colour])
        print(f"wrote {layers}/{name}")

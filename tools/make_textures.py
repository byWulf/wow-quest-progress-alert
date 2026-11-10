"""Renders the addon's textures (Media/*.tga) with plain Python, no dependencies.

Every texture is white with an alpha shape (except where noted) so the addon can tint it
with SetVertexColor. Shapes are anti-aliased with 4x4 supersampling.

Run from the repository root:  python -I tools/make_textures.py
"""

import math
import os
import struct

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Media")
SS = 4  # supersampling per axis


def write_tga(name, width, height, pixels):
    """pixels: list of rows (top to bottom), each a list of (r, g, b, a) floats 0..1."""
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 0x28)
    data = bytearray()
    for row in pixels:
        for r, g, b, a in row:
            data += bytes((
                round(max(0.0, min(1.0, b)) * 255),
                round(max(0.0, min(1.0, g)) * 255),
                round(max(0.0, min(1.0, r)) * 255),
                round(max(0.0, min(1.0, a)) * 255),
            ))
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name + ".tga"), "wb") as f:
        f.write(header + bytes(data))
    if PREVIEW_DIR:
        write_png(os.path.join(PREVIEW_DIR, name + ".png"), width, height, pixels)


# Optional PNG copies for looking at the textures outside the game (set QPA_PREVIEW_DIR).
PREVIEW_DIR = os.environ.get("QPA_PREVIEW_DIR")


def write_png(path, width, height, pixels):
    import zlib

    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for r, g, b, a in row:
            raw += bytes(round(max(0.0, min(1.0, v)) * 255) for v in (r, g, b, a))

    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def render(name, width, height, alpha_fn, color_fn=None, supersample=True):
    """alpha_fn(x, y) -> 0..1 at pixel coordinates (float, origin top-left)."""
    rows = []
    for py in range(height):
        row = []
        for px in range(width):
            if supersample:
                total = 0.0
                for sy in range(SS):
                    for sx in range(SS):
                        total += alpha_fn(px + (sx + 0.5) / SS, py + (sy + 0.5) / SS)
                a = total / (SS * SS)
            else:
                a = alpha_fn(px + 0.5, py + 0.5)
            r, g, b = color_fn(px + 0.5, py + 0.5) if color_fn else (1.0, 1.0, 1.0)
            row.append((r, g, b, a))
        rows.append(row)
    write_tga(name, width, height, rows)


def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def rounded_rect_sdf(x, y, cx, cy, hw, hh, r):
    qx = abs(x - cx) - hw + r
    qy = abs(y - cy) - hh + r
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - r


# Card: 256x128 canvas, the card shape sits inside a 24 px padding (room for the outer glow).
CARD_W, CARD_H, PAD, RADIUS = 256, 128, 24, 20


def card_sdf(x, y):
    return rounded_rect_sdf(x, y, CARD_W / 2, CARD_H / 2, CARD_W / 2 - PAD, CARD_H / 2 - PAD, RADIUS)


def card_body(x, y):
    return 1.0 if card_sdf(x, y) <= 0 else 0.0


def card_body_color(x, y):
    # Slightly lighter at the top, multiplied with the background color in game.
    t = (y - PAD) / (CARD_H - 2 * PAD)
    v = 1.0 - 0.45 * max(0.0, min(1.0, t))
    return v, v, v


def card_border(x, y):
    d = card_sdf(x, y)
    line = 1.0 if -2.6 <= d <= 0 else 0.0
    inner = 0.0
    if d < 0:
        inner = 0.22 * math.exp(d / 7.0)
    return min(1.0, line + inner)


def card_glow(x, y):
    d = card_sdf(x, y)
    if d <= -1:
        return 0.0
    return math.exp(-max(d, 0.0) / 7.5) * smoothstep(-1, 1.5, d) * 0.95


def card_gloss(x, y):
    d = card_sdf(x, y)
    if d > -1.5:
        return 0.0
    t = (y - PAD) / (CARD_H - 2 * PAD)
    return 0.55 * (1 - smoothstep(0.0, 0.5, t))


# Bar: 128x16 capsule.
def bar_sdf(x, y):
    return rounded_rect_sdf(x, y, 64, 8, 63, 7, 7)


def bar_shape(x, y):
    return 1.0 if bar_sdf(x, y) <= 0 else 0.0


def bar_fill_color(x, y):
    # Bright band at the top, darker bottom: a glossy look once tinted.
    t = (y - 1) / 14
    v = 1.0 if t < 0.35 else 0.78 - 0.18 * (t - 0.35) / 0.65
    if t < 0.35:
        v = 1.0 - 0.12 * t / 0.35
    return v, v, v


def spark(x, y):
    dx = (x - 16) / 4.0
    dy = abs(y - 32) / 32.0
    return math.exp(-dx * dx) * max(0.0, 1 - dy) ** 1.6


def shine(x, y):
    u = (x - 64) + (y - 32) * 0.55
    return math.exp(-(u / 11.0) ** 2) * 0.9


def glow(x, y):
    r = math.hypot(x - 64, y - 64) / 64
    return max(0.0, 1 - r) ** 2.2


def ring(x, y):
    r = math.hypot(x - 64, y - 64)
    return math.exp(-((r - 54) / 4.5) ** 2)


def star(x, y):
    dx, dy = x - 32, y - 32
    r = math.hypot(dx, dy) / 32
    falloff = max(0.0, 1 - r)
    rays = math.exp(-(dx / 2.2) ** 2) + math.exp(-(dy / 2.2) ** 2)
    core = math.exp(-(r / 0.16) ** 2)
    return min(1.0, rays * falloff ** 1.3 + core)


def seg_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)))
    return math.hypot(px - (ax + vx * t), py - (ay + vy * t))


def check(x, y):
    d = min(seg_dist(x, y, 13, 33, 26, 46), seg_dist(x, y, 26, 46, 51, 18))
    return 1.0 if d <= 5.0 else 0.0


def cross(x, y):
    d = min(seg_dist(x, y, 16, 16, 48, 48), seg_dist(x, y, 48, 16, 16, 48))
    return 1.0 if d <= 5.0 else 0.0


def icon_sdf(x, y):
    return rounded_rect_sdf(x, y, 32, 32, 31, 31, 11)


def icon_mask(x, y):
    return 1.0 if icon_sdf(x, y) <= -1 else 0.0


def icon_border(x, y):
    d = icon_sdf(x, y)
    line = 1.0 if -3.2 <= d <= 0 else 0.0
    inner = 0.35 * math.exp(d / 4.0) if d < -3.2 else 0.0
    return min(1.0, line + inner)


def main():
    render("CardBody", CARD_W, CARD_H, card_body, card_body_color)
    render("CardBorder", CARD_W, CARD_H, card_border)
    render("CardGlow", CARD_W, CARD_H, card_glow)
    render("CardGloss", CARD_W, CARD_H, card_gloss)
    render("Bar", 128, 16, bar_shape, bar_fill_color)
    render("BarTrack", 128, 16, bar_shape)
    render("Spark", 32, 64, spark, supersample=False)
    render("Shine", 128, 64, shine, supersample=False)
    render("Glow", 128, 128, glow, supersample=False)
    render("Ring", 128, 128, ring, supersample=False)
    render("Star", 64, 64, star)
    render("Check", 64, 64, check)
    render("Cross", 64, 64, cross)
    render("IconMask", 64, 64, icon_mask)
    render("IconBorder", 64, 64, icon_border)


if __name__ == "__main__":
    main()

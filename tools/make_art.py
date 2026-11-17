#!/usr/bin/env python3
"""Draw Chakra's golden sun wheel: the picture on the ball and the Settings icon.

An original drawing made from arithmetic alone. Nothing is traced or sampled from a photograph:
the piece is described as a relief (how far each point stands up from the ground), and the
relief is lit the way polished gold is: a bright sky up and to the left, a dark floor, a
warm bounce from below.

The wheel: twenty-four rays (the spokes of a chakra), long and short in turn, each a ridged
blade on a bead; in the middle a disc with two rings of lotus petals round a polished boss.

Two cuts of the same wheel, the way a typeface has sizes:
  fine   every detail: beads along the blades, a stippled ground. For the big picture.
  bold   thicker blades, a plainer disc. For the ball (a few dozen points across) and the icon.

Writes
  <master dir>/chakra-sun-4096.png                    the fine cut, 4096 x 4096, clear ground
  art/chakra-sun.png                                  the same at 1024, on black (for the README)
  ChakraArt.m                                         the bold cut at 256 px, inside the tweak
  layout/Library/PreferenceLoader/Preferences/Chakra{,@2x,@3x}.png    the Settings icon

Usage:  python3 tools/make_art.py --master DIR       everything (about a minute)
        python3 tools/make_art.py --look DIR         quick pictures to look at, nothing else
Needs numpy and Pillow.
"""

import argparse
import base64
import io
import math
import os

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---- the two cuts. Lengths are fractions of the half-width of the picture. -------------------
FINE = dict(
    rays=24, tip_long=0.960, tip_short=0.865,
    neck=0.528, neck_w=0.012, shoulder=0.612, ray_w=0.040,
    ray_border=0.0075, ray_groove=0.0065, ray_groove_depth=0.0032, ray_slope=1.0, ray_roof=0.85,
    ray_dots=[(0.616, 0.0115), (0.645, 0.0095), (0.669, 0.0078), (0.690, 0.0062)],
    bead_r=0.500, bead=0.0305, bead_h=0.9,
    disc=0.425, rim=0.020, rim_h=1.1, dome=0.012,
    rings=[(0.355, 0.0050), (0.2005, 0.0062), (0.096, 0.0058)],          # (radius, half-width)
    granules=[(64, 0.3725, 0.0085, 0.0)],                                 # (how many, radius, size, turn)
    # (how many, turn in steps, from, to, half-width, height, edge, vein)
    petals=[(16, 0.5, 0.232, 0.350, 0.026, 0.0060, 0.012, 0.0),
            (16, 0.0, 0.212, 0.346, 0.034, 0.0105, 0.014, 0.0030),
            (8, 0.0, 0.118, 0.193, 0.022, 0.0055, 0.011, 0.0),
            (8, 0.5, 0.104, 0.190, 0.030, 0.0100, 0.013, 0.0028)],
    boss=0.082, boss_h=0.75,
    stipple=0.0016, ao=0.45, ao_radius=0.012, ao_depth=0.012,
)

BOLD = dict(
    FINE,
    tip_short=0.875, neck_w=0.016, ray_w=0.052,
    ray_border=0.0, ray_groove=0.0, ray_groove_depth=0.0, ray_roof=0.9, ray_dots=[],
    bead=0.036,
    rim=0.026, rings=[(0.118, 0.0075)], granules=[],
    petals=[(12, 0.5, 0.150, 0.368, 0.036, 0.0080, 0.016, 0.0),
            (12, 0.0, 0.128, 0.362, 0.050, 0.0140, 0.020, 0.0040)],
    boss=0.104, stipple=0.0, ao_radius=0.018,
)

# ---- light -----------------------------------------------------------------------------------


def _unit(x, y, z):
    n = math.sqrt(x * x + y * y + z * z)
    return (x / n, y / n, z / n)


KEY = _unit(-0.50, -0.62, 0.60)                 # the lamp: up and to the left (y runs down the picture)
HALF = _unit(KEY[0], KEY[1], KEY[2] + 1.0)      # halfway between the lamp and the eye
SKY = _unit(-0.45, -0.75, 0.45)                 # where the reflected room is bright
FLOOR = _unit(0.60, 0.70, 0.30)                 # a warm bounce on the far side

# brightness -> gold. Deep brown in the hollows, yellow metal in the middle, near white on a glint.
RAMP_AT = [0.00, 0.25, 0.50, 0.75, 1.00, 1.30, 1.70]
RAMP = [(0.085, 0.040, 0.006), (0.340, 0.185, 0.028), (0.700, 0.455, 0.085), (0.930, 0.715, 0.215),
        (1.000, 0.875, 0.470), (1.000, 0.965, 0.780), (1.000, 1.000, 0.960)]


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def fold(theta, n, offset):
    """The angle measured from the nearest of n evenly spaced spokes, and which spoke that is."""
    step = 2.0 * math.pi / n
    k = np.round((theta - offset) / step)
    return theta - offset - k * step, k


def cap(radius, rho2):
    """Height of a half-round of this radius, at squared distance rho2 from its middle."""
    return np.sqrt(np.maximum(radius * radius - rho2, 0.0))


def relief(x, y, P, noise=None):
    """-> (height, signed distance to the outline: positive inside the gold)."""
    r = np.hypot(x, y)
    th = np.arctan2(y, x)
    up = -math.pi / 2.0

    # --- rays: a blade is a long kite (neck, shoulder, tip) with a ridge down its middle
    t, k = fold(th, P["rays"], up)
    u = r * np.cos(t)                    # along the blade
    a = np.abs(r * np.sin(t))            # across it
    tip = np.where(np.mod(k, 2) == 0, P["tip_long"], P["tip_short"]).astype(np.float32)
    u0, wn, u1, wm = P["neck"], P["neck_w"], P["shoulder"], P["ray_w"]
    b, g = P["ray_border"], P["ray_groove"]

    def inside(uu, aa):                  # distance in from the nearest edge of the kite
        du, dw = u1 - u0, wm - wn
        e1 = -(du * (aa - wn) - dw * (uu - u0)) / math.hypot(du, dw)
        eu = tip - u1
        e2 = -(eu * (aa - wm) + wm * (uu - u1)) / np.sqrt(eu * eu + wm * wm)
        return np.minimum(np.minimum(e1, e2), uu - u0)

    def roof(d):                         # a bevelled rim, then the roof rising to the ridge
        return P["ray_slope"] * np.minimum(d, b) + P["ray_roof"] * np.maximum(d - b - g, 0.0)

    d_ray = inside(u, a)
    h_ray = roof(d_ray)
    if g > 0:
        h_ray = h_ray - P["ray_groove_depth"] * np.exp(-((d_ray - b - 0.5 * g) / (0.4 * g)) ** 2)
    for uc, rad in P["ray_dots"]:        # beads along the ridge, smaller toward the tip
        rho2 = (u - uc) ** 2 + a * a
        seat = roof(inside(uc, 0.0)) - 0.35 * rad
        h_ray = np.where(rho2 < rad * rad, np.maximum(h_ray, seat + cap(rad, rho2)), h_ray)
    h_ray = np.where(d_ray > 0, h_ray, 0.0)

    # --- the bead each blade stands on
    rho2 = (u - P["bead_r"]) ** 2 + a * a
    h_bead = P["bead_h"] * cap(P["bead"], rho2)
    d_bead = P["bead"] - np.sqrt(rho2)

    # --- the disc: a rim, rings, a ring of granules, lotus petals, the boss
    Rd = P["disc"]
    d_disc = Rd - r
    raised = P["rim_h"] * cap(P["rim"], (r - (Rd - P["rim"])) ** 2)
    for rc, rt in P["rings"]:
        raised = np.maximum(raised, cap(rt, (r - rc) ** 2))
    for n, rc, rad, turn in P["granules"]:
        tt, _ = fold(th, n, up + turn * 2.0 * math.pi / n)
        raised = np.maximum(raised, 0.9 * cap(rad, (r * np.cos(tt) - rc) ** 2 + (r * np.sin(tt)) ** 2))
    for n, turn, ua, ub, hw, hp, edge, vein in P["petals"]:
        tt, _ = fold(th, n, up + turn * 2.0 * math.pi / n)
        uu = r * np.cos(tt)
        aa = np.abs(r * np.sin(tt))
        half = (ub - ua) / 2.0
        mid = (ua + ub) / 2.0
        big = (half * half + hw * hw) / (2.0 * hw)      # a petal is where two big circles overlap
        d = big - np.sqrt((uu - mid) ** 2 + (aa + big - hw) ** 2)
        h = hp * (1.0 - (1.0 - np.clip(d / edge, 0.0, 1.0)) ** 2)
        if vein > 0:
            along = smoothstep(ua + 0.25 * half, ua + 0.6 * half, uu) * smoothstep(ub - 0.1 * half, ub - 0.5 * half, uu)
            h = h - vein * np.exp(-(aa / (0.12 * hw)) ** 2) * along
        raised = np.maximum(raised, np.where(d > 0, h, 0.0))
    raised = np.maximum(raised, P["boss_h"] * cap(P["boss"], r * r))

    h_disc = P["dome"] * (1.0 - np.minimum(r / Rd, 1.0) ** 2) + raised
    if noise is not None and P["stipple"] > 0:           # the ground between the petals is punched matt
        ground = (1.0 - smoothstep(0.0, 0.0015, raised)) * smoothstep(0.0, 0.01, d_disc)
        h_disc = h_disc + P["stipple"] * noise * ground

    height = np.where(d_disc > 0, h_disc, np.maximum(h_ray, h_bead))
    outline = np.maximum(np.maximum(d_disc, d_bead), d_ray)
    return height.astype(np.float32), outline.astype(np.float32)


def shade(height, pix, ao):
    gy, gx = np.gradient(height, pix)
    nz = 1.0 / np.sqrt(gx * gx + gy * gy + 1.0)
    nx, ny = -gx * nz, -gy * nz
    lit = np.maximum(nx * KEY[0] + ny * KEY[1] + nz * KEY[2], 0.0)
    glint = np.maximum(nx * HALF[0] + ny * HALF[1] + nz * HALF[2], 0.0)
    rx, ry, rz = 2.0 * nz * nx, 2.0 * nz * ny, 2.0 * nz * nz - 1.0       # the eye's ray, mirrored
    sky = smoothstep(0.15, 0.80, rx * SKY[0] + ry * SKY[1] + rz * SKY[2])
    floor = smoothstep(0.55, 0.95, rx * FLOOR[0] + ry * FLOOR[1] + rz * FLOOR[2])
    b = (0.08 + 0.62 * sky + 0.22 * lit + 1.0 * glint ** 50 + 0.22 * glint ** 5 + 0.20 * floor) * ao
    return np.stack([np.interp(b, RAMP_AT, [c[i] for c in RAMP]) for i in range(3)], axis=-1)


def gauss(a, sigma):
    fy = np.fft.fftfreq(a.shape[0])[:, None]
    fx = np.fft.rfftfreq(a.shape[1])[None, :]
    return np.fft.irfft2(np.fft.rfft2(a) * np.exp(-2.0 * (math.pi * sigma) ** 2 * (fx * fx + fy * fy)), s=a.shape).astype(np.float32)


def render(size, P, seed=7):
    """-> size x size x 4 bytes, straight alpha, clear ground."""
    pix = 2.0 / size
    at = (np.arange(size, dtype=np.float32) + 0.5) * pix - 1.0

    # hollows are darker: compare the relief with a blurred copy of itself (on a coarse grid)
    coarse = min(size, 1024)
    ca = (np.arange(coarse, dtype=np.float32) + 0.5) * (2.0 / coarse) - 1.0
    hc, _ = relief(ca[None, :], ca[:, None], P)
    hollow = (gauss(hc, P["ao_radius"] * coarse / 2.0) - hc) / P["ao_depth"]
    ao = (1.0 - P["ao"] * np.clip(hollow, 0.0, 1.0) + 0.05 * np.clip(-hollow, 0.0, 1.0)).astype(np.float32)
    if coarse != size:
        ao = np.asarray(Image.fromarray(ao).resize((size, size), Image.Resampling.BILINEAR))

    noise = None
    if P["stipple"] > 0 and size >= 1024:
        grain = np.random.default_rng(seed).random((500, 500), dtype=np.float32) - 0.5
        noise = np.asarray(Image.fromarray(grain).resize((size, size), Image.Resampling.BICUBIC))

    out = np.zeros((size, size, 4), np.uint8)
    dither = np.random.default_rng(seed + 1)
    rows = 256
    for j0 in range(0, size, rows):
        j1 = min(size, j0 + rows)
        a0, a1 = max(0, j0 - 1), min(size, j1 + 1)       # one row more each side, for the slopes
        height, outline = relief(at[None, :], at[a0:a1, None], P, None if noise is None else noise[a0:a1])
        rgb = shade(height, pix, ao[a0:a1])
        keep = slice(j0 - a0, j0 - a0 + (j1 - j0))
        rgb = rgb[keep] * 255.0 + dither.random((j1 - j0, size, 1), dtype=np.float32) - 0.5
        out[j0:j1, :, :3] = np.clip(rgb + 0.5, 0, 255).astype(np.uint8)
        out[j0:j1, :, 3] = (np.clip(0.5 + outline[keep] / pix, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    return out


# ---- files -----------------------------------------------------------------------------------

def on_black(img, ground=(0, 0, 0, 255)):
    back = Image.new("RGBA", img.size, ground)
    back.alpha_composite(img)
    return back


def png_bytes(img):
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def settings_icon(sun, px):
    """Black rounded square with the wheel on it, the size Settings wants (29 points)."""
    ss = 8
    mask = Image.new("L", (px * ss, px * ss), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, px * ss - 1, px * ss - 1], radius=0.225 * px * ss, fill=255)
    mask = mask.resize((px, px), Image.Resampling.LANCZOS)
    icon = Image.new("RGBA", (px, px), (10, 8, 6, 255))
    inner = max(8, round(px * 0.94))
    small = sun.resize((inner, inner), Image.Resampling.LANCZOS)
    icon.alpha_composite(small, ((px - inner) // 2, (px - inner) // 2))
    icon.putalpha(mask)
    return icon


ART_M = '''/*  ChakraArt.m — the golden sun wheel on the ball, as a picture inside the library.

    MADE BY tools/make_art.py. Do not edit: change the drawing there and run it again.
    A %d x %d PNG, written out as base64 so that the tweak needs no file beside it.  */

#import "Chakra.h"

static NSString *const kChakraSun =
%s;

NSData *ChakraSunPNG(void) {
    static NSData *data;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        data = [[NSData alloc] initWithBase64EncodedString:kChakraSun options:NSDataBase64DecodingIgnoreUnknownCharacters];
    });
    return data;
}
'''


def write_art_m(path, png, px):
    text = base64.b64encode(png).decode("ascii")
    lines = [text[i:i + 110] for i in range(0, len(text), 110)]
    body = "\n".join('    %s"%s"' % ("@" if i == 0 else " ", s) for i, s in enumerate(lines))
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(ART_M % (px, px, body))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--master", metavar="DIR", help="write everything; the 4096 px master goes to DIR")
    ap.add_argument("--look", metavar="DIR", help="quick pictures to look at, nothing else")
    ap.add_argument("--size", type=int, default=4096, help="the master's size (default 4096)")
    args = ap.parse_args()
    if not args.master and not args.look:
        ap.error("give --master DIR or --look DIR")

    if args.look:
        os.makedirs(args.look, exist_ok=True)
        fine = Image.fromarray(render(1024, FINE))
        on_black(fine).convert("RGB").save(os.path.join(args.look, "fine-1024.png"))
        close = Image.fromarray(render(2048, FINE)).crop((700, 60, 1500, 860))      # a blade, beads, the disc's edge
        on_black(close).convert("RGB").save(os.path.join(args.look, "fine-close.png"))
        bold = Image.fromarray(render(1024, BOLD))
        on_black(bold).convert("RGB").save(os.path.join(args.look, "bold-1024.png"))
        # the ball as it will be: 46 points at 3x, black face; shown four times larger beside the real size
        ball = 138
        face = Image.new("RGBA", (ball, ball), (0, 0, 0, 0))
        ImageDraw.Draw(face).ellipse([0, 0, ball - 1, ball - 1], fill=(8, 7, 9, 255))
        inner = round(ball * 0.92)
        face.alpha_composite(bold.resize((inner, inner), Image.Resampling.LANCZOS), ((ball - inner) // 2,) * 2)
        sheet = Image.new("RGB", (ball * 4 + ball + 60, ball * 4 + 40), (54, 58, 66))
        sheet.paste(face.resize((ball * 4, ball * 4), Image.Resampling.NEAREST), (20, 20), face.resize((ball * 4, ball * 4), Image.Resampling.NEAREST))
        sheet.paste(face, (ball * 4 + 40, 20), face)
        icon = settings_icon(bold, 87)
        sheet.paste(icon, (ball * 4 + 40, ball + 50), icon)
        sheet.save(os.path.join(args.look, "ball.png"))
        print("pictures in", args.look)
        return

    os.makedirs(args.master, exist_ok=True)
    master = Image.fromarray(render(args.size, FINE))
    path = os.path.join(args.master, "chakra-sun-%d.png" % args.size)
    master.save(path, "PNG")
    print("  %-34s %9d bytes" % (os.path.basename(path), os.path.getsize(path)))

    os.makedirs(os.path.join(HERE, "art"), exist_ok=True)
    path = os.path.join(HERE, "art", "chakra-sun.png")
    on_black(master.resize((1024, 1024), Image.Resampling.LANCZOS)).convert("RGB").save(path, "PNG", optimize=True)
    print("  %-34s %9d bytes" % ("art/chakra-sun.png", os.path.getsize(path)))

    bold = Image.fromarray(render(1024, BOLD))
    png = png_bytes(bold.resize((256, 256), Image.Resampling.LANCZOS))
    write_art_m(os.path.join(HERE, "ChakraArt.m"), png, 256)
    print("  %-34s %9d bytes of PNG" % ("ChakraArt.m", len(png)))

    prefs = os.path.join(HERE, "layout", "Library", "PreferenceLoader", "Preferences")
    for scale, suffix in ((1, ""), (2, "@2x"), (3, "@3x")):
        path = os.path.join(prefs, "Chakra%s.png" % suffix)
        settings_icon(bold, 29 * scale).save(path, "PNG", optimize=True)
        print("  %-34s %9d bytes" % ("Chakra%s.png" % suffix, os.path.getsize(path)))


if __name__ == "__main__":
    main()

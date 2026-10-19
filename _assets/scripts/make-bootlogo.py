#!/usr/bin/env python3
"""Generate the CrossMix-OS SE boot logos.

The BootLogo app only lists .bmp files from Apps/BootLogo/Images_1280x720 and the
flasher (Emus/_BootLogo/launch.sh) refuses anything that is not a real BMP, is
bigger than 1280x720, or weighs more than 6 MB. Everything is drawn at 2x and
downsampled, which is the only way to get clean edges out of PIL.

Design rules learned from looking at the first pass on a real 1280x720 frame:
- no text smaller than ~18px at 1x, and no second line of small caps: on a boot
  screen it reads as texture, not as words
- the frame is a square rotated 45 degrees, not a wide lozenge, and it is thick
  enough to survive a cheap panel
- one accent, one focal point. The badge is an outline, not a solid block, so it
  stops competing with the mark

Run: python3 _assets/scripts/make-bootlogo.py
Writes: Apps/BootLogo/Images_1280x720/- CrossMix-OS SE*.bmp
        plus 1:1 PNG previews under /tmp for review.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1280, 720
SS = 2
w, h = W * SS, H * SS

RED = (225, 6, 0)
RED_HOT = (255, 59, 78)
INK = (3, 4, 7)
WHITE = (247, 248, 250)
STEEL = (150, 156, 168)

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

OUT = Path(__file__).resolve().parents[2] / "Apps" / "BootLogo" / "Images_1280x720"


def font(path, size):
    return ImageFont.truetype(path, size * SS)


def tracked(draw, xy, text, fnt, fill, tracking):
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=fnt, fill=fill)
        x += draw.textlength(ch, font=fnt) + tracking * SS
    return x


def tracked_width(draw, text, fnt, tracking):
    return sum(draw.textlength(c, font=fnt) for c in text) + tracking * SS * (len(text) - 1)


def background():
    """Near-black, one red core glow, almost no grid."""
    img = Image.new("RGB", (w, h), INK)
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for r, a in ((600 * SS, 46), (400 * SS, 70), (250 * SS, 96)):
        gd.ellipse([w // 2 - r, h // 2 - r * 0.62, w // 2 + r, h // 2 + r * 0.62],
                   fill=(a, int(a * 0.07), int(a * 0.09)))
    glow = glow.filter(ImageFilter.GaussianBlur(90 * SS))
    img = Image.blend(img, Image.blend(img, glow, 0.6), 0.6)

    # a single horizon line, faint: enough to feel engineered, not a screen saver
    line = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ld = ImageDraw.Draw(line)
    ld.line([(0, int(h * 0.5)), (w, int(h * 0.5))], fill=RED + (16,), width=SS)
    img = Image.alpha_composite(img.convert("RGBA"), line).convert("RGB")

    vig = Image.new("L", (w, h), 0)
    vd = ImageDraw.Draw(vig)
    vd.ellipse([-w * 0.3, -h * 0.4, w * 1.3, h * 1.4], fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(140 * SS))
    return Image.composite(img, Image.new("RGB", (w, h), (0, 0, 0)), vig)


def diamond(img, half=330, width=4, color=RED):
    """Square rotated 45 degrees: equal diagonals, thick enough to read."""
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = w // 2, int(h * 0.385)
    r = half * SS
    pts = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
    d.line(pts + [pts[0]], fill=color + (225,), width=width * SS, joint="curve")

    for px, py in pts:
        s = 5 * SS
        d.rectangle([px - s, py - s, px + s, py + s], fill=color + (240,))

    img = Image.alpha_composite(img.convert("RGBA"), layer)
    img = Image.alpha_composite(img, layer.filter(ImageFilter.GaussianBlur(10 * SS)))
    return img.convert("RGB")


def bez(p0, p1, p2, p3, n=64):
    """Cubic bezier sampled to points: PIL has no curves worth using."""
    out = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        x = (mt ** 3) * p0[0] + 3 * (mt ** 2) * t * p1[0] + 3 * mt * (t ** 2) * p2[0] + (t ** 3) * p3[0]
        y = (mt ** 3) * p0[1] + 3 * (mt ** 2) * t * p1[1] + 3 * mt * (t ** 2) * p2[1] + (t ** 3) * p3[1]
        out.append((x, y))
    return out


def scorpion(draw, cx, cy, s, color, width):
    """Side-view scorpion, built as a filled silhouette.

    The overhead version drawn in outline read as a knot or a hook: at logo size
    the eye needs the profile - low body, legs underneath, claw in front, tail
    arcing over the back to a barb. Filled shapes survive the downscale; 2px
    outlines do not.
    """

    def P(u, v):
        return (cx + u * s, cy + v * s)

    thick = int(0.085 * s)

    # body: arched back, flat underside
    top = bez(P(-0.26, 0.04), P(-0.10, -0.12), P(0.12, -0.12), P(0.26, 0.02))
    bottom = bez(P(0.26, 0.02), P(0.12, 0.15), P(-0.10, 0.15), P(-0.26, 0.04))
    draw.polygon(top + bottom, fill=color)

    # four leg pairs, angled back
    for ux in (-0.15, -0.03, 0.09, 0.18):
        leg = bez(P(ux, 0.12), P(ux - 0.02, 0.26), P(ux - 0.07, 0.33), P(ux - 0.12, 0.38))
        draw.line(leg, fill=color, width=thick, joint="curve")

    # front arm and pincer
    arm = bez(P(-0.24, 0.0), P(-0.38, -0.03), P(-0.48, -0.07), P(-0.55, -0.05))
    draw.line(arm, fill=color, width=int(thick * 1.15), joint="curve")
    upper = bez(P(-0.55, -0.05), P(-0.68, -0.12), P(-0.75, -0.07), P(-0.71, 0.02))
    lower = bez(P(-0.55, -0.05), P(-0.66, 0.03), P(-0.73, 0.08), P(-0.66, 0.12))
    draw.line(upper, fill=color, width=int(thick * 0.9), joint="curve")
    draw.line(lower, fill=color, width=int(thick * 0.9), joint="curve")

    # tail: out of the abdomen, up and over the back
    tail = bez(P(0.25, 0.0), P(0.50, -0.04), P(0.54, -0.34), P(0.30, -0.44))
    hook = bez(P(0.30, -0.44), P(0.16, -0.50), P(0.08, -0.36), P(0.05, -0.27))
    draw.line(tail, fill=color, width=int(thick * 1.1), joint="curve")
    draw.line(hook, fill=color, width=int(thick * 1.1), joint="curve")

    # telson and barb, pointing down-forward
    draw.polygon([P(0.07, -0.24), P(0.02, -0.31), P(-0.05, -0.23)], fill=color)


def badge(d, xy, text, fnt, fill, pad=14, track=3, outline_only=True):
    """SE tag as an outline: mass without stealing focus from the mark."""
    x, y = xy
    tw = tracked_width(d, text, fnt, track)
    bw = tw + pad * 2 * SS
    bh = (fnt.size) + pad * 2 * SS
    if outline_only:
        d.rectangle([x, y, x + bw, y + bh], outline=fill + (200,), width=2 * SS)
    else:
        d.rectangle([x, y, x + bw, y + bh], fill=fill[:3] + (235,))
    tracked(d, (x + pad * SS, y + pad * SS * 0.65), text, fnt, fill, track)
    return bw


def variant_emblem():
    """A — frame plus a clean X."""
    img = background()

    glyph = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glyph)
    cx, cy = w // 2, int(h * 0.385)
    L = 100 * SS
    # two bars, square cut: no notch, nothing that reads as a rendering bug
    gd.line([(cx - L, cy - L), (cx + L, cy + L)], fill=RED_HOT + (255,), width=30 * SS)
    gd.line([(cx + L, cy - L), (cx - L, cy + L)], fill=RED_HOT + (255,), width=30 * SS)
    img = Image.alpha_composite(img.convert("RGBA"), glyph).convert("RGB")
    img = Image.alpha_composite(img.convert("RGBA"),
                                glyph.filter(ImageFilter.GaussianBlur(14 * SS))).convert("RGB")
    img = diamond(img, half=214, width=4)

    d = ImageDraw.Draw(img)
    f_big = font(FONT_BOLD, 62)
    f_se = font(FONT_BOLD, 34)

    text = "CROSSMIX-OS"
    tw = tracked_width(d, text, f_big, 7)
    se_w = tracked_width(d, "SE", f_se, 4) + 28 * SS
    total = tw + 22 * SS + se_w
    x0 = (w - total) / 2
    y = int(h * 0.80)
    tracked(d, (x0, y), text, f_big, WHITE, 7)

    bx = x0 + tw + 22 * SS
    bw = tracked_width(d, "SE", f_se, 4) + 28 * SS
    bh = f_se.size + 16 * SS
    d.rectangle([bx, y + 6 * SS, bx + bw, y + 6 * SS + bh], outline=RED_HOT + (210,), width=2 * SS)
    tracked(d, (bx + 14 * SS, y + 13 * SS), "SE", f_se, RED_HOT, 4)
    return img


def variant_wordmark():
    """B — no frame, typography only. The quietest and the most legible."""
    img = background()
    d = ImageDraw.Draw(img)
    f_big = font(FONT_BOLD, 104)
    f_se = font(FONT_BOLD, 46)

    text = "CROSSMIX"
    tw = tracked_width(d, text, f_big, 12)
    os_w = tracked_width(d, "-OS", f_big, 12)
    se_w = tracked_width(d, "SE", f_se, 8)
    total = tw + os_w + 30 * SS + se_w
    x0 = (w - total) / 2
    y = int(h * 0.40)

    x = tracked(d, (x0, y), text, f_big, WHITE, 12)
    x = tracked(d, (x, y), "-OS", f_big, RED_HOT, 12)

    bx = x + 52 * SS
    by = y + (f_big.size - f_se.size) * 0.42
    d.line([(bx - 22 * SS, by - 10 * SS), (bx - 22 * SS, by + f_se.size + 10 * SS)],
           fill=(90, 94, 102), width=2 * SS)
    tracked(d, (bx + 10 * SS, by), "SE", f_se, WHITE, 8)

    # one rule, red core on the left
    ry = y + f_big.size + 30 * SS
    d.line([(x0, ry), (x0 + tw + os_w, ry)], fill=(64, 68, 76), width=2 * SS)
    d.line([(x0, ry), (x0 + tw * 0.42, ry)], fill=RED, width=4 * SS)
    return img


def variant_scorpion():
    """C — the scorpion is the mark. Kept because it is the identity piece."""
    img = background()

    mark = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    md = ImageDraw.Draw(mark)
    scorpion(md, int(w * 0.5) + 18 * SS, int(h * 0.375), 290 * SS, RED_HOT + (255,), 8 * SS)
    img = Image.alpha_composite(img.convert("RGBA"), mark).convert("RGB")
    img = Image.alpha_composite(img.convert("RGBA"),
                                mark.filter(ImageFilter.GaussianBlur(16 * SS))).convert("RGB")
    img = diamond(img, half=232, width=3)

    d = ImageDraw.Draw(img)
    f_big = font(FONT_BOLD, 54)
    f_se = font(FONT_BOLD, 30)

    text = "CROSSMIX-OS"
    tw = tracked_width(d, text, f_big, 8)
    se_w = tracked_width(d, "SE", f_se, 4) + 26 * SS
    total = tw + 20 * SS + se_w
    x0 = (w - total) / 2
    y = int(h * 0.80)
    tracked(d, (x0, y), text, f_big, WHITE, 8)

    bx = x0 + tw + 20 * SS
    bw = tracked_width(d, "SE", f_se, 4) + 26 * SS
    bh = f_se.size + 14 * SS
    d.rectangle([bx, y + 5 * SS, bx + bw, y + 5 * SS + bh], outline=RED_HOT + (210,), width=2 * SS)
    tracked(d, (bx + 13 * SS, y + 11 * SS), "SE", f_se, RED_HOT, 4)
    return img


def save(img, name):
    out = img.resize((W, H), Image.Resampling.LANCZOS)
    bmp = OUT / f"{name}.bmp"
    out.save(bmp, format="BMP")
    out.save("/tmp/logo_" + name.replace(" ", "_").replace("-", "").lower() + ".png")
    size = bmp.stat().st_size
    print(f"{bmp.name:<38} {out.size[0]}x{out.size[1]}  {size / 1048576:.2f} MiB")
    if size > 6 * 1024 * 1024:
        raise SystemExit(f"{bmp.name} exceeds the 6 MB limit the flasher enforces")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    save(variant_emblem(), "- CrossMix-OS SE")
    save(variant_wordmark(), "- CrossMix-OS SE Wordmark")
    save(variant_scorpion(), "- CrossMix-OS SE Scorpio")


if __name__ == "__main__":
    main()

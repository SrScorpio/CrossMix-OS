#!/usr/bin/env python3
"""Derive the CrossMix-OS SE theme from the stock one.

Why a copy and not a rename: several firmware scripts hard-code
/mnt/SDCARD/Themes/CrossMix - OS/wqy-microhei.ttf to draw the firmware-update
screens (_FirmwareCheck.sh, infoscreen2). Renaming or removing the stock theme
breaks those screens. The SE theme is an additional folder; the stock one stays
exactly where it is.

What changes: the teal accent becomes Ember Red, the background gets the SE mark
as a watermark, the nav logo and the carousel dots follow, and the shutdown
screen loses the old wordmark. Everything else is left alone - the skin is
already neutral greys, so there is nothing to recolour.

Run: python3 _assets/scripts/make-theme-se.py
"""

import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "Themes" / "CrossMix - OS"
DEST = ROOT / "Themes" / "CrossMix - OS SE"
LOGO = ROOT / "_assets" / "readme" / "logo-se.png"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

BLACK = (15, 16, 20)       # Scorpio Black
RED = (236, 39, 59)        # Ember Red
CREAM = (254, 228, 205)    # Bone Cream

# Hue wheel in PIL's 0-255 space: 180 deg = 127, 354 deg (Ember Red) = 251.
CYAN_LO, CYAN_HI, RED_HUE = 92, 155, 251


def recolor(img):
    """Shift teal/cyan pixels to Ember Red, keeping saturation and brightness."""
    rgba = np.asarray(img.convert("RGBA")).copy()
    hsv = np.asarray(img.convert("HSV")).copy()

    h = hsv[..., 0].astype(np.int16)
    s = hsv[..., 1].astype(np.int16)
    v = hsv[..., 2].astype(np.int16)

    mask = (h >= CYAN_LO) & (h <= CYAN_HI) & (s > 40) & (v > 25)
    h[mask] = RED_HUE
    s[mask] = np.clip(s[mask] * 1.15, 0, 255)

    hsv[..., 0] = h.astype(np.uint8)
    hsv[..., 1] = s.astype(np.uint8)
    out = Image.fromarray(hsv, "HSV").convert("RGB")
    out = np.dstack([np.asarray(out), rgba[..., 3]]).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def tint_mono(img, color):
    """Recolour a monochrome asset by luminance.

    Hue shifting leaves the antialiased fringe half teal and half red, which is
    exactly the halo it produces on 40px assets. Rebuilding the colour from
    luminance keeps every edge pixel consistent with its neighbours.
    """
    rgba = img.convert("RGBA")
    alpha = np.asarray(rgba.split()[3])
    lum = np.asarray(rgba.convert("L")).astype(np.float32)
    mx = float(lum.max()) or 1.0
    lum = (lum / mx) ** 0.9

    out = np.zeros((*lum.shape, 3), dtype=np.uint8)
    for i, c in enumerate(color):
        out[..., i] = (lum * c).astype(np.uint8)
    return Image.fromarray(np.dstack([out, alpha]), "RGBA")


def build_nav_logo():
    """A 218x40 nav logo drawn clean, instead of a recoloured 40px bitmap."""
    img = Image.new("RGBA", (218, 40), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    text = "CROSSMIX-OS"
    size = 19
    while size > 10:
        f = ImageFont.truetype(FONT, size)
        if d.textlength(text, font=f) <= 176:
            break
        size -= 1

    d.text((0, 8), text, font=f, fill=CREAM)

    cx, cy, r = 193, 20, 15
    pts = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
    d.line(pts + [pts[0]], fill=RED, width=2)
    d.line([(cx - 6, cy - 6), (cx + 6, cy + 6)], fill=RED, width=3)
    d.line([(cx + 6, cy - 6), (cx - 6, cy + 6)], fill=RED, width=3)
    return img


def mark_layer(size, opacity):
    """The SE mark, trimmed and scaled to sit as a watermark."""
    art = Image.open(LOGO).convert("RGB")
    # Upper part only: the scorpion inside its shield, without the wordmark.
    art = art.crop((0, 0, art.size[0], int(art.size[1] * 0.62)))

    flat = Image.new("RGB", art.size, art.getpixel((0, 0)))
    diff = ImageChops.difference(art, flat).convert("L").point(lambda v: 255 if v > 8 else 0)
    box = diff.getbbox()
    if box:
        art = art.crop(box)

    h = int(size[1] * 0.62)
    art = art.resize((int(art.size[0] * h / art.size[1]), h), Image.Resampling.LANCZOS)

    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    layer.paste(art.convert("RGBA"), ((size[0] - art.size[0]) // 2,
                                      (size[1] - art.size[1]) // 2))
    alpha = layer.split()[3].point(lambda a: int(a * opacity))
    layer.putalpha(alpha)
    return layer


def build_bg(mark_opacity=0.22):
    bg = recolor(Image.open(BASE / "skin" / "bg.png").convert("RGB"))

    # push the neutrals darker and neutral: the stock file is a blue-grey map
    arr = np.asarray(bg).astype(np.float32)
    grey = arr.mean(axis=2, keepdims=True)
    arr = np.clip(arr * 0.55 + grey * 0.45 * 0.85, 0, 255)
    bg = Image.fromarray(arr.astype(np.uint8))

    # vignette so the icon grid keeps the contrast it needs
    vig = Image.new("L", bg.size, 0)
    ImageDraw.Draw(vig).ellipse([-bg.size[0] * 0.25, -bg.size[1] * 0.3,
                                 bg.size[0] * 1.25, bg.size[1] * 1.3], fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(120))
    bg = Image.composite(bg, Image.new("RGB", bg.size, BLACK), vig)

    bg = Image.alpha_composite(bg.convert("RGBA"), mark_layer(bg.size, mark_opacity))
    return bg.convert("RGB")


def build_shutdown():
    img = recolor(Image.open(BASE / "skin" / "shutdown.png").convert("RGB"))

    d = ImageDraw.Draw(img)
    w, h = img.size
    # Deliberate badge: if it has to cover the old wordmark, make it look placed
    # there on purpose instead of like a rectangle smeared over the artwork.
    d.rectangle([w - 214, h - 54, w - 12, h - 12], fill=(10, 10, 13), outline=RED, width=2)
    f = ImageFont.truetype(FONT, 17)
    d.text((w - 202, h - 42), "CROSSMIX-OS SE", font=f, fill=CREAM)
    return img


def build_preview():
    """512x288, the shape the theme picker shows."""
    bg = build_bg(mark_opacity=0.45).resize((512, 288), Image.Resampling.LANCZOS)
    d = ImageDraw.Draw(bg)
    d.rectangle([0, 288 - 46, 512, 288], fill=(0, 0, 0, 130))
    f = ImageFont.truetype(FONT, 22)
    d.text((16, 288 - 34), "CROSSMIX-OS", font=f, fill=CREAM)
    f2 = ImageFont.truetype(FONT, 13)
    d.text((16, 288 - 12), "SCORPIO EDITION", font=f2, fill=RED)
    return bg


def update_config():
    cfg = json.loads((DEST / "config.json").read_text(encoding="utf-8"))
    cfg["name"] = "CrossMix - OS SE"
    cfg.pop("bootlogo", None)   # nothing reads it; the pack script carries it

    fc = cfg.setdefault("fontcolor", {})
    fc["content_color2"] = "#E6EC273B"      # highlight / selected, Ember Red
    fc["nav_color1"] = "#FF9A9AA4"
    fc["nav_color3"] = "#FFC8C8D0"
    (DEST / "config.json").write_text(json.dumps(cfg, indent=4) + "\n", encoding="utf-8")


THEME_SCRIPT = """#!/bin/sh

theme=$(basename "$0" .sh)

if [ -d "/mnt/SDCARD/Themes/${theme}" ]; then
    /mnt/SDCARD/System/usr/trimui/scripts/infoscreen.sh -m "Applying \\"${theme}\\" theme."
    /usr/trimui/bin/systemval "theme" "/mnt/SDCARD/Themes/${theme}/"
else
    echo "Theme directory Themes/${theme} does not exist."
    /mnt/SDCARD/System/usr/trimui/scripts/infoscreen.sh -m "\\"${theme}\\" theme directory does not exist !!" -c red -t 3
fi

/mnt/SDCARD/System/usr/trimui/scripts/mainui_state_update.sh "THEMES" "$theme"
"""

PACK_SCRIPT = """packname="CrossMix - OS SE"
style="Default"
theme="CrossMix - OS SE"
bootlogo="- CrossMix-OS SE.bmp"
emuicons="Default"
appicons="Default"
background="Default"
emulabels="Default"

. /mnt/SDCARD/System/usr/trimui/scripts/themepack_apply.sh
"""


def write_menu_scripts():
    """A theme is only reachable from the menu if it has these two entries."""
    themes_menu = ROOT / "Apps" / "SystemTools" / "Menu" / "ADVANCED SETTINGS##THEMES (value)"
    packs_menu = ROOT / "Apps" / "SystemTools" / "Menu" / "THEME##THEME PACK (value)"

    p = themes_menu / "CrossMix - OS SE.sh"
    p.write_text(THEME_SCRIPT, encoding="utf-8")
    p.chmod(0o755)

    p = packs_menu / "CrossMix - OS SE.sh"
    p.write_text(PACK_SCRIPT, encoding="utf-8")
    p.chmod(0o755)


def main():
    if not DEST.exists():
        shutil.copytree(BASE, DEST)

    build_bg().save(DEST / "skin" / "bg.png")
    build_shutdown().save(DEST / "skin" / "shutdown.png")
    build_preview().save(DEST / "preview.png")

    build_nav_logo().save(DEST / "skin" / "nav-logo.png")
    for name in ("icon-back.png", "progress-dot1.png", "progress-dot2.png",
                 "progress-dot3.png", "progress-dot4.png"):
        p = DEST / "skin" / name
        tint_mono(Image.open(p), RED).save(p)

    update_config()
    write_menu_scripts()
    print("tema SE listo en", DEST)


if __name__ == "__main__":
    main()

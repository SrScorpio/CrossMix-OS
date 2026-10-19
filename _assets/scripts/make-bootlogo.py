#!/usr/bin/env python3
"""Mount the existing CrossMix-OS SE artwork as a 1280x720 boot logo.

There is no drawing here on purpose. The brand is already defined: the mark in
_assets/readme/logo-se.png (scorpion inside a hexagonal shield, wordmark and
SCORPIO EDITION underneath) on Scorpio Black, and docs/BRANDING.md fixes the
palette. This script only places that artwork on the console's canvas at the
size the flasher accepts, so the boot screen and the rest of the brand cannot
drift apart.

The flasher (Emus/_BootLogo/launch.sh) requires a real BMP, at most 1280x720 and
under 6 MB. A 24-bit BMP at this size is 2.64 MiB, so all three hold.

Run: python3 _assets/scripts/make-bootlogo.py
Writes: Apps/BootLogo/Images_1280x720/- CrossMix-OS SE*.bmp
"""

from pathlib import Path

from PIL import Image, ImageChops

W, H = 1280, 720

# docs/BRANDING.md -> Palette / Scorpio Black. The artwork sits on exactly this
# colour, so pasting it on the same fill leaves no visible rectangle.
BG = (15, 16, 20)

SRC = Path(__file__).resolve().parents[2] / "_assets" / "readme" / "logo-se.png"
OUT = Path(__file__).resolve().parents[2] / "Apps" / "BootLogo" / "Images_1280x720"


def content_box(img):
    """Trim the flat background so the mark can be as large as possible."""
    bg = img.getpixel((0, 0))
    flat = Image.new("RGB", img.size, bg)
    diff = ImageChops.difference(img, flat).convert("L").point(lambda v: 255 if v > 8 else 0)
    return diff.getbbox() or (0, 0, img.size[0], img.size[1])


def compose(height_ratio, max_width_ratio=0.98):
    art = Image.open(SRC).convert("RGB").crop(content_box(Image.open(SRC).convert("RGB")))

    target_h = int(H * height_ratio)
    scale = target_h / art.size[1]
    if art.size[0] * scale > W * max_width_ratio:
        scale = (W * max_width_ratio) / art.size[0]

    art = art.resize((int(art.size[0] * scale), int(art.size[1] * scale)),
                     Image.Resampling.LANCZOS)

    canvas = Image.new("RGB", (W, H), BG)
    canvas.paste(art, ((W - art.size[0]) // 2, (H - art.size[1]) // 2))
    return canvas


def save(img, name):
    bmp = OUT / f"{name}.bmp"
    img.save(bmp, format="BMP")
    size = bmp.stat().st_size
    print(f"{bmp.name:<34} {img.size[0]}x{img.size[1]}  {size / 1048576:.2f} MiB")
    if size > 6 * 1024 * 1024:
        raise SystemExit(f"{bmp.name} exceeds the 6 MB limit the flasher enforces")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    # Default: the mark with breathing room, so nothing is clipped by the bezel
    # and the wordmark stays inside the safe area.
    save(compose(0.86), "- CrossMix-OS SE")
    # Edge to edge, for panels that crop a few pixels.
    save(compose(0.97, max_width_ratio=0.99), "- CrossMix-OS SE Full")
    # Quieter: same mark at 72%, more black around it.
    save(compose(0.72), "- CrossMix-OS SE Minimal")


if __name__ == "__main__":
    main()

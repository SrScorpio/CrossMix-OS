# Boot logo: how it is stored, what the flasher accepts, and how to add one

There is no need to build a firmware image to change the boot logo. The console
ships an app that does it: `Apps/BootLogo`.

## The chain, in order

1. `Apps/BootLogo/launch.sh` lists the `.bmp` files in
   `Apps/BootLogo/Images_1280x720` (TSP) or `Images_1024x768` (other devices),
   builds a thumbnail per file into `Thumbnails/`, and hands the list to MainUI
   through `GoTo_Bootlogo_List.json`.
2. When you pick one, MainUI runs `Emus/_BootLogo/launch.sh <file.bmp>`.
3. That script writes the file to the boot partition as `bootlogo.bmp` and
   shows a confirmation screen.

The first boot of a fresh card also flashes a logo, from
`System/starts/°customization.sh`: the SE mark if it is present, the stock one
otherwise.

## What the flasher accepts

`Emus/_BootLogo/launch.sh` validates before writing. All three checks must pass:

| Check | Rule | What happens if it fails |
|---|---|---|
| Real BMP | `gm identify -format %m` returns `BMP` | refuses, reports the format |
| Size | at most 1280x720 | refuses anything bigger; a smaller image is accepted with a warning |
| Weight | under 6 MB | refuses |

A 1280x720 24-bit BMP lands at 2,64 MiB, which is the shape every logo in the
repo uses. Bigger colour depths only add bytes; the panel gains nothing.

## Adding a logo

Drop the `.bmp` into `Images_1280x720` (or `Images_1024x768`). Nothing else is
needed: the app rediscovers the folder each time it launches, and every file
becomes a row in the list. Thumbnails are regenerated, and stale ones are
removed except `- Default Trimui.png`.

Name files the way the existing ones are named — a leading `-` keeps the
defaults and the brand marks at the top of the list.

## Themes can carry one too

`System/usr/trimui/scripts/themepack_apply.sh` reads a `bootlogo` field from a
theme and flashes that file when the theme is applied. No theme in the tree
uses it today; the hook exists and works.

## The SE marks

`_assets/scripts/make-bootlogo.py` draws them (PIL, 2x supersampled, 24bpp,
2,64 MiB each):

| File | What it is |
|---|---|
| `- CrossMix-OS SE.bmp` | frame, cut-free X, wordmark and SE tag — the default |
| `- CrossMix-OS SE Wordmark.bmp` | typography only, no frame |
| `- CrossMix-OS SE Scorpio.bmp` | side-view scorpion inside the frame |

Regenerate with `python3 _assets/scripts/make-bootlogo.py`; same input, same
bytes. The script refuses to write a file over the 6 MB the flasher enforces.

Design notes that came out of rendering these on a 1280x720 frame: no text
below ~18px at 1x, one accent and one focal point, and the badge as an outline
rather than a solid block, or it competes with the mark.

## Reverting

Flash any other logo from the app. The stock one is `- Default Trimui.bmp` and
is never deleted by the thumbnail cleanup.

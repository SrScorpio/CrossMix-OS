# Branding

CrossMix-OS SE (Scorpio Edition) is a GPL-3.0 fork of
[CrossMix-OS](https://github.com/cizia64/CrossMix-OS) by cizia64. This document
defines the visible brand, lists every surface where a user can see the OS name,
and records exactly what this repository changed and what it deliberately does
not touch.

Scope rule used throughout: **branding is display text and artwork only.** If a
string is read by a script, a comparator, a filename pattern or a firmware
loader, it is not branding and it is left alone.

## 1. Brand system

### Name

| Context | Form |
| --- | --- |
| Text anywhere a user reads it (splash, prompts, toasts) | `CrossMix-OS SE` |
| First mention in documentation | `CrossMix-OS SE (Scorpio Edition)` |
| Artwork wordmark | `CROSSMIX-OS` over `SCORPIO EDITION` (two lines) |

### `SE` vs `CE` — do not mix them

`SE` is the fork. It is what the product is called and what the user must see.

`CE` only exists inside the functional version key `1.4.0-ce.2` stored in
`System/usr/trimui/crossmix-version.txt`. That key is parsed by the firmware
comparator, by the OTA/hotfix gates and by the customization stamp, so it is
**never** renamed, reformatted, shortened or stripped. When the version has to be
shown, it is printed verbatim and appended to the brand name:

```
CrossMix-OS SE v1.4.0-ce.2
```

`CE` is never used as a product name, a suffix on the name, or a label in the UI.

### Palette

Sampled from the artwork already shipped in `_assets/readme/logo-se.png` and
`_assets/readme/banner-se.png`:

| Token | Hex | Use |
| --- | --- | --- |
| Scorpio Black | `#0F1014` | backgrounds |
| Ember Red | `#EC273B` | accents, highlights, wordmark accents |
| Ember Shade | `#A11727` | depth on red elements |
| Bone Cream | `#FEE4CD` | primary text on black |

No new colours are introduced for on-device text; the splash and prompts inherit
the current theme's own colours (`infoscreen.sh` default text colour is
`220,220,220`).

### Typography

No font is added. Two fonts are already available and are the only ones allowed
for brand text:

- `DejaVuSans.ttf` — the `infoscreen.sh` default fallback
  (`System/usr/trimui/scripts/infoscreen.sh:68`), already used for every splash
  message.
- `regular.ttf` — the only TTF committed to this tree
  (`System/usr/trimui/osd/regular.ttf`).

The wordmark itself is raster artwork (`_assets/readme/*`), not text, so it needs
no font at all.

### Three rules

1. **One spelling.** Any text a user reads says `CrossMix-OS SE`. Never
   `CrossMix OS v…` (upstream's form), never `SE Edition`, never `CE`, never
   `Scorpio` alone.
2. **Branding never renames function.** File and directory names, JSON keys,
   package ids, theme folders, archive names and version keys keep their upstream
   names. Rebranding is limited to the text that is rendered on screen.
3. **Red on black, and credit upstream.** Accents use Ember Red on Scorpio Black
   with Bone Cream text; every public surface that names the fork keeps the
   cizia64 attribution and the GPL-3.0 notice next to it.

## 2. Inventory of visible surfaces

Line numbers are for this branch (`feat/gh-1-branding`).

| # | Surface | Location | Before | Status |
| --- | --- | --- | --- | --- |
| 1 | Boot version splash (drawn over the theme background right after the boot logo) | `System/starts/°customization.sh:14-16` | `CrossMix OS v1.4.0-ce.2` | **changed** |
| 2 | Firmware-too-old log line (written to the update log) | `System/starts/_FirmwareCheck.sh:108` | `… must be updated to … to support CrossMix OS v…` | **changed** |
| 3 | OTA update found — not enough internal space | `System/starts/_FirmwareCheck.sh:305` | `CrossMix-OS update v…` | **changed** |
| 4 | OTA update found — install/cancel prompt | `System/starts/_FirmwareCheck.sh:328` | `CrossMix-OS update v… Press A…` | **changed** |
| 5 | Update in progress | `System/starts/_FirmwareCheck.sh:333` | `Updating CrossMix to v…` | **changed** |
| 6 | Update installer title bar | `System/starts/_FirmwareCheck.sh:336` | `CrossMix-OS Update v…` | **changed** |
| 7 | Installer failure screen | `System/usr/trimui/scripts/crossmix_update.sh:145` | `CrossMix v… installation FAILED` | **changed** |
| 8 | OSD toast: release available | `System/usr/trimui/scripts/update_notification.sh:126` | `CrossMix v… available.` | **changed** |
| 9 | OSD toast: hotfix available | `System/usr/trimui/scripts/update_notification.sh:225` | `CrossMix Hotfix … available.` | **changed** |
| 10 | SD-card `autorun` label (shown by the host OS when the card is mounted) | `autorun.inf:3` | `label = CrossMix-OS` | **changed** |
| 11 | OSD widget descriptions | `System/usr/trimui/res/osd/widgets/app_info/config.json:21`, `System/usr/trimui/osd/widgets/app_cpu_info/config.json:21` | `CrossMix HW info Widget`, `CrossMix cpu info Widget` | **changed** |
| 12 | Theme names `CrossMix - OS`, `CrossMix - Tronkyfran` (theme picker) | `Apps/SystemTools/Menu/THEME##THEME PACK (value)/CrossMix - OS.sh:13`, `.../CrossMix - Tronkyfran.sh:13` | `CrossMix - OS` | not changed — see §4.1 |
| 13 | Boot logo `- CrossMix-OS.bmp` | `Apps/SystemTools/Menu/THEME##THEME PACK (value)/CrossMix - OS.sh:16`, `.../CrossMix - Tronkyfran.sh:16`, `System/starts/°customization.sh:196` | shows the upstream logo at boot | not changed — see §4.2 |
| 14 | Stock MainUI *Information* screen | firmware UI, not in this repository | shows the internal `1.4.0-ce.2` | not changed — see §4.3 |
| 15 | Version key | `System/usr/trimui/crossmix-version.txt` | `1.4.0-ce.2` | not changed — see §4.4 |
| 16 | Update archive name | `System/starts/_FirmwareCheck.sh:289,294`, `System/usr/trimui/scripts/update_notification.sh:74-75,100` | `CrossMix-OS_v<tag>.zip/.7z` | not changed — see §4.5 |
| 17 | Hostname `TSP` | `System/starts/°customization.sh:224` | `TSP` | not changed — see §4.6 |
| 18 | System Tools app entry | `Apps/SystemTools/config.json:2,6` | `System Tools` / `Tools and system apps.` | not changed — generic, carries no brand |
| 19 | README + `_assets/readme/*` | `README.md`, `_assets/readme/logo-se.png`, `banner-se.png`, `download-se.png`, `bg-firmware-se.png` | already SE artwork | not changed — already correct |

## 3. What was changed

All changes are strings and metadata. No binary, no firmware file, no asset, no
file rename.

| File | Before | After |
| --- | --- | --- |
| `System/starts/°customization.sh` | `-m "CrossMix OS v$version"` | `Brand_Name="CrossMix-OS SE"` + `-m "$Brand_Name v$version"` |
| `System/starts/_FirmwareCheck.sh:108` | `… to support CrossMix OS v$CrossMix_version.` | `… to support CrossMix-OS SE v$CrossMix_version.` |
| `System/starts/_FirmwareCheck.sh:305` | `CrossMix-OS update v… found. Not enough space…` | `CrossMix-OS SE update v… found. Not enough space…` |
| `System/starts/_FirmwareCheck.sh:328` | `CrossMix-OS update v… found. Press A to install, B to cancel.` | `CrossMix-OS SE update v…` |
| `System/starts/_FirmwareCheck.sh:333` | `Updating CrossMix to v…` | `Updating CrossMix-OS SE to v…` |
| `System/starts/_FirmwareCheck.sh:336` | `CrossMix-OS Update v…` | `CrossMix-OS SE Update v…` |
| `System/usr/trimui/scripts/crossmix_update.sh:145` | `CrossMix v… installation FAILED` | `CrossMix-OS SE v… installation FAILED` |
| `System/usr/trimui/scripts/update_notification.sh:126` | `CrossMix v… available.` | `CrossMix-OS SE v… available.` |
| `System/usr/trimui/scripts/update_notification.sh:225` | `CrossMix Hotfix …` | `CrossMix-OS SE Hotfix …` |
| `autorun.inf:3` | `label = CrossMix-OS` | `label = CrossMix-OS SE` |
| `app_info/config.json:21` | `CrossMix HW info Widget` | `CrossMix-OS SE HW info widget` |
| `app_cpu_info/config.json:21` | `CrossMix cpu info Widget` | `CrossMix-OS SE cpu info widget` |

Two details worth knowing:

- The splash builds the name from a `Brand_Name` variable so the on-screen name
  has a single definition; the version is still read verbatim from
  `crossmix-version.txt` and is never post-processed.
- The OSD toast on line 126 is centred by hand-padded spaces. The new string is
  one character shorter, so the leading padding went from 7 to 4 spaces to keep
  the message centred inside the same box.

## 4. What was NOT touched, and why

### 4.1 Theme directory names (`CrossMix - OS`, `CrossMix - Tronkyfran`)

These are real folders under `/mnt/SDCARD/Themes/` and their names are used as
paths, not as labels:

- `System/usr/trimui/scripts/infoscreen.sh:74,79,102` resolves the current theme
  folder and reads `config.json`/font files from it.
- `System/starts/_FirmwareCheck.sh` points its firmware dialogs at
  `/mnt/SDCARD/Themes/CrossMix - OS/wqy-microhei.ttf`.
- `Apps/SystemTools/launch.sh:190` special-cases the literal name
  `CrossMix - OS` to label the default theme.
- `System/usr/trimui/scripts/MainUI_default_system.json:8` stores the default
  theme path.

Renaming them would break theme resolution, font lookup and the theme picker for
every installed SD card. They are also upstream theme names by other authors
(Tronkyfran), so rebranding them would misattribute someone else's work.

### 4.2 Boot logo (`- CrossMix-OS.bmp`)

`System/starts/°customization.sh:196` flashes
`Apps/BootLogo/Images_1280x720/- CrossMix-OS.bmp` through
`Emus/_BootLogo/launch.sh`, and the theme scripts re-point `bootlogo` at
`- CrossMix-OS.bmp` (`CrossMix - OS.sh:16`, `CrossMix - Tronkyfran.sh:16`).

This is the firmware boot logo. Replacing it requires producing our own `awimg`
image in the exact format the loader accepts, and explicit owner permission. It is
out of scope for this change: **no boot-logo asset, patch or scaffold was added.**
After the firmware flash, the console shows the stock boot logo again; that is
expected and is not something text changes can fix.

### 4.3 The stock *Information* screen

The Information page is drawn by the TrimUI firmware/MainUI and reports the
internal image version (`1.4.0-ce.2`). Nothing in this repository renders it, so
it cannot be rebranded without touching the firmware. The only OS-owned screen
that shows a name is the boot splash (§2.1).

### 4.4 `System/usr/trimui/crossmix-version.txt`

`1.4.0-ce.2` is the functional version key. It is read by:

- `System/starts/°customization.sh:12,16-20,169` (splash value, stamp comparison,
  write-back to `/usr/trimui/crossmix-version.txt`),
- `System/starts/_FirmwareCheck.sh:104,294` (firmware requirement message and OTA
  "newer than installed?" comparison),
- `System/usr/trimui/scripts/update_common.sh:60`,
  `ota_update.sh:94`, `update_ota_release.sh:119`,
  `update_notification.sh:104,219`,
- `_assets/scripts/build-hotfix-zip.sh:35` (ships it inside the hotfix payload).

Changing its format would break the comparator and the hotfix gates. It is
untouched, byte for byte, and `MinFwVersion.txt` is untouched for the same reason
(firmware requirement data, not branding).

### 4.5 Update archive names

`_FirmwareCheck.sh:289` finds `CrossMix-OS_v*.zip` and derives the tag with
`awk -F'_v|\.zip'`; `update_notification.sh:74-75` matches release assets named
exactly `CrossMix-OS_v<tag>.7z|.zip` and strips the `CrossMix-OS_v` prefix from
the release title. Renaming the archives would silently break OTA detection, so
the `CrossMix-OS_v…` filename scheme stays; only the surrounding on-screen text
was rebranded.

### 4.6 Hostname `TSP`

`hostname "TSP"` (`°customization.sh:224`) is the device's network identity. Users
reach the console over SSH/SFTP/VNC and Tailscale by that name, so it is
functional, not cosmetic, and stays as it is.

### 4.7 Binaries and firmware files

Not touched at all: `System/usr/trimui/bin/*`, `System/usr/trimui/osd/*osdd`,
`System/usr/trimui/scripts/{busybox,evtest,retroarch}`, `pic2argb`, and anything
under `trimui/firmwares/`. The OSD daemons and the firmware loader own their own
strings and formats; editing them needs a rebuild and testing on hardware.

## 5. Verification performed

```sh
busybox sh -n "System/starts/°customization.sh"
busybox sh -n System/starts/_FirmwareCheck.sh
busybox sh -n System/usr/trimui/scripts/crossmix_update.sh
busybox sh -n System/usr/trimui/scripts/update_notification.sh
python3 -m json.tool System/usr/trimui/res/osd/widgets/app_info/config.json
python3 -m json.tool System/usr/trimui/osd/widgets/app_cpu_info/config.json
git diff --stat
```

- All four scripts pass `busybox sh -n`; both JSON files still parse.
- No PNG/BMP/ICO was modified, so no image format or dimension was put at risk.
- `git diff` touches no file name, no JSON key and no version string; the version
  file and `MinFwVersion.txt` do not appear in the diff.
- `grep -rn "CrossMix OS v"` now returns nothing outside the docs.

## 6. Known gaps (deliberately left for later)

1. **The shipped hotfix payload is older than this tree.**
   `_assets/hotfixes/CrossMix-OS_v1.4.0-ce.2.zip` is a build artifact and still
   contains the pre-branding `_FirmwareCheck.sh` and `update_notification.sh`.
   Regenerate it with `sh _assets/scripts/build-hotfix-zip.sh` as part of the next
   hotfix/release (with a version bump, otherwise already-updated consoles skip
   it by the `.16` gate). It was not regenerated here on purpose: this change set
   is text-only and does not rebuild release artifacts.
2. ~~**Boot logo** returns to stock after a firmware flash and needs its own
   `awimg` plus owner permission (§4.2).~~ **Resolved, and the premise was
   wrong.** No custom `awimg` is needed: `Apps/BootLogo` flashes a `.bmp` into the
   boot partition at runtime (`Emus/_BootLogo/launch.sh`), and the SE mark is
   generated from `_assets/readme/logo-se.png` by
   `_assets/scripts/make-bootlogo.py`. See `docs/BOOTLOGO.md`.
3. **Two README assets are JPEGs with a `.png` extension**
   (`_assets/readme/logo-se.png`, `_assets/readme/banner-se.png`; confirmed with
   `file`). They render on GitHub, but they are mislabelled. Fixing it means
   renaming to `.jpg` and updating `README.md:2` — a separate, mechanical change
   that would break any external hotlink to the current names, so it is not done
   here.
4. **Upstream prose in `README.md`** still says "CrossMix-OS" in the inherited
   *Introduction* body. That text is cizia64's and is kept verbatim for
   attribution; the fork identifies itself in the header, the badge line and this
   document.

## 7. The SE theme

`Themes/CrossMix - OS SE` is a copy of the stock theme with the accent moved from
teal to Ember Red. It is a copy and not a rename on purpose: several firmware
scripts hard-code `/mnt/SDCARD/Themes/CrossMix - OS/wqy-microhei.ttf` to draw the
firmware-update screens (`_FirmwareCheck.sh`, `infoscreen2.sh`). Renaming or
removing the stock theme breaks those screens, so the stock folder stays exactly
where it is and the SE one sits beside it.

What changed:

| Asset | Change |
|---|---|
| `skin/bg.png` | rebuilt: black plate, one red glow, hexagonal lattice, SE mark as a transparent watermark. Nothing of the stock bitmap survives — it carried its own emblem and two marks in one place looked wrong |
| `skin/shutdown.png` | teal shifted to red; the old wordmark in the corner replaced by a bordered `CROSSMIX-OS SE` badge |
| `skin/nav-logo.png` | regenerated at 218x40 — `CROSSMIX-OS` in Bone Cream plus the diamond mark, instead of a recoloured 40px bitmap |
| `skin/icon-back.png`, `skin/progress-dot1-4.png` | rebuilt from luminance in Ember Red |
| `config.json` | `name` = `CrossMix - OS SE`, `content_color2` = `#E6EC273B`, nav greys warmed |

What did **not** change: the rest of the skin is already neutral grey, so it
needs no recolouring; icons, sounds and fonts are untouched. The theme carries
its own copy of `wqy-microhei.ttf` (5 of its 6.7 MB) because a theme folder
without its font fails to render.

Reaching it from the console takes two files besides the folder:

- `Apps/SystemTools/Menu/ADVANCED SETTINGS##THEMES (value)/CrossMix - OS SE.sh`
  applies the theme alone.
- `Apps/SystemTools/Menu/THEME##THEME PACK (value)/CrossMix - OS SE.sh` is the
  pack: theme + boot logo + icon set in one action. `themepack_apply.sh` reads
  `theme` and `bootlogo` from those variables — **not** from the theme's
  `config.json`, which is why no `bootlogo` key is written there.

Regenerate with `python3 _assets/scripts/make-theme-se.py`. Two traps found the
hard way: a hue shift leaves a teal fringe on antialiased 40px assets (they are
rebuilt from luminance instead), and the SE mark is a flat `#0F1014` square that
shows as a floating rectangle unless its alpha is rebuilt from the difference
against that colour.

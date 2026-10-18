# Slimming options (GitHub #4)

**Status:** proposal only. Nothing in this document has been implemented: no asset has been
deleted, moved, recompressed or rewritten.
**Scope:** CrossMix-OS SE on TrimUI Smart Pro (TG5040, aarch64, ~1 GB RAM), SD-card tree.
**Tree measured:** commit `9bd776b5` (`main`), sparse worktree, no binary executed.
**Companion work:** GitHub #3 owns device-level measurement (real FAT32 usage, boot-to-menu
time, per-app open time). Wherever this document needs a device number it says
`[pendiente de #3]` instead of estimating one.

**Evidence legend** (same convention as `docs/ota-security-design.md`):

| Label | Meaning |
| --- | --- |
| **FACT** | Verified in this repository: path, line, blob size or blob hash. |
| **ASSUMPTION** | Reasonable inference from repo evidence; not proven on the device. |
| **UNKNOWN** | Needs hardware or a fuller tree before it can be decided. |

---

## 1. What the tree weighs

### 1.1 Size by directory

All figures are **logical blob bytes from the git index** at the commit above, not FAT32
cluster usage. The card rounds every file up to a cluster, so on-device `du` will be larger;
the difference is #3's number.

| Directory | MiB | Files | Notes |
| --- | ---: | ---: | --- |
| `RetroArch/` | 1 464.9 | 11 758 | cores 1 099.1, overlays 126.8, database 107.6, assets 46.7, shaders 35.0 |
| `Emus/` | 790.1 | 1 761 | SCUMMVM 294.2, PSP 115.2, JAVA 94.5, DC 63.4, NDS 52.5, ADVMAME 47.5 |
| `Apps/` | 525.7 | 1 450 | PortMaster 272.8, BootLogo 110.6, ScreencapTK 61.5, EbookReader 40.5 |
| `System/` | 500.3 | 1 065 | `lib/` 159.7, `bin/` 147.1, `updates/` 106.5, sftpgo 52.5 |
| `trimui/` | 160.0 | 69 | firmware payload 153.4 (`.7z.001`), required by the release workflow |
| `Themes/` | 135.8 | 3 111 | 18 theme packs, per-theme fonts and `bgm.mp3` |
| `_assets/` | 131.8 | 45 | **not shipped**: the release step runs `rm -rf _assets` |
| `BIOS/` | 125.5 | 420 | required by cores; `BIOS/scummvm/` is 117.7 of it |
| `Backgrounds/` | 74.7 | 425 | one background per system per theme |
| `Icons/` | 73.9 | 2 241 | icon packs, one set per system per pack |
| `Best/` | 69.4 | 81 | "Free Games Collection" template, incl. 2× FreeDoom WADs (55.0) |
| `Roms/` | 54.8 | 309 | 107 system dirs; 104 hold only `.gitkeep`, DAPHNE/VIDEOS carry media |
| `Data/`, `Imgs/`, `Pictures/`, `docs/`, `scripts/` | 3.4 | 170 | negligible |
| **Total** | **4 110.7** | **22 946** | |

FACT: `du -sh` on the sparse checkout shows 29 MiB because only `Apps/SystemTools`,
`System/usr/trimui`, `System/starts`, `.github` and `_assets` are materialised. The index is the
authoritative size list here.

### 1.2 Duplicate bytes (content-identical)

FACT: comparing blob hashes across the whole index yields **1 840 groups of identical files** and
**433.7 MiB of extra copies**. Removing groups that live entirely inside `_assets` (never shipped)
leaves **354.4 MiB of duplicated bytes in the shipped tree**:

| Top-level | Duplicate MiB | Main cause |
| --- | ---: | --- |
| `Apps/` | 177.1 | PortMaster ships the same 5 CJK Noto fonts in 6 theme directories |
| `Emus/` | 92.6 | PPSSPP builds and PSPMINIS share assets; flycast v1.0 vs v2.4 |
| `Themes/` | 42.8 | the same `bgm.mp3` and `wqy-microhei.ttf` in every theme pack |
| `RetroArch/` | 17.5 | UI fonts repeated across menu drivers, a stray `bold.bak.ttf`, overlay PNGs duplicated under `_Others/` |
| `Backgrounds/` | 12.3 | 19 systems share one background image in "Epic Noir" |
| `System/` | 7.3 | libraries repeated across `bin/` and `lib/` |

Duplicate bytes are **not automatically recoverable**: on FAT32 the card cannot symlink or
hardlink, so a duplicate only becomes a saving when one of the two consumers can be pointed at
the other copy or removed. That is the test every option below has to pass.

### 1.3 Reachability, not just size

Size alone says nothing about whether a byte is reachable by a user. Two facts change the picture:

- FACT: 160 `.so` cores (956.3 MiB) plus 5 `.7z` cores (142.5 MiB) ship in
  `RetroArch/.retroarch/cores`. Only **107** core artifacts are referenced by an `Emus/`
  launcher. `docs/cores-inventory.tsv` records the rest with `referenced_by_count = 0`.
- FACT: `Apps/RetroArch/` is a first-class menu entry (`Apps/RetroArch/config.json`), and its
  `launch.sh` starts RetroArch's own UI, which browses cores. So the 57 `.so` cores that no `Emus/`
  script names (**249.3 MiB**) are *unwired from the menu*, not dead. Deleting them is a
  product decision about an escape hatch, not a cleanup — see §4.3.

Overlays are the counter-example, and the reason "big folder ⇒ easy win" is wrong:

- FACT: `RetroArch/.retroarch/overlay/` is 126.8 MiB / 834 files. 380 distinct images are
  referenced by the `.cfg` descriptors shipped next to them, and the stock menu offers overlays
  as a user setting (`Apps/SystemTools/Menu/EMULATORS##OVERLAYS (value)/`, five options). Only
  **108 images (7.2 MiB)** are referenced by no `.cfg`. The other ~120 MiB *is* the bezel
  feature.

### 1.4 What the menu actually scans

FACT: the launcher caches one SQLite file per ROM directory — `reset_list.sh` line 76 removes
`"$RomDir/${RomDirBase}_cache7.db"` to force a rescan, and `mainui_state_update.sh` (lines 25-30)
rewrites the per-app `Menu_cache7.db` under `Apps/<App>/Menu/`. There is also a global list index
at `/mnt/romwinidx.json`.

Consequence, stated plainly: **the shipped tree's biggest directories are not on the boot path.**
Cores, overlays, `database/rdb`, `assets/`, `Themes/`, `Icons/` and `Backgrounds/` are read when
the relevant app opens, not when the main menu paints. **ASSUMPTION:** the stock launcher binary
is not in this tree, so "what it enumerates at paint time" is inferred from the caches and
`config.json` contracts it leaves behind, not observed. The scan surface the distro itself
contributes is:

| Scanned at menu paint | Count | Cost driver |
| --- | ---: | --- |
| `Roms/<system>/` directories | 107 | 104 hold only `.gitkeep`; the cost is the user's ROM count, not ours |
| `Emus/<system>/` entries | 112 | one `config.json` each, 109 emulator entries |
| `Apps/<app>/` entries | 18 | one `config.json` each |
| `Apps/SystemTools/Menu/` | 405 files | app open, not boot; one `.sh` + one image per option |
| `Apps/PortMaster/PortMaster/themes/` | 180 files | PortMaster start |
| `Apps/BootLogo/Images_1280x720/` | 24 BMP | BootLogo regenerates every thumbnail on each launch |

One detail matters for every "reduce scanned files" idea: the scan target is whatever
`config.json:rompath` names, which can be narrower than the directory. `Emus/DAPHNE/config.json`
points at `../../Roms/DAPHNE/roms`, so the 186 bezel/sound/picture files in `Roms/DAPHNE/`
(9.8 MiB) are already outside the scan — moving them elsewhere would buy nothing.

So a cut that removes *files from a non-scanned directory* buys card space only. A cut that
removes *menu entries or per-launch scans* buys perceived speed. Options are labelled
accordingly, and no option here claims a boot-time win that #3 has not measured.

---

## 2. Touchable and untouchable

### 2.1 Untouchable

| Area | MiB | Why |
| --- | ---: | --- |
| `BIOS/` | 125.5 | cores refuse to start without the right BIOS; there is no substitute and no smaller build |
| `trimui/firmwares/*.7z.001` | 153.4 | the release workflow *validates* its presence against `MinFwVersion.txt` and fails the build without it |
| `RetroArch/.retroarch/cores/*.7z` | 142.5 | already-compressed aarch64 cores; the release step extracts them to `.so`, so the archive is repo-size hygiene, not runtime payload |
| User content (`Roms/`, saves, states, screenshots, thumbnails) | — | not ours to delete; the worst possible failure mode |
| aarch64 binaries with no source in-tree | — | cannot be rebuilt or stripped safely; GPL-3.0 obligations attach to the exact builds that ship |
| `RetroArch/retroarch.cfg`, `Emus/*/config.json` | <1 | configuration, and every option below depends on them staying coherent |

### 2.2 Touchable

| Area | MiB | Basis for calling it touchable |
| --- | ---: | --- |
| Binaries no script calls (`ffplay`, `ffprobe`) | 35.8 | zero non-binary references in the whole index |
| Assets for a resolution this device never reads | 49.8 | `Apps/BootLogo/launch.sh` branches on device id; TSP takes the other branch |
| Superseded builds kept as fallbacks | 107.9 | every launcher calls the unversioned binary or the newest build |
| Superseded asset generations | ~144.6 | 9 dated ScummVM icon packs, plus 19.0 MiB identical between `BIOS/scummvm` and `Emus/SCUMMVM` |
| Duplicated per-theme payload | up to 219.9 | identical fonts/music repeated per theme; each theme is independently droppable |
| Installer payloads carried in the image | 104.9 | re-downloadable, and the tree already has one payload that works this way (`tailscale.7z`) |

### 2.3 Grey (needs a product decision, not a measurement)

- The 57 unwired cores (249.3 MiB) — reachable through the RetroArch core browser.
- `Best/Free Games Collection` (69.4 MiB) — shipped freeware, not weight, a feature.
- `Apps/EbookReader/Books/*.epub` (10.1 MiB) — two preinstalled books.
- The 18 theme packs (135.8 MiB) and their icon/background sets (148.6 MiB) — the customization
  story is a headline feature of this fork.

---

## 3. Options

Each option states: evidence, measured gain, what breaks, how to verify on the console, whether
it is reversible, and the minimum experiment that demonstrates the gain. Times are left to #3;
gains are MiB measured from the index.

### Option A — remove binaries nothing calls (`ffplay`, `ffprobe`)

**Evidence.** FACT: `Apps/ScreencapTK/bin/` ships `ffmpeg` (18.0 MiB), `ffprobe` (17.9 MiB) and
`ffplay` (17.9 MiB). FACT: a whole-index grep for `ffplay` and `ffprobe` returns no non-binary
reference; `Apps/ScreenRecorder/launch.sh` calls only `$bindir/ffmpeg` (line 14), with `bindir`
set to `Apps/ScreencapTK/bin`. No script adds that directory to `PATH`.

**Gain.** 35.8 MiB. No scan or start-up effect (nothing enumerates that directory at boot).

**What breaks.** Only a caller outside this repository that resolves `ffplay`/`ffprobe` through
`Apps/ScreencapTK/bin`. **ASSUMPTION:** PortMaster ports ship their own media tools and do not
borrow these; not verified on device.

**Verify on console.**

```sh
# before: prove nothing in the shipped tree calls them
grep -rl --include='*.sh' -e ffplay -e ffprobe /mnt/SDCARD 2>/dev/null \
  | grep -v 'Apps/ScreencapTK/bin'
# expected: no output
# then: prove the recording path still works
ls -l /mnt/SDCARD/Apps/ScreencapTK/bin/ffmpeg
```

**Reversible.** Yes — move back, no config change involved.

**Minimum experiment.**

| Step | Command / action | Metric |
| --- | --- | --- |
| Before | `du -sm /mnt/SDCARD/Apps/ScreencapTK; find /mnt/SDCARD/Apps/ScreencapTK -type f \| wc -l` | MiB, file count |
| Change | `mv /mnt/SDCARD/Apps/ScreencapTK/bin/ffplay /mnt/SDCARD/.trash/` (same for `ffprobe`) | — |
| After | run ScreenRecorder for 30 s, play the file on a PC; take one screenshot with ScreencapTK | file plays, screenshot saved |
| Re-measure | same `du`/`find` | Δ MiB should equal 35.8 |

### Option B — drop the boot-logo set for the other resolution

**Evidence.** FACT: `Apps/BootLogo/` holds `Images_1280x720/` (60.7 MiB, 24 BMPs) and
`Images_1024x768/` (49.8 MiB, 23 BMPs). `Apps/BootLogo/launch.sh` reads
`/etc/trimui_device.txt` and uses `Images_1280x720` when the device is `tsp`, otherwise
`Images_1024x768`. The TSP is the only target of this fork (README), and the app only ever
scans `$src_dir` plus `Thumbnails/`.

**Gain.** 49.8 MiB. **No scan effect**: the app never enumerates the unused directory, so this is
card space and image size only. Do not sell it as a speed win.

**What breaks.** Using the same SD image on a 1024×768 TrimUI device: the BootLogo entry stays
in the menu but fails with an empty file list. Mitigation if that matters: keep 3 logos in that
directory instead of all 23.

**Verify on console.**

```sh
cat /etc/trimui_device.txt                 # expect: tsp
ls /mnt/SDCARD/Apps/BootLogo/Images_1024x768 | wc -l
grep -n 'Images_1024x768' /mnt/SDCARD/Apps/BootLogo/launch.sh   # only the else branch
```

**Reversible.** Yes — the directory is self-contained.

**Minimum experiment.**

| Step | Command / action | Metric |
| --- | --- | --- |
| Before | `du -sm /mnt/SDCARD/Apps/BootLogo/Images_*` | 60.7 / 49.8 |
| Change | `mv Images_1024x768 /mnt/SDCARD/.trash/` | — |
| After | open BootLogo, apply one logo, reboot, confirm the logo appears | logo applied |
| Re-measure | `du -sm /mnt/SDCARD/Apps/BootLogo` | Δ 49.8 MiB |

### Option C — retire superseded builds kept as fallbacks

**Evidence.** FACT: three classes of "old build still shipped":

| Artifact | MiB | Reachable from |
| --- | ---: | --- |
| `RetroArch/ra64.trimui-1.15.0`, `-1.17.0`, `-1.18.0`, `-1.20.0` | 32.7 | only the hold-Y selector in `Apps/RetroArch/launch.sh` (or a manual shell call); every `Emus/` and `System/` launcher calls plain `ra64.trimui` |
| `Emus/PSP/PPSSPP_1.15.4/` | 38.8 | `Emus/PSP/ppsspp_1.15.4.sh`, a `launchlist` entry in `Emus/PSP/config.json` |
| `Emus/DC/flycast_v1.0/` | 36.4 | `Emus/DC/flycast_standalone_v1.0.sh`, a `launchlist` entry |

FACT: `Emus/PSPMINIS/` is a third copy of PPSSPP (31.7 MiB) that shares **44.5 MiB of
byte-identical files** with `Emus/PSP/`. It is a separate menu system, so it can be repointed at
the PSP build instead of deleted.

**Gain.** 107.9 MiB by dropping the four `ra64` fallbacks plus PPSSPP 1.15.4 and flycast v1.0;
a further 31.7 MiB if PSPMINIS is repointed at `PPSSPP_1.17.1` instead of shipping its own copy.

**What breaks.** Exactly what the fallbacks exist for. **UNKNOWN:** the repository does not
record *why* each old build was kept; the `launchlist` entries carry no comment. The plausible
reason is per-title regressions in the newer build (**ASSUMPTION**). Deleting a fallback turns
"this game looks wrong here, try the other build" into "this game no longer runs".

**Verify on console.**

```sh
# every reference to a versioned RetroArch binary
grep -rn 'ra64.trimui-' /mnt/SDCARD/Emus /mnt/SDCARD/System 2>/dev/null | head
# the launchlist entries that would disappear
sed -n '/launchlist/,/]/p' /mnt/SDCARD/Emus/PSP/config.json
sed -n '/launchlist/,/]/p' /mnt/SDCARD/Emus/DC/config.json
# what the PSP Minis entry actually executes
cat /mnt/SDCARD/Emus/PSPMINIS/config.json
```

**Reversible.** Yes for a removal (restore the directory); repointing PSPMINIS is a one-line
change in its launcher, also reversible.

**Minimum experiment.**

| Step | Command / action | Metric |
| --- | --- | --- |
| Before | list the three titles each fallback is known to fix (owner's knowledge — not in the repo) | named titles per build |
| Change | move one fallback aside at a time, starting with `ra64.trimui-1.15.0` | — |
| After | run those titles on the remaining build; record FPS, audio, save-load | frames dropped, audio glitches |
| Re-measure | `du -sm /mnt/SDCARD/RetroArch /mnt/SDCARD/Emus/PSP /mnt/SDCARD/Emus/DC` | Δ MiB per step |

Do not batch this one: one fallback per commit, so a regression has a single culprit.

### Option D — collapse superseded asset generations (ScummVM first)

**Evidence.** FACT: `Emus/SCUMMVM/ScummVM/icon/` is 161.5 MiB across 10 files, of which **9 are
dated generations of the same icon pack**:

| File | MiB |
| --- | ---: |
| `gui-icons-20211112.dat` | 24.1 |
| `gui-icons-20220602.dat` | 26.1 |
| `gui-icons-20220802.dat` | 8.1 |
| `gui-icons-20221010.dat` | 5.8 |
| `gui-icons-20230317.dat` | 25.7 |
| `gui-icons-20230807.dat` | 21.8 |
| `gui-icons-20231110.dat` | 9.2 |
| `gui-icons-20231231.dat` | 4.8 |
| `gui-icons-20241222.dat` | 13.0 |
| `shaders-20230108.dat` | 23.0 |

Only one generation can be in use at a time. FACT: `BIOS/scummvm/` and `Emus/SCUMMVM/` also hold
**33 byte-identical files (19.0 MiB)**, including `Roland_SC-55.sf2` and `titanic.dat`. Both trees
also carry a `fonts-cjk.dat` of exactly 36.5 MiB, but the two blobs **differ** (different content
hashes), so they are near-duplicates for two engine paths, not copies of one file — the standalone
build reads `Emus/SCUMMVM/ScummVM/`, the libretro core reads `BIOS/scummvm/`, and both paths are
live today.

**Gain.** Up to **125.6 MiB** of stale icon generations (keeping the newest pack) plus **19.0 MiB**
of exact duplicates — but the duplicate half only pays if the two engines can share one directory,
which is a ScummVM path decision, not a file move. Plan on 125.6 MiB verified, 144.6 MiB
optimistic.

**What breaks.** If the shipped ScummVM build requests a specific generation (the filenames are
versioned, so this is likely), deleting the wrong pack leaves the UI unthemed or the standalone
build refusing to start. **UNKNOWN:** no `.cfg`/`.ini` in the tree names a pack; the selection
is internal to ScummVM.

**Verify on console.**

```sh
ls -l /mnt/SDCARD/Emus/SCUMMVM/ScummVM/icon/          # 10 dated packs
grep -ri 'gui-icons' /mnt/SDCARD/Emus/SCUMMVM/ /mnt/SDCARD/BIOS/scummvm/ 2>/dev/null
du -sm /mnt/SDCARD/Emus/SCUMMVM /mnt/SDCARD/BIOS/scummvm
```

**Reversible.** Yes — the packs are self-contained files.

**Minimum experiment.**

| Step | Command / action | Metric |
| --- | --- | --- |
| Before | start the standalone ScummVM, open its launcher UI; start one game through the libretro core | UI renders, game boots |
| Change | move the 7 oldest `gui-icons-*.dat` to `.trash/`, keep the two newest (≈120.8 MiB) | — |
| After | repeat both launches, plus a theme change inside ScummVM | icons render, no "missing asset" |
| Re-measure | `du -sm /mnt/SDCARD/Emus/SCUMMVM/ScummVM/icon` | Δ MiB, target ≈ 125 |

If the standalone build complains, restore one generation at a time — the filenames give the
order for free. Once both engines run clean on the two newest packs, dropping the older of the two
is the last 4.8 MiB of the 125.6 MiB target.

### Option E — duplicated per-theme payload (PortMaster first, Themes second)

**Evidence.** FACT: `Apps/PortMaster/PortMaster/themes/` holds 7 theme directories and **40 font
files totalling 212.2 MiB**:

| Theme | MiB | Files |
| --- | ---: | ---: |
| Doom | 46.4 | 31 |
| ff_VII | 44.7 | 25 |
| Fallout | 41.2 | 41 |
| Stardew | 40.4 | 37 |
| Zelda | 38.9 | 26 |
| hiviz | 35.9 | 16 |
| basic_theme | 0.7 | 4 |

FACT: `NotoSansSC/TC/HK/KR/JP-Regular.ttf` appear **six times each** (once per full theme), which
is 177.1 MiB of byte-identical copies — the single largest duplication in the tree. FACT: the
same pattern exists in `Themes/`: one `wqy-microhei.ttf` (4.4 MiB) appears in 3 theme packs
plus the Drastic build, and `bgm.mp3` (1.88 MiB ×5) / `bgm2.mp3` (3.10 MiB ×6) repeat across the
packs, for 42.8 MiB of duplicate bytes.

**Gain.** Removing unused themes is the no-code-change version: each dropped full theme is
35.9-46.4 MiB (and removes 16-41 files from PortMaster's theme listing). Collapsing the CJK
fonts to one shared copy is worth 177.1 MiB but requires changing how PortMaster resolves
theme fonts — **ASSUMPTION:** it reads the font by name from the active theme directory, in
which case a shared directory needs a code change upstream. Verify before planning on it.

**What breaks.** Dropping a theme a user has selected: PortMaster falls back to its default and
the saved selection is lost. Dropping CJK fonts breaks UI text for Chinese/Japanese/Korean port
titles only — invisible in an English UI, which is exactly why it must be tested with a CJK title.

**Verify on console.**

```sh
ls /mnt/SDCARD/Apps/PortMaster/PortMaster/themes/
find /mnt/SDCARD/Apps/PortMaster/PortMaster/themes -name '*.ttf' | wc -l
md5sum /mnt/SDCARD/Apps/PortMaster/PortMaster/themes/*/NotoSansSC-Regular.ttf | awk '{print $1}' | sort -u | wc -l
# expected: 1 (proves the six copies are identical)
```

**Reversible.** Yes — move the theme directory back; the selection is a config value.

**Minimum experiment.**

| Step | Command / action | Metric |
| --- | --- | --- |
| Before | time PortMaster from tap to its port list (3 runs); start a port; open the theme picker | seconds; theme count |
| Change | move one theme (start with `Doom`) to `.trash/` | — |
| After | same three steps; then launch a CJK-named port to check font fallback | seconds; CJK text legible |
| Re-measure | `du -sm /mnt/SDCARD/Apps/PortMaster` | Δ 46.4 MiB; expect a small PortMaster start improvement `[pendiente de #3]` |

### Option F — stop carrying installer payloads in the image

**Evidence.** FACT: `System/updates/` is 106.5 MiB, of which `update_001/python.zip` is 78.33 MiB
and `portmaster_fix.7z` is 26.55 MiB. FACT: both are consumed by `portmaster_fix.sh`
(lines 166-167 and 207-208), which verifies an MD5 and extracts; both have a remote source
declared in the same file (lines 169-170, 209-210) pointing at
`raw.githubusercontent.com/.../main/_assets/resources/`. FACT: the repo already ships one payload
this way — `_assets/resources/tailscale.7z` (19.6 MiB) is **not** in the image;
`Apps/SystemTools/Menu/NETWORK##Tailscale (state)/Tailscale  - enable.sh` downloads it on first
enable and deletes the temp copy.

So the pattern "payload lives in the repo, image fetches it on demand" is already established
product behaviour, and `python.zip`/`portmaster_fix.7z` are the two files that did not get it.

**Gain.** 104.9 MiB.

**What breaks.** The PortMaster repair path (`portmaster_fix.sh`) stops working **offline** or
behind a network that blocks `raw.githubusercontent.com`. That path is reachable from the menu and
is the documented fix for a broken PortMaster install, so the failure lands exactly when the user
has no working package manager. Also note the scripts currently *prefer* the local copy; they
already have a download fallback, so the change is a default flip, not new logic.

**Verify on console.**

```sh
grep -n 'Archive_URL\|Archive=\|verify_md5' /mnt/SDCARD/System/usr/trimui/scripts/portmaster_fix.sh | head
md5sum /mnt/SDCARD/System/updates/update_001/python.zip
wc -c /mnt/SDCARD/System/updates/update_001/python.zip.md5
```

**Reversible.** Yes — re-download, or restore the two files.

**Minimum experiment.**

| Step | Command / action | Metric |
| --- | --- | --- |
| Before | run the PortMaster repair from the menu **with the network on**, then again **with it off** | works / fails, and how it fails (message vs silence) |
| Change | move `python.zip` and `portmaster_fix.7z` aside | — |
| After | repeat both runs; confirm the online run downloads and extracts, and that the offline run fails loudly | success path, failure message |
| Re-measure | `du -sm /mnt/SDCARD/System/updates` | Δ 104.9 MiB |

Ship this one only with an explicit offline story (menu text or a fallback URL). A silent failure
here is worse than the 104.9 MiB.

---

## 4. Recommended order

### 4.1 Order and why

1. **A — unreferenced binaries (35.8 MiB).** Zero product surface, one grep proves it, one
   recording proves it still works. Do this first as the method's calibration: if the measured Δ
   does not match 35.8 MiB, #3's numbers and these numbers are not comparable and nothing else
   should be trusted.
2. **B — wrong-resolution boot logos (49.8 MiB).** Also zero product surface on this device, and
   it removes a latent trap (23 files that can never be used on a TSP).
3. **D — ScummVM asset generations (≈125.6 MiB).** Biggest verified win with the narrowest blast
   radius: one emulator, two launch paths, both testable in five minutes. This is where the
   card-size story gets real.
4. **F — installer payloads (104.9 MiB).** No UX change when online, but it needs an explicit
   offline failure story before it can ship; do it after the cheap wins have shown the method
   holds.
5. **C — superseded builds (107.9 MiB + 31.7 optional).** Only after someone names the titles each
   fallback exists for. Without that list this is a coin flip on user reports.
6. **E — per-theme payload (46 MiB per theme, up to 177 with code change).** Last because the
   real win needs an upstream PortMaster change, and the no-code version depends on which themes
   are actually used — usage data we do not have.

### 4.2 Acceptance rule for a cut

A cut ships only if all four hold, which is the owner's "demonstrated improvement" rule made
mechanical:

1. **Measured**: Δ MiB and Δ file count recorded on the card, not in the index.
2. **Reachability proof**: a grep/parse over the shipped launchers showing what referenced the
   removed files, and why that reference is gone or repointed.
3. **Negative test on device**: the feature that used the removed files was exercised *after* the
   cut, not before.
4. **Revert path written down** in the issue, with the exact restore command.

Anything that fails (2) is not a cleanup, it is a feature removal and needs a product decision.

### 4.3 Rejected or deferred

| Candidate | MiB | Why not now |
| --- | ---: | --- |
| The 57 cores no `Emus/` launcher names | 249.3 | **Reachable** through `Apps/RetroArch`'s core browser. Deleting them is removing an escape hatch to win a size contest. Needs per-core usage evidence first; a per-core "last used" log is the only honest way to get it. |
| RetroArch overlays | 126.8 | 380 of 440 images are referenced by shipped `.cfg` descriptors and the menu exposes both variants as a user setting. Only 7.2 MiB is unreferenced — not worth the churn. |
| `RetroArch/.retroarch/database/rdb` | 107.6 | `retroarch.cfg` sets `content_database_path` to it; removing it breaks RetroArch's own scan path. |
| `RetroArch/.retroarch/assets/` | 46.7 | `menu_driver = "xmb"` and xmb is 16.9 MiB of it. The `ozone`/`glui`/`rgui`/`switch` sets (17.8 MiB, 1 068 files) are reachable only by changing the menu driver — a real but tiny win, and it breaks a documented option. |
| `BIOS/` | 125.5 | Cores require it. Not a slimming target. |
| Firmware payload | 153.4 | The release workflow fails without it. |
| `Best/Free Games Collection` | 69.4 | Shipped freeware is a feature, not weight; the two FreeDoom WADs alone are 55.0 MiB, so the question is "do we still ship free games", not "how do we compress them". |
| Recompress cores or assets | — | `.so` and `.7z` are already compressed; the image is packed with `7z -mx=7`. Recompression buys nothing measurable and risks GPL source/artifact mismatch. |
| Symlink/hardlink the duplicated fonts | 219.9 | FAT32 supports neither. This is why every duplicate has to be resolved by removal or code change. |
| Stripping aarch64 binaries | — | No source in-tree, and stripping shipped GPL binaries invites a "where is the corresponding source" question for a few MB. |

**Deferred, worth a second look once #3 reports:** `Apps/EbookReader/koreader.7z` (26.9 MiB) is an
installer archive for an app that is also published upstream — the same download-on-demand pattern
as Option F, but KOReader is an offline-first reading app, so the trade is different.

---

## 5. Decision table

Gain is measured from the index at `9bd776b5`; "cost" is the work needed to ship and prove the cut.

| Option | Cost | Gain | Risk |
| --- | --- | --- | --- |
| **A** — drop `ffplay`, `ffprobe` | Very low: one grep, one recording test | 35.8 MiB | Very low. Only an out-of-tree caller could notice; PATH does not expose them |
| **B** — drop 1024×768 boot logos | Very low: one device-id check, one reboot | 49.8 MiB | Low. Breaks BootLogo on non-TSP hardware sharing the card |
| **D** — collapse ScummVM asset generations | Low-medium: two engine tests, staged restore | ≈125.6 MiB verified, 144.6 with duplicate dedupe | Medium. Wrong pack removed ⇒ ScummVM UI unthemed or won't start; recoverable by filename order |
| **F** — fetch installer payloads on demand | Medium: needs an offline failure story and menu copy | 104.9 MiB | Medium-high. PortMaster repair fails with no network — the moment it is most needed |
| **C** — retire fallback builds | Medium: per-title regression testing, one build per commit | 107.9 MiB (+31.7 by repointing PSP Minis) | High. Removes the "try the other build" remedy for titles whose regressions nobody recorded |
| **E** — per-theme duplicated payload | High for the full win (upstream PortMaster change); low for dropping themes | 35.9-46.4 MiB per dropped theme; 177.1 MiB with code change | Medium. Breaks a saved theme selection, or CJK text in ports if fonts are collapsed |
| *(deferred)* 57 unwired cores | High: needs usage telemetry first | 249.3 MiB | Very high. Removes the RetroArch escape hatch; guaranteed "my game stopped working" reports |

Reading the table: A + B + D is **≈211 MiB for low effort and low risk**, and that is the
defensible first release. F and C roughly double it but each needs a story the repo cannot supply
today. E is only worth it with usage data. The 249.3 MiB of unwired cores is the largest number on
the page and the last thing that should be touched.

---

## 6. What is still missing (owners: #3 and the device)

| Question | Why it blocks | How to answer |
| --- | --- | --- |
| Real FAT32 usage per directory | Index bytes ignore cluster rounding; the card is the constraint | `du -sm` per directory on the card, `[pendiente de #3]` |
| Boot-to-menu time, and its sensitivity to file count | The whole "scanned files beat MiB" premise is a **hypothesis** here: no measurement in the repo ties boot time to file count | Stopwatch ×5 with the current tree, then again after Option D; plus `cat /proc/uptime` right after the menu paints |
| Which ScummVM icon generation is actually loaded | Decides whether Option D is 125.6 MiB or 13 MiB | Run ScummVM standalone after moving packs, one at a time |
| Which titles justify each fallback build (Option C) | Not recorded anywhere in the tree | Owner's memory, written into the issue before deletion |
| Whether PortMaster resolves theme fonts by path or by name (Option E) | Decides between 46 MiB (drop themes) and 177 MiB (share fonts) | Read the PortMaster theme loader on device; `grep -r NotoSans /mnt/SDCARD/Apps/PortMaster` |
| Which cores users actually launch through RetroArch | The only honest input for the 249.3 MiB question | Add a per-core launch counter to the launcher script and read it after a release cycle |

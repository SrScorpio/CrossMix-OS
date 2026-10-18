# SLIM-MEASURE — what the payload actually weighs

Read-only audit of the CrossMix-OS SE SD payload, produced for
[#3](https://github.com/scolf/CrossMix-OS-SE/issues/3) before deciding what to cut.
Nothing in the tree was deleted, re-encoded or reconfigured: this document only
measures.

Every figure is tagged:

| tag | meaning |
| --- | --- |
| **MEASURED** | counted or hashed on the real tree, or compressed with the release's own settings |
| **EXTRAPOLATED** | a ratio measured on a sample, applied to the population; the sample size and its assumption travel with the number |
| **NOT MEASURED** | the tree does not answer the question; stated as such instead of estimated |

---

## 1. Reproduce this

```sh
# inventory, sha256 duplicates, junk, core archive members  (~2 min, hashes 4 GB)
python3 scripts/slim-measure.py --fast --hash-cache --jobs 8 \
    --output canonical.json --cache /tmp/slim-cache

# PNG lossless potential, size-stratified sample
python3 scripts/slim-measure.py --no-hash --no-cores --png-sample 200 --jobs 8 \
    --output png.json --cache /tmp/slim-cache

# core .so vs .7z, evenly spaced sample across the size range
python3 scripts/slim-measure.py --no-hash --no-png --cores-sample 8 --jobs 8 \
    --output cores.json --cache /tmp/slim-cache
```

`--cache` keeps per-file results between runs, so a slow host can resume with
`--limit N` instead of starting over. `--png-max-pixels` skips the handful of
multi-megapixel scans that cost minutes of deflate each (they are reported as
skipped, never guessed).

Cross-checks, independent of the script:

```sh
find . -path ./.git -prune -o -type f -print | wc -l            # 22948
find . -path ./.git -prune -o -type f -printf '%s\n' | awk '{s+=$1} END{print s}'
                                                                # 4310419594
du -sk --exclude=.git .                                         # 4189296 KiB
```

Measured on commit `9bd776b5` (branch `chore/gh-3-slim-measure`), 2026-10-18.

The worktree had to be widened first: it was a sparse checkout of a handful of
paths, so `Emus/`, `RetroArch/`, `Roms/`, `BIOS/`, `Themes/` and the rest were
absent until `git sparse-checkout add`. Numbers are only meaningful on the full
tree.

> The tree measured includes this tool (`scripts/slim-measure.py`, 53,567 bytes).
> `find` counts 22,948 files; the script's own inventory reports 22,947 because it
> skips the worktree's `.git` pointer file (59 bytes, not payload). Both are
> correct; only the second is payload-shaped.

---

## 2. Totals — MEASURED

| metric | bytes | human |
| --- | ---: | ---: |
| files | 22,948 | |
| apparent size (`st_size` sum) | 4,310,419,594 | 4.01 GiB |
| allocated on disk (`du -sk`) | 4,289,839,104 | 3.99 GiB |
| **payload** (what reaches the SD card) | 4,172,165,928 | 3.89 GiB |
| repository-only (deleted by packaging) | 138,253,666 | 131.8 MiB |

Payload = total minus `_assets/` (131.8 MiB), `.github/` (50 KiB), `LICENSE` and
`README.md` — the four paths `.github/scripts/release-manifest.sh` deletes with
its named transforms. `docs/` and `scripts/` are not deleted by any transform, so
they count as payload; together they are 137 KB and change nothing either way.

Apparent and allocated differ by only 20 MB (0.5%): the tree is mostly large
files, so the 4 KiB block rounding that inflates many-small-files trees is
irrelevant here.

---

## 3. Where the bytes live — MEASURED

| category | files | bytes | MiB | share |
| --- | ---: | ---: | ---: | ---: |
| `cores-extracted` — libretro cores, extracted | 160 | 1,002,705,628 | 956.3 | 23.3% |
| `emulators` — per-system emulator payloads | 1,763 | 828,590,636 | 790.2 | 19.2% |
| `apps` — applications | 1,473 | 551,425,023 | 525.9 | 12.8% |
| `system-runtime` — runtime libs and binaries | 662 | 388,962,685 | 370.9 | 9.0% |
| `retroarch` — frontend, assets, shaders | 11,321 | 383,522,192 | 365.8 | 8.9% |
| `artwork` — themes, icons, backgrounds | 5,941 | 301,750,468 | 287.8 | 7.0% |
| `vendor-trimui` — vendor surface | 69 | 167,753,571 | 160.0 | 3.9% |
| `cores-archives` — libretro cores, still .7z | 5 | 149,393,280 | 142.5 | 3.5% |
| `repo-only` — deleted by packaging | 50 | 138,253,666 | 131.8 | 3.2% |
| `bios` — BIOS/firmware dumps | 420 | 131,552,688 | 125.5 | 3.0% |
| `system-updates` — bundled update payloads | 10 | 111,624,831 | 106.5 | 2.6% |
| `best-packs` — Best collection | 81 | 72,784,474 | 69.4 | 1.7% |
| `roms` — bundled ROMs | 313 | 57,452,009 | 54.8 | 1.3% |
| `project-code` — scripts and configuration | 404 | 24,187,057 | 23.1 | 0.6% |
| `cores-metadata` — `.info` files | 273 | 400,665 | 0.4 | 0.0% |
| `root-files` — SD root metadata | 2 | 38,896 | 0.0 | 0.0% |

Two facts dominate everything that follows.

**Emulator cores alone are 23.3% of the tree.** One category, one decision
(`.so` vs `.7z`), worth more than every other idea in this document combined.

**Extracted cores plus core archives are 1,099 MiB — 26.7% of the payload**, and
the archives are *additional* cores, not stale copies. Their members are
`mame`, `mame2016`, `mame219`, `mess`, `scummvm`; the extracted set contains
`mame2015`, `mame2010`, `mess2015` and `scummvm-2.9`. Different builds: dropping
one does not replace the other.

### By content kind — MEASURED

| kind | files | MiB | share |
| --- | ---: | ---: | ---: |
| libretro core | 160 | 956.3 | 23.3% |
| data (`.dat`, `.rdb`, `.pat`) | 1,019 | 504.1 | 12.3% |
| archive (`.7z`, `.zip`, `.gz`) | 84 | 499.0 | 12.1% |
| image | 14,512 | 498.3 | 12.1% |
| ELF executable (extensionless) | 141 | 458.2 | 11.1% |
| font | 192 | 385.0 | 9.4% |
| shared library (`.so`, `.so.N`) | 399 | 262.1 | 6.4% |
| other | 1,029 | 201.3 | 4.9% |
| firmware (split `.7z.00N`) | 12 | 153.4 | 3.7% |
| audio | 279 | 84.6 | 2.1% |
| ROM data | 115 | 68.3 | 1.7% |
| configuration | 2,511 | 18.7 | 0.5% |
| shader | 1,436 | 13.7 | 0.3% |
| script | 1,059 | 7.8 | 0.2% |

Native code — cores, shared libraries and ELF executables — is **1,676 MiB, 41%
of the payload**. That is the structural fact this audit establishes: this is a
*binary* distribution with a UI on top, not an asset pack. Any cut that does not
touch native code fights over the remaining 59%.

### Largest single files — MEASURED

| file | MiB |
| --- | ---: |
| `trimui/firmwares/firmware_tsp_v1.1.1_20251128.7z.001` | 98.0 |
| `RetroArch/.retroarch/cores/mame2015_libretro.so` | 98.0 |
| `RetroArch/.retroarch/cores/scummvm_libretro-2.9.so` | 91.7 |
| `System/updates/update_001/python.zip` | 78.3 |
| `_assets/resources/python.zip` | 78.3 |
| `RetroArch/.retroarch/cores/fbneo_libretro.so` | 61.8 |
| `RetroArch/.retroarch/cores/mame2010_libretro.so` | 61.8 |
| `trimui/firmwares/firmware_tsp_v1.1.1_20251128.7z.002` | 52.8 |
| `RetroArch/.retroarch/cores/mess2015_libretro.so` | 48.5 |
| `Emus/ADVMAME/advmame` | 47.4 |
| `RetroArch/.retroarch/cores/mame219_libretro.7z` | 46.6 |
| `RetroArch/.retroarch/cores/fbalpha_libretro.so` | 44.5 |
| `System/sftpgo/sftpgo` | 43.1 |
| `System/bin/rclone` | 38.3 |
| `RetroArch/.retroarch/cores/same_cdi_libretro.so` | 36.6 |

---

## 4. Exact duplicates by sha256 — MEASURED

Every file in the tree was hashed. No sampling.

| metric | value |
| --- | ---: |
| duplicate groups | 1,840 |
| redundant files | 3,811 |
| wasted bytes, whole tree | 454,792,415 (433.7 MiB) |
| wasted bytes **inside the payload** | 371,583,274 (354.4 MiB) |

The headline misleads on its own, and the reason is a filesystem fact:

> **The payload filesystem is FAT.** The tree ships `System/bin/fsck.fat`, and the
> update scripts operate on `/dev/mmcblk0p1` — the SD partition. FAT32 has no
> hardlinks and no symlinks. Duplicate bytes cannot be reclaimed by linking: the
> only way to reclaim them is to *delete* a functional copy.

So 354.4 MiB is not a saving; it is an upper bound that is almost entirely
unreachable. What the duplicates show is a packaging pattern — self-contained
components — not waste:

| group | copies | MiB each | why the copies exist |
| --- | ---: | ---: | --- |
| `NotoSansSC-Regular.ttf` | 6 | 10.1 | each PortMaster theme is self-contained |
| `NotoSansTC/HK/KR/JP-Regular.ttf` | 6 | 5.5–6.8 | same |
| `font.ttf` (`Emus/NDS/drastic/resources/font/`) | 5 | 4.4 | per-emulator skin resource |
| `bgm2.mp3`, `bgm.mp3` (`Themes/Retro Genesis/sound/`) | 5–6 | 1.9–3.1 | per-theme audio |
| `jpn0.pgf` (PPSSPP asset) | 3 | 4.1 | three PPSSPP installs |
| `libSDL2-2.0.so.0.2600.1` (`Emus/NDS/drastic`) | 2 | 7.5 | one app ships the lib under two names |

One group *is* genuinely removable:

| group | copies | MiB | verdict |
| --- | ---: | ---: | --- |
| `python.zip` | 2 | 78.3 | `System/updates/update_001/` (payload) + `_assets/resources/` (repository-only), byte-identical `sha256 6547ff0f…`. Deleting the `_assets` copy costs nothing at runtime and trims 78.3 MiB from the **repository**, not the SD card. |

**Deduplication is not a lever here.** Reading "354 MB of duplicates" as a
354 MB saving would be wrong on a FAT device.

### Near duplicates: same name, size within 1%, different content — MEASURED

The dangerous ones: two builds of the same thing, both shipping.

| files | MiB each | note |
| --- | ---: | --- |
| `BIOS/scummvm/extra/fonts-cjk.dat` vs `Emus/SCUMMVM/ScummVM/extra/fonts-cjk.dat` | 36.5 | different sha256, identical size |
| `System/updates/portmaster_fix.7z` vs `_assets/resources/portmaster_fix.7z` | 26.6 | different sha256, 277 bytes apart — two builds of one patch payload |
| `BIOS/scummvm/extra/ultima.dat` vs `Emus/SCUMMVM/ScummVM/extra/ultima.dat` | 15.2 | *byte-identical* content, duplicated across two components |

The two SCUMMVM `extra/` trees were compared file by file: `BIOS/scummvm/extra`
holds 106 files / 107.5 MiB, `Emus/SCUMMVM/ScummVM/extra` holds 117 files /
77.0 MiB; 31 names appear in both with equal size, of which **30 are
byte-identical (15.2 MiB)** and **1 differs (`fonts-cjk.dat`, 36.5 MiB)**. So the
overlap is ~51.7 MiB concentrated in one divergent font, not a wholesale mirror.
Consolidating it needs a per-consumer path test (libretro ScummVM core vs
standalone ScummVM), which cannot be settled statically.

---

## 5. PNG lossless recompression — MEASURED SAMPLE / EXTRAPOLATED TOTAL

14,380 PNGs, 400,904,328 bytes (382.3 MiB, 400.9 MB), 9.6% of the payload.
Two independent samples were taken; both re-encoded at `optimize=True`,
`compress_level=9` without changing colour mode, and both are reported here
because they disagree and the disagreement is informative.

**Sample A — 80 files, random by file (seed 42), measured separately from this
script:** 3.76 MB → 3.22 MB, **14.4% smaller**. Extrapolated over the population
under a uniformity assumption: **~57.8 MB**.

**Sample B — 286 files, size-stratified (`--png-sample 200`), produced by
`scripts/slim-measure.py`:** 54.9 MiB of sampled bytes, 6.25 MiB saved (11.4%
overall), 24.5% of sampled files shrank at all, 4 undecodable, 4 skipped by the
pixel cap (22.4 MiB, 5.9% of PNG bytes). Per-band detail:

| size band | files | MiB | sampled | saving ratio | projected |
| --- | ---: | ---: | ---: | ---: | ---: |
| < 64 KB | 13,000 | 69.0 | 180 | 2.4% | 1.7 MiB |
| 64–256 KB | 1,059 | 128.7 | 40 | 3.3% | 4.3 MiB |
| 256 KB–1 MB | 295 | 129.5 | 40 | 11.0% | 14.2 MiB |
| ≥ 1 MB | 26 | 55.2 | 22 | 12.9% | 7.1 MiB |
| **total** | **14,380** | **382.3** | **286** | | **27.3 MiB (28.6 MB)** |

**Why they differ.** Sample B shows the ratio is strongly size-dependent: 2.4%
for the 13,000 tiny UI sprites, 11–13% for the few hundred large images. A
file-weighted random sample is dominated by that tiny-sprite band (90% of files,
18% of bytes), so a single uniform ratio cannot be right in both directions.
The honest answer is a range:

> **PNG lossless recompression recovers ~27–58 MB (27.3 MiB measured-projected to
> 57.8 MB uniform-extrapolated), i.e. 0.7%–1.4% of the payload.** The
> byte-weighted, size-aware figure (27.3 MiB) is the better estimate; the uniform
> figure (57.8 MB) is the optimistic bound.

Either way the conclusion is the same and it is the useful part: **PNG
recompression is a 1% lever, not a size-class change.** It is worth doing because
it is safe and mechanical, not because it fixes the distribution.

Verified claims: every file counted by Sample B was decoded again after
re-encoding and compared pixel-for-pixel; files whose mode or pixels would have
changed were not counted. Zero palette rewrites survived that check, so no
"savings" here depend on colour-model changes.

---

## 6. Junk, stale copies and per-device variants — MEASURED

### Junk

| reason | files | bytes |
| --- | ---: | ---: |
| editor/build leftover (`__pycache__/*.pyc`) | 1 | 1,987 |
| placeholder (`.gitkeep`) | 316 | 0 |
| **total** | **317** | **1,987** |

The tree is clean: no `.DS_Store`, no `Thumbs.db`, no `._*` AppleDouble, no log,
no `.bak`, no `.orig`, no stray `__pycache__` beyond one file
(`System/lib/python3.11/site-packages/modern_colorthief/__pycache__/`). Cleaning
it is worth 1,987 bytes — 0.00005% of the payload, not a commit.

357 files are zero-byte; 41 of them are not `.gitkeep`. Plumbing, no weight.

### Stale versioned copies of a shipped binary

| file | MiB | replaced by | referenced in code? |
| --- | ---: | --- | --- |
| `RetroArch/ra64.trimui-1.15.0` | 7.4 | `RetroArch/ra64.trimui` | no |
| `RetroArch/ra64.trimui-1.17.0` | 7.9 | `RetroArch/ra64.trimui` | no |
| `RetroArch/ra64.trimui-1.18.0` | 8.0 | `RetroArch/ra64.trimui` | no |
| `RetroArch/ra64.trimui-1.20.0` | 9.4 | `RetroArch/ra64.trimui` | no |
| **total** | **32.6** | | |

3,342 script/config files and 229 documentation files were scanned for
references. The live frontend is `RetroArch/ra64.trimui` (9.5 MiB, named by 161
launcher scripts); none of the four versioned copies appears in a script or
config. `1.15.0` and `1.20.0` are mentioned in `docs/emulators-matrix.md` as
*evidence* that version claims were checked, and the other two appear there in
shortened form (`-1.17.0`), which is why the `documented_only` flag is uneven
across the four. Deleting them removes the artifacts those claims were verified
against — a documentation decision as much as a size one.

### Versioned directories — measured, and *not* junk

| pair | variants | MiB | verdict |
| --- | --- | ---: | --- |
| PPSSPP | `Emus/PSP/PPSSPP_1.15.4`, `PPSSPP_1.17.1` | 115.2 | **user-selectable** — both listed in `Emus/PSP/config.json` `launchlist` |
| flycast | `Emus/DC/flycast_v1.0`, `flycast_v2.4` | 63.4 | **user-selectable** — both have launcher scripts |

178.6 MiB of "obvious duplicate versions" that must **not** be cut: they are menu
entries.

### Per-resolution assets — measured, and *not* junk

`Apps/BootLogo/Images_1280x720` (60.7 MiB) and `Images_1024x768` (49.8 MiB) both
ship and both are required. `Apps/BootLogo/launch.sh` branches on
`/etc/trimui_device.txt`, and `System/starts/_FirmwareCheck.sh` derives `tsp`
(1280x720) versus `brick` (1024x768) from `fbset`. One tree serves two devices;
dropping either resolution breaks boot-logo flashing on that device.

This corrected an early assumption of mine: CrossMix-OS SE is not a
TrimUI-Smart-Pro-only distribution, and the 1024x768 assets are live.

---

## 7. Cores: `.so` versus `.7z` — MEASURED SAMPLE / EXTRAPOLATED TOTAL

### What the tree already proves — MEASURED

The five core archives are compressed with the release's own settings. Members
read with `7z l -slt`:

| archive | member | packed | uncompressed | smaller by |
| --- | --- | ---: | ---: | ---: |
| `mame_libretro.7z` | `mame_libretro.so` | 26.9 | 196.6 | 86.3% |
| `mame2016_libretro.7z` | `mame2016_libretro.so` | 22.2 | 146.2 | 84.8% |
| `mame219_libretro.7z` | `mame219_libretro.so` | 46.6 | 269.0 | 82.7% |
| `mess_libretro.7z` | `mess_libretro.so` | 23.9 | 156.9 | 84.8% |
| `scummvm_libretro.7z` | `scummvm_libretro.so` | 22.9 | 102.0 | 77.6% |
| **total** | | **142.5** | **870.7** | **83.6%** |

### What a sample of the extracted cores shows — MEASURED

Six cores spread evenly across the size range, `7z a -t7z -mx=7` into scratch:

| core | MiB | packed | smaller by |
| --- | ---: | ---: | ---: |
| `mame2015_libretro.so` | 98.0 | 16.1 | 83.6% |
| `vice_xscpu64_libretro.so` | 3.9 | 0.8 | 78.9% |
| `fuse_libretro.so` | 2.1 | 0.5 | 73.6% |
| `snes9x2005_libretro.so` | 0.8 | 0.2 | 79.9% |
| `o2em_libretro.so` | 0.3 | 0.1 | 70.2% |
| `mpv_libretro.so` | 0.05 | 0.02 | 66.6% |
| **total** | **105.1** | **17.8** | **83.1%** |

### The saving — EXTRAPOLATED

| basis | ratio | applied to | projected saving |
| --- | ---: | ---: | ---: |
| 5 in-repo archives (870.7 MiB uncompressed) | 83.6% | 956.3 MiB of extracted cores | 799 MiB |
| 6-core sample (105.1 MiB, byte-weighted) | 83.1% | 956.3 MiB of extracted cores | 795 MiB |

**≈ 795 MiB off a 4.01 GiB payload — 19.4% of the whole tree, from one
decision.** The two independent bases agree within 0.5 points, so the
extrapolation is not fragile: the ratio is a property of ARM code, not of which
core you pick. The sample is byte-dominated by `mame2015` (98 of 105 MiB);
per-core ratios for small cores (67–80%) are lower but contribute almost nothing
to the total.

### What it costs — partially measured

Shipping cores compressed means something must unpack them, once, on first boot:

* `System/bin/7zz` is **already in the payload** (2.3 MiB) — the tool exists.
* The release workflow currently extracts archives at *packaging* time
  (`.github/scripts/release-manifest.sh` → `extract-core-archives`). The change
  inverts that: ship `.7z`, unpack on device.
* **Decompression, measured on this host:** `mame2015_libretro.so`, 98.0 MiB,
  extracted in 2.87 s = **34.1 MB/s**. The whole 956 MiB core set would unpack in
  roughly half a minute here.
* **On-device speed: NOT MEASURED.** An ARM A53 reading SD flash is slower, and
  that number — not the host number — should set the risk. It is a first-boot,
  one-time cost either way.
* Failure mode: a partially extracted directory leaves cores that fail to load —
  visible, not silent. Mitigation is an idempotent first-boot step with a marker
  file, the pattern `System/updates/update_001.sh` already uses
  (`/etc/ex_update/$UPDATE_ID`).
* Update bandwidth improves too: an OTA touching one core currently ships 98 MiB;
  compressed it ships ~16 MiB.

An intermediate option exists and should be evaluated first: keep cores extracted
but drop the five `.7z` archives (142.5 MiB). Those archives are different builds,
so this only works if those five systems are being retired.

---

## 8. Firmware — MEASURED

| item | bytes | MiB |
| --- | ---: | ---: |
| `trimui/firmwares/firmware_tsp_v1.1.1_20251128.7z.001` | 102,760,448 | 98.0 |
| `trimui/firmwares/firmware_tsp_v1.1.1_20251128.7z.002` | 55,340,257 | 52.8 |
| **total** | **158,100,705** | **150.8** |

`MinFwVersion.txt` declares `1.1.1` / `20251128`. Stock firmware carried for the
in-app update path: already `.7z`, so no further compression, and it cannot be
dropped without removing the firmware-update feature. Treated as untouchable.

---

## 9. The five cuts, ranked by gain over risk

Ranked by bytes reclaimed ÷ chance of breaking something. Numbers are the
measured or extrapolated figures above.

### 1. Ship libretro cores as `.7z`, unpack on first boot — **≈795 MiB, 19.4% of the payload**

The only cut that changes the size class of the distribution. Ratio measured two
independent ways (§7). Risk is real but bounded: `7zz` already ships, the
first-boot pattern already exists in `System/updates/`, decompression is fast even
on the host, and failure is visible (cores fail to load) rather than silent.
Blocking question: on-device extraction time. **Do this first; everything else is
rounding error next to it.**

### 2. Drop the four stale `ra64.trimui-1.*` binaries — **32.6 MiB, low risk**

Verified unreferenced across 3,342 scripts/configs; the live binary is
`RetroArch/ra64.trimui`. Only cost: `docs/emulators-matrix.md` cites them as
evidence, so the doc needs the hashes recorded when they go. Clean enough for its
own PR.

### 3. Resolve the SCUMMVM `extra/` duplication — **36.5 MiB divergent + 15.2 MiB identical, medium risk**

`BIOS/scummvm/extra` (107.5 MiB) and `Emus/SCUMMVM/ScummVM/extra` (77.0 MiB)
share 31 names; 30 are byte-identical and `fonts-cjk.dat` (36.5 MiB) diverges.
One tree is presumably canonical. Needs a ScummVM smoke test on both paths;
blast radius is user-visible (text rendering), which is why it ranks below §2
despite being bigger.

### 4. Lossless PNG re-encode — **27–58 MB (0.7%–1.4%), low risk, medium effort**

Mechanical and verified pixel-identical, no behaviour change. Costs a packaging
step; PNGs cannot be re-derived on device, so it is a one-way transform — but a
safe one. Worth doing last, and not because it fixes anything.

### 5. Remove the repository-only `python.zip` duplicate — **78.3 MiB of repository, 0 of payload**

Free and safe: `_assets/resources/python.zip` is byte-identical to
`System/updates/update_001/python.zip` and never ships. It does not shrink the SD
image; it stops the *repository* carrying 78 MiB and removes the risk of the two
copies drifting.

The payload copy is **not** redundant. The tree ships `System/bin/python3.11` and
`System/lib/python3.11/site-packages` but **no Python standard library** — no
`os.py` exists anywhere in the tree. The stdlib lives only inside `python.zip`
(9,791 members, 236.8 MiB unpacked) and is extracted on first boot by
`update_001.sh`. Removing it would ship a Python that cannot start.

### Explicitly *not* recommended

| idea | why not |
| --- | --- |
| Deduplicate the 1,840 sha256 groups (354 MiB) | FAT has no hardlinks or symlinks; reclaiming means deleting functional copies |
| Drop `BootLogo/Images_1024x768` (49.8 MiB) | required for the `brick` variant, selected in `launch.sh` |
| Drop PPSSPP 1.15.4 or flycast 1.0 (178.6 MiB) | both are `launchlist` entries; cutting removes user-visible options |
| Purge junk | 1,987 bytes total |
| Drop the 5 core `.7z` (142.5 MiB) | different builds from the extracted cores |
| Remove locale files (`.mo`, `System/share/locale`) | 2.0 MiB over 38 languages; selection happens at runtime inside the frontend binary, so non-use cannot be proven statically — and 2 MiB is not worth the argument |

---

## 10. What this audit did not establish

Stated plainly rather than guessed:

* **On-device extraction speed** for compressed cores (ARM A53 + SD flash). The
  34.1 MB/s host figure is not transferable, and §7's risk assessment turns on it.
* **Which `fonts-cjk.dat` build is canonical.** Contents differ; the tree does not
  say.
* **Whether the five core `.7z` represent systems still on offer.** Different
  builds, but no inventory maps them to menu entries.
* **Per-file PNG results for all 14,380 images.** Both figures are sample-based;
  §5 gives the range and the reason the two samples disagree.
* **Runtime behaviour of anything.** No payload binary was executed, by design.

---

*Generated with `scripts/slim-measure.py` (read-only). Regenerate the tables with
the commands in §1; every number above came from one of those runs.*

# Emulator and core matrix (GH#6)

Evidence-backed inventory of every emulator entry under `Emus/` and every core
artifact under `RetroArch/.retroarch/cores`, generated from the repository itself
by `scripts/emu-inventory.sh`.

The point of this file is not to know *which versions exist upstream*. It is to
separate three different things that are routinely confused:

1. what the repository **declares** (`.info` metadata, `config.json`, a shipped
   licence file);
2. what can be **verified statically** from the shipped binary (build strings,
   ELF notes) without executing it;
3. what is simply **unknown** until someone consults the upstream project and
   records the source and the date.

Anything that is not (1) or (2) is reported as `UNKNOWN`, never guessed.

- Repository: `CrossMix-OS-SE`, branch `feat/gh-6-emu-matrix`
- Commit measured: `35d557b` (2026-10-18)
- Data files: `docs/emulators-inventory.tsv`, `docs/cores-inventory.tsv`,
  `docs/emulators-summary.tsv`
- Generator: `scripts/emu-inventory.sh` (POSIX `sh`, read-only)

## How to reproduce

```sh
/bin/busybox sh -n scripts/emu-inventory.sh          # syntax check
./scripts/emu-inventory.sh -t emus    > docs/emulators-inventory.tsv
./scripts/emu-inventory.sh -t cores   > docs/cores-inventory.tsv
./scripts/emu-inventory.sh -t summary > docs/emulators-summary.tsv
```

Requirements: `sh`, `awk`, `sed`, `grep`, `ls`, `wc`, `tr`, `cut`, `dirname`.
`git` is optional and only used to read the committed tree (`HEAD:path`), so the
counts stay correct in a sparse checkout where blobs are not materialised.
Runtime on the reference host: ~19 s for the emulator table, ~4 s for the cores
table. The script never executes a shipped binary, never downloads anything and
never writes outside stdout.

## Measured counts

Generated with `./scripts/emu-inventory.sh -t summary` (paste of the real run):

| metric | value |
| --- | --- |
| `Emus/` directories | 112 |
| directories with `config.json` | 112 |
| underscore-prefixed utility dirs (`_BootLogo`, `_Scraper`, `_SystemTools`) | 3 |
| **emulator entries** | **109** |
| rows whose only engine is RetroArch | 88 |
| rows that reference RetroArch (alone or with a standalone build) | 101 |
| rows that reference a standalone binary | 22 |
| rows where no engine could be resolved from the launchers | 2 |
| rows with a declared version | 100 |
| rows with no declared version (`UNKNOWN`) | 12 |
| rows with a declared licence | 102 |
| rows with no declared licence (`UNKNOWN`) | 10 |
| rows whose every referenced artifact is in `HEAD` | 109 |
| rows with at least one referenced artifact absent from `HEAD` | 1 (MSX) |
| rows whose payload only exists inside a `.7z` | 3 |
| core `.so` files | 160 |
| core `.7z` archives | 5 |
| core `.info` files | 270 |
| files with no extension in `cores/` | 3 |
| core artifacts referenced by an `Emus/` launcher | 107 |
| referenced cores that ship only as `.7z` | 4 |

Derived facts that matter for any update decision:

- 119 `.info` files have **no** matching `.so` (metadata for cores this build does
  not ship), and 9 `.so` files have **no** `.info`. Metadata alone is therefore
  not a component list.
- 58 of the 165 core artifacts are referenced by no `Emus/` launcher at all.
- The 5 core archives are `mame`, `mame2016`, `mame219`, `mess`, `scummvm`. The
  four referenced-but-absent cores are `mame`, `mame2016`, `mame219`, `scummvm`:
  the launcher points at `<name>_libretro.so`, the repo ships `<name>_libretro.7z`.
- `RetroArch/` carries five frontend binaries: `ra64.trimui` plus
  `ra64.trimui-1.15.0`, `-1.17.0`, `-1.18.0`, `-1.20.0`. All 161 references in
  `Emus/` and `System/` use the unversioned `ra64.trimui`; no launcher in the
  materialised tree references a versioned one.

## Baseline comparison (ticket text vs. this run)

| baseline claim | this run | verdict |
| --- | --- | --- |
| 109 Emus | 112 dirs, 3 of them utilities → **109 emulator entries** | matches |
| 160 `.so` | 160 | matches |
| 5 `.7z` | 5 | matches |
| 270 `.info` | 270 | matches |
| 3 files without extension | 3 (`Makefile`, `COPYING`, `configure`) | matches |
| "287 engines" | 165 core artifacts + 22 standalone binaries; no set of 287 components exists | not reproducible |
| versions not inferable from folder names | confirmed; see "Names are not evidence" | matches |

The 112-vs-109 difference is not drift: `Emus/_BootLogo`, `Emus/_Scraper` and
`Emus/_SystemTools` are app-like entries that live under `Emus/` and have a
`config.json`, but they are not emulators. Counting directories rather than
entries is exactly how a baseline ends up disagreeing with itself.

## What is accredited, and what is not

### Accredited (written in the repository)

- **Core version** — `display_version` in `<core>.info`. 100 of 112 rows resolve
  a version this way. Examples: `snes9x_libretro` → `1.61`, `puae2021_libretro`
  → `v2.6.1`. Where a row references several cores with different versions, the
  cell lists every distinct value (`SVN|6.0`), so a mixed row is visible instead
  of being flattened to one number.
- **Core licence** — `license` in `<core>.info`. 102 rows resolve a licence this
  way. Values are the upstream strings, not normalised: `GPLv2`, `GPLv3`,
  `Non-commercial`, `MAME`, `MIT`, `CC BY-NC 3.0 US (Non-commercial)`, …
- **Standalone licence, only when a licence file ships in-tree** —
  `Emus/N64/mupen64plus/doc/LICENSES-mupen64plus-*` is the single case
  (`N64DD`). The script records the directory and file names, not an
  interpretation.

### Not accredited

- **Version of any standalone emulator.** `config.json` carries menu labels, not
  release metadata. 12 rows are `UNKNOWN`, 9 of them real emulators:
  `ADVMAME`, `JAVA`, `N64DD`, `NDS` (Drastic), `OPENBOR`, `PORTS`, `PSP`
  (PPSSPP), `PSPMINIS`, `UZEBOX`. `UZEBOX` is `UNKNOWN` even though it runs a
  core, because `uzem_libretro.info` has no `display_version`.
- **Licence of every standalone emulator except N64DD.** PPSSPP, Drastic,
  Java/Zulu, OpenBOR, AdvanceMAME: no `LICENSE`/`COPYING`/`NOTICE` file is
  shipped next to the binary. The repo is GPL-3.0; a 16 MB stripped PPSSPP
  binary distributed without its licence text is a compliance gap that this
  matrix makes visible rather than hides. `UNKNOWN` here means "not evidenced
  by this repository", not "unlicensed".
- **RetroArch's own version, from metadata.** No file in the repo declares it.
  It is only obtainable by static inspection (below).
- **Whether any binary was built from the upstream tag its name suggests.**
  Not provable without a reproducible build or a published checksum.

## Names are not evidence

A version-shaped token in a *path* is a label someone typed. It is not a
declaration and it is not proof. The script never reads a version out of a
directory name, and `docs/emulators-inventory.tsv` records such tokens only in
the `notes` column, suffixed `(not evidence)`.

Three real cases from this tree:

| name | what it looks like | what it proves |
| --- | --- | --- |
| `Emus/PSP/PPSSPP_1.17.1/` | "PPSSPP 1.17.1" | nothing. The folder could hold any build. The matrix reports `version_declared=UNKNOWN` for `PSP` and lists `1.17.1`/`1.15.4` as name hints. |
| `Emus/NDS/drastic/drastic_2.5.2.2` | "Drastic 2.5.2.2" | nothing. `NDS` stays `UNKNOWN`. |
| `RetroArch/ra64.trimui-1.20.0` | "RetroArch 1.20.0" | nothing *by itself* — but here the name was checked against the binary and matched (see below). Verified, not assumed: that is the difference. |

The same rule applies to the `launchlist` names in `config.json`
("PPSSPP 1.17.1 - OpenGL"): menu text, mapped to a script name in the
`launcher_scripts` column, never to a version.

## Verifying an upstream without executing the binary

Procedure, per component. It produces an auditable row: source, retrieval date,
declared version, upstream tag/commit.

1. **Identify the project.** Use `<core>.info` (`display_name`, `authors`,
   `corename`) for cores; for standalones use the launcher (`emulator` column)
   plus the shipped tree. Record the upstream repository URL.
2. **Read the binary statically.** `strings` and `readelf` read bytes; they do
   not run the ARM payload. Only accept *anchored* strings — a version next to a
   product name or in a known log format — never a bare `x.y.z`:

   ```sh
   strings -a RetroArch/ra64.trimui | grep -oE '\[INFO\] Version: [0-9.]+' | head -1
   # [INFO] Version: 1.21.0
   readelf -p .comment RetroArch/ra64.trimui
   readelf -n RetroArch/ra64.trimui | grep 'Build ID'
   # Build ID: 9f9a892b7bc44ef8f63ad040655346c186da4c81
   ```

   Why the anchor matters: the same binary also contains a bare `1.21.0` next to
   the `glslp`/`slangp` preset strings, and a `1.2.8`. Grepping `[0-9]+\.[0-9]+`
   and stopping at the first hit would have "found" the wrong number. The
   `[INFO] Version:` form is RetroArch's own startup log line, so it is
   attributable to the frontend.
3. **Consult upstream, and write down when.** Fetch the release notes or the tag
   list, note the release date and the tag. One component is already done:

   | component | declared in repo | static check | upstream source | retrieved | upstream date | verdict |
   | --- | --- | --- | --- | --- | --- | --- |
   | RetroArch frontend `RetroArch/ra64.trimui` | `UNKNOWN` (no metadata file) | `[INFO] Version: 1.21.0` | https://www.retroarch.com (news), https://www.libretro.com/index.php/retroarch-1-21-0-release | 2026-10-18 | 2025-04-29 | static version matches a real upstream release |

   Every other row is **pending** and stays `UNKNOWN` in the matrix until it has
   the same four fields (source, retrieved, upstream date, verdict). Do not fill
   a row from memory.
4. **Compare against what ships.** Same name ≠ same build: only a published
   checksum, a reproducible build, or a `Build ID` recorded upstream closes that
   gap. Until then the honest cell is "version verified, provenance of the build
   unverified".
5. **Record the row** in the table with the values above. A row without a date is
   not evidence, it is an opinion.

### Checking a versioned frontend binary

The dated `ra64.trimui-*` files were checked the same way rather than trusted:

```sh
strings -a RetroArch/ra64.trimui-1.20.0 | grep -oE '\[INFO\] Version: [0-9.]+'  # 1.20.0
strings -a RetroArch/ra64.trimui-1.15.0 | grep -oE '\[INFO\] Version: [0-9.]+'  # 1.15.0
```

The names happen to be truthful. They still had to be checked, and the check —
not the filename — is what goes in the matrix.

## Columns

`docs/emulators-inventory.tsv` (one row per `Emus/*/config.json`, 112 rows):

| column | meaning |
| --- | --- |
| `emu` | directory name under `Emus/` |
| `label` | `label` from `config.json` |
| `config_launch` | `launch` from `config.json` (the default script) |
| `launcher_count` | scripts reachable for this entry (`launch` + `launchlist[].launch` + `launch.sh` fallback) |
| `launcher_scripts` | those script names |
| `engines` | `retroarch`, `standalone`, `retroarch+standalone`, or `none` |
| `binaries` | repository paths actually invoked; `archive:<path>` when the payload ships compressed; `MISSING:<path>` when the launcher points at a path that is not in the tree |
| `bin_in_head` | `yes` / `partial(n/m)` / `no` — presence in the committed tree, i.e. in the distribution |
| `bin_on_disk` | same, for this working copy (differs in a sparse checkout; that is a checkout artifact, not a repo defect) |
| `version_declared` | distinct declared versions, `|`-joined, or `UNKNOWN` |
| `version_source` | `info:<core>.info` / `config:label` / `none` |
| `license_declared` | distinct declared licences, `|`-joined, or `UNKNOWN` |
| `license_source` | `info:<core>.info` / `file:<dir>` / `none` |
| `notes` | name hints explicitly marked `(not evidence)`, missing scripts, cross-folder launchers |

`docs/cores-inventory.tsv` (165 rows): `core_file`, `display_name`,
`display_version`, `license`, `referenced_by_count`, `referenced_by` (emulator
ids), `info_file` (yes/no), `present_in_head`, `present_on_disk`.

## Limits of the static parser

The script reads shell text, so it inherits the ambiguity of shell text. Known
limits, all of which fail towards `MISSING`/`UNKNOWN` rather than towards a
guess:

- `cd` is followed only when the target is a literal or a variable assigned to a
  literal in the same file. `cd $(dirname "$0")/x` is not resolved.
- Paths containing spaces are skipped, so `Emus/PICO/Pico8 Wrapper.sh` and
  `aplay ".../Background Scraping Finished.wav"` never appear as engines.
- Launchers living in another emulator's folder are not harvested into the
  current row (they belong to their own row); the row gets a
  `launcher(s) in another folder:` note instead. `Emus/MSX/openmsx.sh` is the
  real case: it runs the payload shipped under `Emus/MSX2/`, which is why `MSX`
  shows one `MISSING:` path that an operator would find on the card only after
  first-run extraction.
- A payload that only exists inside a `.7z` is reported as `archive:` only when
  the extraction target can be parsed from the launcher (`7zz x ... -o...`).
- Directories are excluded via `git cat-file -t HEAD:<path>`, so `Apps/Scraper`
  or `lib/` cannot be mistaken for executables.

## Update policy this matrix is meant to serve

Update a component only when an improvement is demonstrated, never because a
newer version exists:

1. the current row shows a concrete defect (bug, crash, regression, missing
   feature the product needs) — with a reproduction;
2. the candidate version is verified per the procedure above (source + date +
   version + checksum or build id);
3. the change is measured (frames, load time, memory) or covered by a
   test/reproduction that fails before and passes after;
4. the licence of the replacement is accredited **before** it is shipped, not
   after;
5. the matrix row is updated in the same change, with the new evidence.

A pull request that only bumps a binary without (1)–(5) has no basis in this
document, and `UNKNOWN` in a cell is a fact to be filled, not a gap to be
plausibly filled in.

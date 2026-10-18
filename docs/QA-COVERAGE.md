# QA coverage matrix (GitHub #7)

**Branch:** `docs/gh-7-qa-matrix`, based on `main` @ `9bd776b5`.
**Scope:** what is actually verified in this repository today, what is only verified by
hand on a TG5040, and which of the unverified paths can damage a real console.

**Why this document exists:** there is no test framework. Verification has lived in
throw-away harnesses under `/tmp` (an OTA sandbox with stub `curl`/`wget`/`7zz` and a
fake `/mnt/SDCARD` tree was used while fixing #29 and #36), so the evidence disappeared
with the session. Nothing in the repo said which paths had been exercised.

**Evidence convention.** `FACT` = observed in this tree by the command cited. `MANUAL` =
only reachable on hardware, no run recorded in the repo. A cell is `COVERED` only when a
committed artifact asserts the behaviour and is run by someone or something on every
change; `PARTIAL` = an artifact exists but covers a slice; `NONE` = no artifact.

> Sparse worktree note: this branch checks out `docs/`, `.github/`, `Apps/SystemTools`,
> `System/`, `_assets/`, `scripts/` and `trimui/firmwares`. Scripts outside those paths are
> counted by `git ls-files` but not parsed locally. `FACT` (see `shell-syntax` output:
> 115 parsed, 1125 not materialised).

---

## 1. What verification exists today

| Artifact | What it proves | What it does not prove |
| --- | --- | --- |
| `.github/scripts/tests/release-manifest-test.sh` (206 lines, 30 assertions) | The manifest generator emits the right files, digests, exclusions, surface rules and byte-identical output for a pinned timestamp, on a throw-away tree. `FACT`: `sh .github/scripts/tests/release-manifest-test.sh` → `manifest fixture: all checks passed`. | Anything about the console. Anything about the OTA chain. Nothing runs it automatically. |
| `.github/workflows/CrossMix Release.yml` step *Validate firmware payload consistency* (lines 49–59) | `MinFwVersion.txt` names a payload that exists as `.7z.001`. | That `.002` exists, that the parts are complete, that the archive tests clean, that the CRC matches after extraction. |
| `sha256sum`/`jq -e .` calls inside that workflow (lines 156–157) | The published manifest is valid JSON. | That it describes the archive that was uploaded (the manifest is generated *after* packaging, from the workspace, so it can). |
| **`scripts/qa/run.sh`** (added by this branch) | The 12 smoke cases listed in section 4, including two defects it currently reports. | Everything marked `NONE`/`MANUAL` below. |
| Manual runs by maintainers | Recent PRs (#40, #41, #42) describe device checks in prose. | No log, screenshot, serial number or version stamp is stored, so they are not reproducible evidence and are marked `MANUAL` throughout. |

**No CI job runs any test.** `FACT`: the workflow triggers on `push: tags: v*` only, and
its twelve steps are checkout → version → 7-Zip → record inputs → extract cores → firmware
payload name check → hotfix manifest → cleaning → packaging → release → manifest →
upload. There is no `pull_request` trigger, no `sh -n`, no shellcheck, no invocation of
`release-manifest-test.sh`. A PR can therefore merge with a script that does not even
parse; the first execution is the tag build.

**No harness is committed by this branch's parent.** `FACT`: `.github/scripts/tests/`
contains exactly one file, and it is the only executable test in the repository — every
other path matching `*test*` is a theme asset, a vendored PortMaster library or a binary.

---

## 2. Coverage matrix

Legend: **U** = shell-unit (pure functions, fixtures), **I** = integration with stubs
(fake SD tree, canned HTTP/JSON, fake binaries), **H** = hardware (TG5040 + real SD).
`MANUAL` in the H column means "only a human on a device can tell, and no run is recorded".

| # | Area (entry points) | U | I | H | Evidence / citation |
| --- | --- | --- | --- | --- | --- |
| 1 | **OTA chain driver & exit-code contract** — `ota_update.sh:133-184`, `update_common.sh:5-41,109-123` | NONE | NONE | MANUAL | Contract is documentation only. `ota_run_logged` (the pipe-status trick that #29 depends on) has no test; `report_failure` wording is unchecked. |
| 2 | **Bootstrap self-refresh** — `_assets/scripts/ota_bootstrap.sh:10-79` | NONE | NONE | MANUAL | Replaces `update_common.sh` + 6 scripts from `raw.githubusercontent.com` on every run. Untested by construction: it rewrites the code under test. |
| 3 | **Version comparator** — `update_common.sh:342-392` | COVERED | — | — | `scripts/qa/run.sh` case `version-compare`: 17 rows of ordering and rejection (equal, `dev`, `ce.N.M`, 4-component, 1000-range overflow, `-ce`, `-ce.x`, empty, `1.4`). |
| 4 | **Release discovery** — `update_ota_release.sh:81-157` | NONE | PARTIAL | MANUAL | `release-asset-selection` asserts exactly one image candidate from a 4-asset release payload (green since #44). No fixture covers the `releases/latest` 404 path or the missing-`size` guard at `:106-113`. |
| 5 | **Download + size verification** — `download_file` (`update_common.sh:275-340`), `check_update` (`update_ota_release.sh:188-204`) | NONE | NONE | MANUAL | Verification is *length equality only* (`:196`); no digest, no archive test before `reboot`. Nothing tests the `_tmp` rename or the free-space pre-check. |
| 6 | **Staging + reboot** — `update_ota_release.sh:206-249` | NONE | NONE | MANUAL | The `success` marker (`:235`) is the only signal the UI trusts. Untested: partial `mv`, missing `crossmix_update.sh` download, `reboot` on a console with no update actually staged. |
| 7 | **Boot installer** — `crossmix_update.sh:10-402` | NONE | NONE | MANUAL | Moves `System/` etc. into `_Updates/Backup_*` (`:96-100`) *before* extracting (`:110-114`). No staging, no rollback beyond `crossmix-version.txt` (`:128-136`). Save/state migration (`:150-259`) is entirely untested. |
| 8 | **Staged-zip detection at boot** — `System/starts/_FirmwareCheck.sh:289-340` | NONE | NONE | MANUAL | Version gate is `tr -d '.' | -gt` (`:298`), which cannot parse the CE version strings this project ships (section 6, D2). |
| 9 | **Hotfix apply** — `_assets/hotfixes/CrossMix-OS_v1.4.0-ce.2.sh:36-152` | NONE | PARTIAL | MANUAL | `hotfix-zip-vs-tree` + `hotfix-zip-coverage` prove the committed zip matches the tree and ships every file `build-hotfix-zip.sh` lists (9/9). Application itself (`7zz x -aoa` straight onto `/mnt/SDCARD`, `:64`) is untested and non-atomic. |
| 10 | **Hotfix version gate** — hotfix `:26,45-50` | NONE | NONE | MANUAL | A *second*, independent comparator (`version_num`, digit-padding via `sed`/`awk`) instead of `cmp_crossmix_versions`. No test; see section 5, G6. |
| 11 | **Favourites guard** — `favorites_guard.sh` (211 lines) | COVERED | COVERED | MANUAL | 5 cases: healthy file untouched byte-for-byte, corrupt line dropped + verified backup, missing launcher dropped, absent file = no writes, unusable `jq` = no writes + logged. Boot hook (`°customization.sh:207-216`, `timeout 120`) itself is untested. |
| 12 | **Firmware update menu** — `Apps/SystemTools/Menu/TOOLS/Firmware Update.sh` | NONE | NONE | MANUAL | 173 lines: version read (`:49-52`), payload fallback (`:75-79`), 158 MB download with retries (`:107-135`), `awimg` extraction (`:144-162`). All device/network. |
| 13 | **Firmware minimum + payload selection** — `_FirmwareCheck.sh:24-282` | NONE | PARTIAL | MANUAL | CI checks the *filename* only (workflow `:49-59`). CRC32 check (`:37-60`), "newest bundled payload" fallback (`:157-171`) and busybox replacement (`:112-151`) are unverified; `:242` contains a swallowed branch (D3). |
| 14 | **Menu cache rebuild** — `Apps/SystemTools/launch.sh:47` | NONE | NONE | MANUAL | The mechanism the #42 hotfix relies on to make the restored entry visible (`.cache_stamp` mtime + `find -newer`). One typo here and the entry stays invisible with no error. |
| 15 | **Release manifest** — `.github/scripts/release-manifest.sh` + its test | — | COVERED | — | 30 assertions, `FACT` run locally. Not wired into CI, so it is COVERED as an artifact and **not** COVERED as a gate. |
| 16 | **Update notifier** — `update_notification.sh` (233 lines) | NONE | NONE | MANUAL | Strictest asset matcher in the tree (`:71-93`), but zero fixtures; its version of "which asset is the image" diverges from area 4 (a third behaviour). |
| 17 | **Boot customisation hook** — `System/starts/°customization.sh` | NONE | NONE | MANUAL | Runs `favorites_guard` and restores FW settings; `:156` has the same swallowed-branch defect as D3. |

Areas 1–2 and 5–8 are the update path a user hits from **Check Update**: none of them has
an off-device test, and the two that do (4, 9) currently fail or are partial.

---

## 3. Areas that can only be validated on hardware

Ordered by how expensive the failure is:

1. **Full-image install and boot** (areas 6–7): 4+ minute extraction on FAT32, then the
   console must boot the new tree. Nothing in CI can emulate the 32-bit address space,
   the FAT directory churn or the `/sys` cpufreq writes.
2. **Firmware flash** (areas 12–13): `awimg` on the SD root + VOL−/POWER. A wrong payload
   is recovery-only. `docs/FIRMWARE-UPDATE.md` documents the manual procedure; the repo
   states, correctly, that auto-flash is not accredited.
3. **Hotfix application on a live SD** (area 9): `7zz x -aoa` overwrites files in place
   while MainUI may be running from them.
4. **MainUI's own parse of `favourite2.json`** (area 11): the guard's contract is
   "MainUI stays bootable", which only MainUI can confirm.
5. **Menu cache rebuild** (area 14) and **boot hook ordering** (`°customization.sh`).
6. **Wi-Fi preconditions**: `check_connection`, `enable_wifi` and the fsck prompt
   (`update_common.sh:125-234`) behave differently on a captive portal, a card with
   `FSCK*.REC` files or a full card.

---

## 4. Mini-harness: `scripts/qa/run.sh`

Added by this branch: 495 lines, POSIX sh, driven by `busybox sh` when busybox is present
(the console's shell, so bash-only constructs fail here instead of on the device). The
harness itself parses and runs under both dash and ash. No network, no writes outside
`$TMPDIR`, device paths injected through the variables the scripts already expose
(`SDCARD`, `FAVORITES_ROMS_DIR`, `FAVORITES_BACKUP_DIR`, `FAVORITES_LOG_FILE`, `JQ`).

```sh
sh scripts/qa/run.sh            # 12 cases; known defects reported, run stays green
sh scripts/qa/run.sh --strict   # known defects fail the run (release gate)
sh scripts/qa/run.sh --list     # case ids
```

| Case | Asserts |
| --- | --- |
| `shell-syntax` | Every tracked `*.sh` parses under `busybox sh -n`. |
| `sh-lint-if-test-flag` | No `if -f ...` / `if -n ...` (runs a command named `-f`, exit 127, branch silently skipped). |
| `version-compare` | 17-row table over `cmp_crossmix_versions`: ordering (`1.4.0 < 1.4.0-ce.1 < 1.4.0-ce.2.9 < 1.4.0-ce.2.10 < 1.4.1`), 4-component bases, and rejection of `""`, `1.4`, `1.4.0-`, `1.4.0-ce`, `1.4.0-ce.x`, `1.4.1000`, `1.4.0-ce.2.3.4`. |
| `favorites-guard-healthy` | Valid NDJSON + existing launchers → exit 0, bytes unchanged, no backup. |
| `favorites-guard-corrupt` | One unparsable line → exit 0, 1 line kept, original copied to `System/backups`. |
| `favorites-guard-missing-launch` | Entry pointing at a missing `.launch` is dropped, live entry kept. |
| `favorites-guard-absent` | No `favourite2.json` → no writes, exit 0. |
| `favorites-guard-no-jq` | `JQ=/bin/false` on a *corrupt* file → no repair, no backup, `jq unusable` logged (proves the guard cannot empty a list it cannot read). |
| `release-asset-selection` | The asset filter parsed out of `update_ota_release.sh` selects exactly one image from a realistic 4-asset release payload. |
| `hotfix-zip-vs-tree` | All 9 committed hotfix-zip members are byte-identical to the working tree. |
| `hotfix-zip-coverage` | Every path in `build-hotfix-zip.sh`'s `FILES` list is present in the zip. |
| `release-manifest-fixture` | Delegates to `.github/scripts/tests/release-manifest-test.sh` and requires all 30 assertions. |

Real output on this branch (`sh scripts/qa/run.sh --strict`, exit 1 — the two failures are
the defects in section 6, not harness bugs):

```
crossmix-qa  root=/home/hermes/repos/wt-7
            shell=busybox (busybox ash)

ok    shell-syntax                   115 parsed, 1125 not materialised (sparse checkout)
FAIL  sh-lint-if-test-flag           test builtin used as a command at: System/starts/_FirmwareCheck.sh:242 System/starts/°customization.sh:156
ok    version-compare                17 rows (ordering + rejects)
ok    favorites-guard-healthy         exit 0, bytes unchanged, no backup
ok    favorites-guard-corrupt         1 line kept, original backed up
ok    favorites-guard-missing-launch  dead launcher entry dropped
ok    favorites-guard-absent          no-op on a card without favourites
ok    favorites-guard-no-jq           unusable jq: no repair, no backup, logged
FAIL  release-asset-selection         3 candidates match (want 1 image): CrossMix-OS_v1.4.0-ce.2.manifest.json ...
ok    hotfix-zip-vs-tree              9 members match the tree byte for byte
ok    hotfix-zip-coverage             9 listed files present
ok    release-manifest-fixture        30 assertions

10 passed, 2 failed, 0 skipped, 0 known defects
```

Default mode marks those two as `KNOWN` and exits 0, so the harness can be added to CI
before the defects are fixed. `--strict` is the gate: today it must fail.

**What it deliberately does not do:** no network, no `reboot`, no `7zz` extraction, no
`/mnt/SDCARD` writes, no assertion about MainUI. It is a regression net for logic drift
(comparators, asset selection, guard policy, payload drift), not a substitute for section 3.

**Suggested CI wiring (not done here — touching the release workflow is out of scope):**

```yaml
on: [push, pull_request]        # separate workflow, ubuntu-latest, 30 s
steps:
  - uses: actions/checkout@v4
  - run: sudo apt-get install -y busybox jq p7zip-full
  - run: sh scripts/qa/run.sh --strict
```

---

## 5. Seven highest-risk gaps (what failure each one permits)

**G1 — Release asset selection is not anchored to the image name.**
`update_ota_release.sh:99-103` picks every asset whose name *contains* `CrossMix-OS_v`.
The release now ships three such assets (image, image manifest, hotfix manifest —
workflow `:121-157`). `FACT`: the exact pipeline copied out of the script returns
3 URLs and 3 candidate versions, so `Release_Version`/`Release_FullVersion` become
multi-line values (`1.4.0-ce.2.manifest.json`, `…hotfix-manifest.json`, `1.4.0-ce.2`) and
`cmp_crossmix_versions` returns "invalid" (rc 1, no output) → `OTA_EXIT_VERIFY`.
**Failure:** on any console once a release carries its own manifests, Check Update ends in
"verification failed" with no update and no actionable message. Behind that gate the
unquoted `download_file $Release_url` would also pick the *last* matching URL by word
splitting, so even a passing gate could download a manifest as the image. Split images
(`.7z.001`) are equally unpickable: `sed` strips only a trailing `.7z`.
Repro: `sh scripts/qa/run.sh --strict` → `release-asset-selection`. Same defect, stricter
matcher, already solved in `update_notification.sh:71-93`; the fix is to reuse it.

**G2 — The boot installer cannot compare the versions this project ships.**
`_FirmwareCheck.sh:298` does `[ "$(echo "$v" | tr -d '.')" -gt ... ]`. `FACT`:
`1.4.0-ce.2` → `140-ce2` → `bad number`, `test` exits 2, the branch is false.
**Failure:** a staged `CrossMix-OS_v1.4.0-ce.2.zip` (the current version string) is
classified as "not greater than the installed version". The console boots normally, says
nothing, keeps the archive on the SD root forever, and the user concludes the update
"succeeded" because `update_ota_release.sh` wrote `success` to `/tmp/ota_release_result`
and rebooted. Only `cmp_crossmix_versions` has tests; this third comparator has none.
Repro: `tr -d '.'` on the two strings, then `[ 140-ce2 -gt 140-ce2 ]`.

**G3 — A failed extraction leaves a half-moved system tree.**
`crossmix_update.sh:96-100` moves `System/`, `Apps/`, `Themes/`, `Emu/` … into
`_Updates/Backup_CrossMix_v<old>/` **before** extracting the new archive (`:110-114`). On
failure the script only restores `crossmix-version.txt` (`:128-136`); the directories stay
in the backup folder, the archive stays in the SD root and the next boot retries the same
operation on an already-moved tree. **Failure:** console boots to MainUI with missing
`System/` (no OTA scripts, no System Tools, possibly no emulators) and each boot re-enters
the same half-state — the exact class of damage that needs a PC to repair.
No test: the harness stops at `7zz`, and `move_items` is untested even as a unit.

**G4 — Hotfix application is non-atomic and unauthenticated, and its stamp is written
even when the payload failed.**
`CrossMix-OS_v1.4.0-ce.2.sh:64` runs `7zz x -aoa` directly onto `/mnt/SDCARD`: no staging
directory, no checksum of the zip, no rollback. `:135-144` then writes
`crossmix-hotfix-version.txt` **even when the firmware payload failed**, by design (to
avoid a 158 MB retry loop). **Failure:** a killed run (user exits the terminal, SD pulled,
power loss mid-extract) leaves a mix of old and new OTA scripts with no stamp → the next
run re-applies on top of the mix; or the payload failure is stamped as "applied", so
`run_hotfix` never retries and the console stays on an old firmware while claiming
`1.4.0-ce.2.16`. The harness proves the *payload* matches the tree; nothing proves the
*application* is all-or-nothing.

**G5 — Two boot scripts contain `if -f` instead of `if [ -f ... ]`.**
`_FirmwareCheck.sh:242` and `°customization.sh:156`. `FACT`: `if -f x` runs a command
named `-f`, exits 127 and takes the `else` branch — no error, no log, `sh -n` passes.
**Failure (a):** after a firmware flash the "restore FW settings" branch never runs, so
joystick/Wi-Fi settings silently stay at defaults. **Failure (b):** the "remove the
previous automatic backup" branch never runs, so every firmware update leaves another
full settings backup on the card. Both are invisible in normal use; the second one is how
a 32 GB card fills up over a few updates. Caught by `sh-lint-if-test-flag`.

**G6 — Three independent version comparators, one of them tested.**
`cmp_crossmix_versions` (`update_common.sh:342-392`, COVERED), `version_num`
(hotfix `:26-50`, `NONE`) and the `tr -d '.'` compare (`_FirmwareCheck.sh:298`, `NONE`).
`FACT`: `version_num` pads only five components, so `1.4.0-ce.2.16.1` truncates; the
hand-rolled `-le` path also silently accepts a local version with fewer components as
"newer". **Failure:** the release says "update available" (canonical comparator) while
the hotfix says "already applied" (or vice versa), so a console can be flagged forever or
never offered the hotfix that fixes the flag — and the disagreement is invisible because
each path logs to a different file. Any future version scheme needs three edits in three
languages of comparison; only one of them is in the harness.

**G7 — Firmware payload integrity is asserted at the filename level only.**
CI checks that `firmware_tsp_v<ver>_<rev>.7z.001` exists (workflow `:49-59`) and nothing
else; `.002` is never mentioned. At boot `_FirmwareCheck.sh:157-171` falls back to "the
newest bundled payload" whenever the declared one is missing, and the *hotfix* downloads
both parts with three retries each but only tests the archive with `7zz t` (`:123`).
**Failure:** a truncated or missing `.002`, or a stale bundle left on the card, is
accepted as the update source and the console is asked to flash a firmware image that
does not match `MinFwVersion.txt` — the one operation on this device that can require
recovery. The only real gate is a human reading `7zz t` output.

---

## 6. Defects found while writing this (not coverage gaps)

**D1 — `release-asset-selection` fails.** `FACT`: 3 assets match
`contains("CrossMix-OS_v")` on a release that carries both manifests. See G1.
**RESOLVED in #44**: anchored to `CrossMix-OS_v<tag>.7z|.zip` with size/url checks and
`.7z` preference. Case green: 1 candidate.

**D2 — `sh-lint-if-test-flag` fails.** `FACT`: `System/starts/_FirmwareCheck.sh:242` and
`System/starts/°customization.sh:156`. See G5.
**RESOLVED in #44**: `[ -f ... ]` at both sites. Case green.

Both were listed in `KNOWN_DEFECTS` while open and were removed from that list when fixed,
as this section required. The harness now runs 12/12 with no `KNOWN` and no `skip`, and
`--strict` exits 0.

---

## 7. Pre-release checklist (10 lines)

1. `sh scripts/qa/run.sh --strict` exits 0 — no `KNOWN` defects, no `skip` on a path this release touches.
2. `busybox sh -n` clean for every script in the diff, and the `sh-lint-if-test-flag` case green.
3. Version/comparator or GitHub-API shape changed? Update the `version-compare` and `release-asset-selection` fixtures in the same commit.
4. Hotfix payload changed? Re-run `_assets/scripts/build-hotfix-zip.sh` on the final tree and commit the regenerated zip (`hotfix-zip-vs-tree` + `hotfix-zip-coverage` green).
5. `crossmix-version.txt`, `trimui/firmwares/MinFwVersion.txt` and the payload filenames agree; the workflow's payload-consistency step passes on a full checkout.
6. Release assets reviewed by name: exactly one `CrossMix-OS_v<tag>.7z|.zip` image, plus manifests — no second asset matching the updater's filter.
7. Manifest published and spot-checked: `jq -r '.files[].sha256'` matches `sha256sum` of the uploaded archive parts.
8. On a disposable SD: fresh image install boots, `crossmix-version.txt` matches the tag, System Tools opens (menu cache rebuilt, new entry visible).
9. On the same SD: Check Update twice (idempotent; `$updatedir/ota_release.log` shows the exit code), then the hotfix path — `crossmix-hotfix-version.txt` advances and no `*.tmp`/`.partial` files remain.
10. Append a broken line to `Roms/favourite2.json` and boot: menu opens, backup lands in `System/backups`; record device, SD, versions and date in the release issue so the manual evidence survives.

Lines 8–10 are the only ones a machine cannot do; they are also the only ones whose
result is currently not written down anywhere.

---

## 8. Extending this

- One case per listed gap, in `scripts/qa/run.sh`, with the failing assertion written
  first. Prefer extracting the real expression/filter from the script (as
  `release-asset-selection` does) over copying it into the test — a copy passes forever.
- When a `/tmp` harness is used again for an OTA investigation, add the smallest case that
  reproduces what it found before deleting it. The budget is ~40 lines per case.
- Hardware sessions should leave a `docs/qa-runs/YYYY-MM-DD-<version>.md` with the ten
  checklist lines and raw command output; that is the only way the `H` column ever becomes
  `COVERED`.

# Upstream triage — `cizia64/CrossMix-OS` → CrossMix-OS SE

**Consultation date:** 2026-10-18 (UTC).
**Upstream audited:** `cizia64/CrossMix-OS`, default branch `main`, GPL-3.0.
**Tooling:** `gh` CLI (authenticated as `scolfbrain-source`) plus the fetched `upstream` remote. No write operations, no PRs, no comments on the upstream repository.
**Scope:** decide what from upstream is worth taking, with the diff read for every candidate. Nothing is implemented here.

## 1. Divergence point

| Item | Value | Evidence |
|---|---|---|
| Upstream HEAD (`main`) | `206d612f` — "Improve Random app", 2026-08-20 | `gh api repos/cizia64/CrossMix-OS/commits` |
| Merge-base with our `main` | `206d612f` (upstream HEAD **is** the merge-base) | `git merge-base origin/main upstream/main` |
| Commits upstream has that we lack | **0** | `git rev-list --count <base>..upstream/main` |
| Commits we have that upstream lacks | 40 | `git rev-list --count <base>..origin/main` |
| Upstream pushed_at | 2026-08-20T03:28Z | repo metadata |

The fork is fully merged with upstream `main`: there is no upstream commit on the default branch that we are missing.

The live upstream work is therefore not on `main` but on three unmerged topic branches and 17 open pull requests:

| Branch | Head | Ahead / behind `main` | Nature |
|---|---|---|---|
| [`TrimUI-Smart-Pro-S-compatibility`](https://github.com/cizia64/CrossMix-OS/tree/TrimUI-Smart-Pro-S-compatibility) | `372cbb55` (2026-08-20) | 41 ahead / 3 behind | Multi-device (TG5040/TG5050/TG3040/TG4040) rewrite of firmware check, customization, OSD, inputd, language packs |
| [`PPSSPP-update`](https://github.com/cizia64/CrossMix-OS/tree/PPSSPP-update) | `f75279ea` (2025-08-28) | 3 ahead / 36 behind | Head of PR #506 |
| [`Brick`](https://github.com/cizia64/CrossMix-OS/tree/Brick) | `4742c235` (2024-12-29) | 15 ahead / 87 behind | Brick hardware (TG3040) + per-device themes |

The 3 commits `main` has that the TSP-S branch lacks are `cd19f475` ("[Fix] Support for TSP firmware v1.1.1 (#548)"), `80fa4bb4` (libffi) and `206d612f`. #548 already absorbed a large part of the branch's 1.1.1 work (SSH enable/disable scripts, `init.d/sshd`, `asound.conf` removal, `.lang` fixes, the `firmware_tsp_v1.1.1_20251128` payload) — that is why several branch commits below are classified as already covered.

Release channel: latest published upstream release is [v1.3.0](https://github.com/cizia64/CrossMix-OS/releases/tag/v1.3.0) (2024-12-22). Upstream has shipped no image since, so there is no upstream release artifact to diff against; only the branch contents matter.

## 2. Priority criterion

Priority answers "when do we look at this", not "how good is it".

- **P0 — conflict blocker.** The change lands on a path where this fork already ships a different, hardware-verified fix: `System/starts/_FirmwareCheck.sh`, `System/starts/°customization.sh`, the OTA scripts (`ota_update.sh`, `update_common.sh`, `crossmix_update.sh`), `favorites_guard.sh`, `MinFwVersion.txt`. Never cherry-pick these; reconcile the design first.
- **P1 — adopt as an isolated patch.** Small, auditable, device-agnostic, no overlap with our divergent files.
- **P2 — adopt only after on-device verification.** Plausible gain, but it touches input, boot/library scan, shutdown, emulator binaries or OSD, where a server-side test proves nothing.
- **P3 — park or reject.** Other hardware, cosmetic churn, superseded work, or scope we do not want.

A hardware test on the TG5040 is the gate for every P2. `sh -n` or a stubbed run does not clear it.

## 3. Verdict summary

| Surface | Rows triaged | Adopt | Have equivalent | Not applicable | Risk |
|---|---|---|---|---|---|
| upstream `main` commits | 1 (the whole branch) | 0 | 1 | 0 | 0 |
| `TrimUI-Smart-Pro-S-compatibility` commits | 41 | 11 | 5 | 14 | 11 |
| Open pull requests | 17 | 6 | 1 | 4 | 6 |
| Upstream issues cited as context | 4 | — | 4 | — | — |

## 4. Upstream `main`

| Ref | What it changes | Verdict | Why | Priority |
|---|---|---|---|---|
| [`206d612f`](https://github.com/cizia64/CrossMix-OS/commit/206d612f) (branch `main`) | Last three commits: "Improve Random app", missing `libffi.so.7`, firmware v1.1.1 support (#548) | **HAVE EQUIVALENT** | `206d612f` is an ancestor of our `main`; the fork already contains all of it | — |

There is nothing to take from `main`. Any future adoption has to come from the unmerged branches or the open PRs below.

## 5. Branch `TrimUI-Smart-Pro-S-compatibility` (41 commits)

Ordered newest first, as in `git log`. Every row was read with `git show <sha>` on the fetched upstream refs; every SHA was resolved against the GitHub API on 2026-10-18.

| Commit | What the diff actually does | Verdict | Why | Pri |
|---|---|---|---|---|
| [`372cbb55`](https://github.com/cizia64/CrossMix-OS/commit/372cbb55) | `infoscreen.sh`: moves the `style_<theme>` / device-suffixed image resolution **out** of the `[ -f "$image_name" ]` branch (previously themed images were only looked up when the argument was a full path), and adds `<name>_<device>.png` lookups | **ADOPT** | Genuine lookup bug fixed; on `tsp` the new suffixes match no file yet, so behaviour is unchanged until we ship `*_tsp.png` for the SE screens | P2 |
| [`918dae87`](https://github.com/cizia64/CrossMix-OS/commit/918dae87) | Scraper OSD toast coordinates made per-device; `tsp`/`tsps` keep `x=920,y=330`, `brick` gets `350,350` | **HAVE EQUIVALENT** | Byte-identical behaviour for TG5040 — no reason to touch a working script | P3 |
| [`e18f7077`](https://github.com/cizia64/CrossMix-OS/commit/e18f7077) | Adds 10 `*.brickpro.patch` files for MainUI strings | **NOT APPLICABLE** | Brick Pro (TG4040) texts | P3 |
| [`51fc2647`](https://github.com/cizia64/CrossMix-OS/commit/51fc2647) | Adds `brickpro_inputd`; `inputd_switcher.sh` gains three guards: abort if `/etc/trimui_device.txt` is missing, abort with a message if `${device}_inputd` is absent, skip polling-rate config on `brickpro` | **ADOPT (guards only)** | The binary is Brick Pro; the guards are device-agnostic and stop a silent `cp` failure from leaving a stale `trimui_inputd` in place | P1 |
| [`f4c376ef`](https://github.com/cizia64/CrossMix-OS/commit/f4c376ef) | FnEditor fonts, `fnkey_scripts.json`, backlight/cpufreq switch scripts for Brick Pro | **NOT APPLICABLE** | Fn key hardware of the Brick family | P3 |
| [`a5265eda`](https://github.com/cizia64/CrossMix-OS/commit/a5265eda) | 63 lines in `_FirmwareCheck.sh`, `start_tab.sh`, 73 lines in `°customization.sh`: language patcher wiring and Avahi `host-name` set to `$current_device` | **RISK** | Lands directly on our rewritten firmware check and on the boot block that carries our favourites guard | P0 |
| [`1f3b7fb0`](https://github.com/cizia64/CrossMix-OS/commit/1f3b7fb0) | Renames `cpuinfo_osdd`→`cpuinfo_osdd_tsp`, adds `_tsps` binaries, **deletes** `System/usr/trimui/osd/osdlayout.json`, adds `osdlayout_tsp.json`/`osdlayout_tsps.json`, plus the copy logic in the device-change block | **RISK** | Restructures OSD layout and depends on the `°customization.sh` device block; our SE screens and OSD layout would need revalidation on the device | P2 |
| [`b35ffdf7`](https://github.com/cizia64/CrossMix-OS/commit/b35ffdf7) | Adds `RetroArch/ra64.trimui_tsps_1.22.2.bin` | **NOT APPLICABLE** | TSPS-only binary | P3 |
| [`e778d0bd`](https://github.com/cizia64/CrossMix-OS/commit/e778d0bd) | Adds the C source of `Emu_DBcleanup` under `_assets/sources/` | **ADOPT** | Source publication only (GPL hygiene) — pair with the EmuCleaner row; do not ship the binary alone | P3 |
| [`9c4abd40`](https://github.com/cizia64/CrossMix-OS/commit/9c4abd40) | `lang_patches.sh` runtime copy, Brick Pro patches, `generate_patches.py` tweak | **NOT APPLICABLE** | Brick Pro strings | P3 |
| [`9bd2ee2b`](https://github.com/cizia64/CrossMix-OS/commit/9bd2ee2b) | Replaces `puae2021_libretro.so` (10,082,216 → 10,214,424 B) and adds `System/lib/libvpx.so.4` | **RISK** | Our inventory already reports PUAE 2021 v2.6.1 but the binary differs (`md5 3ea7ad4a` vs `e51424e1`) — the version string is not evidence of what changed; `libvpx.so.4` is absent from our tree so the new core would need it added | P2 |
| [`54dce8b6`](https://github.com/cizia64/CrossMix-OS/commit/54dce8b6) | One line of the **global** `RetroArch/retroarch.cfg`: `video_context_driver = "gl_sdl"` | **RISK** | Commit message says TSPS black screens, but the file is shared with TG5040; forcing a context driver on our device is an unverified video-init change | P2 |
| [`c484a50e`](https://github.com/cizia64/CrossMix-OS/commit/c484a50e) | Three one-line fixes: unbalanced quote in `Apps/SmartLed/launch.sh` (`grep "You selected")"`), `/usr/lib` prepended to `LD_LIBRARY_PATH` in `infoscreen.sh`, same quote fix in `.romscript_launcher.sh` | **ADOPT** | The two quote fixes are real shell bugs on any device. The `LD_LIBRARY_PATH` change is TSPS/mali-motivated and should be dropped when patching | P1 |
| [`f020a97b`](https://github.com/cizia64/CrossMix-OS/commit/f020a97b) | Adds a 292 MB `firmware_tsps_v1.0.1` payload and 5 lines in `_FirmwareCheck.sh` | **NOT APPLICABLE** | TSPS firmware payload | P3 |
| [`3bb14e47`](https://github.com/cizia64/CrossMix-OS/commit/3bb14e47) | Renames every `ra64.trimui-<ver>` to `ra64.trimui_<device>_<ver>.bin`, adds Brick builds, rewrites `Apps/RetroArch/launch.sh` to pick per device | **RISK** | Invalidates `docs/emulators-inventory.tsv` / `cores-inventory.tsv` paths and the launch path for every system in one commit; depends on the `°customization.sh` device block | P2 |
| [`5e046a9e`](https://github.com/cizia64/CrossMix-OS/commit/5e046a9e) | Adds the device-patch call in `°customization.sh`, `lang_patches.sh`, and **new language packs** `ch.lang`, `ko.lang`, `de.lang`, `es.lang` (217 lines each) | **ADOPT (packs only)** | `es.lang` and `de.lang` do not exist in our tree — a Spanish pack is directly useful for this fork's owner. Caveat: the packs declare `"icon": "lang_es.png"` / `"lang_de.png"` and **no `lang_*.png` exists in `trimui/res/lang/`**, so the icons must be produced before shipping, or the language menu shows an empty icon | P2 |
| [`ee3feaad`](https://github.com/cizia64/CrossMix-OS/commit/ee3feaad) | Python patch generator, `lang_patches.sh`, per-device patch files under `_assets/sources/` | **NOT APPLICABLE** | Patches stock MainUI strings per device; the `.lang` copy path already covers TG5040 | P3 |
| [`db366aae`](https://github.com/cizia64/CrossMix-OS/commit/db366aae) | Two lines in `_FirmwareCheck.sh` before flashing: `rm /usr/trimui/res/sound/bgm2.mp3` (from `rm -rf`) and **`rm /etc/1.mp4`** | **ADOPT (one line)** | Frees internal storage before extracting — the same failure class as upstream issue #314. Apply as a patch to our file, not as part of a merge | P1 |
| [`cd91ece8`](https://github.com/cizia64/CrossMix-OS/commit/cd91ece8) | `chmod a+x /usr/trimui/apps/musicplayer/launch.sh &` before invoking the stock music app | **ADOPT** | Harmless on TG5040, fixes a permission-drift class of bug | P1 |
| [`cabca600`](https://github.com/cizia64/CrossMix-OS/commit/cabca600) | DinguxCommander/File Manager branch for TG5050 | **NOT APPLICABLE** | TSPS panel | P3 |
| [`321a16cd`](https://github.com/cizia64/CrossMix-OS/commit/321a16cd) | Final `tsp_inputd` / `tsps_inputd` build (41,144 B, `md5 d140e919`; ours in `main` is `md5 0fa99a33`) | **ADOPT** | Only TSP-relevant *binary* change in the branch ("Fix old DPAD bug!" / device detection). Binary, no source: cannot be audited statically, so it needs a controls test on the device | P2 |
| [`c4b24518`](https://github.com/cizia64/CrossMix-OS/commit/c4b24518) | Publishes busybox sources under `_assets/sources/busybox/`, replaces `System/usr/trimui/scripts/busybox` (1,082,936 → 984,472 B), deletes `System/updates/update_001/busybox` | **ADOPT (sources) / RISK (binary)** | Publishing the GPL source of a binary we ship is pure compliance gain. Swapping busybox is the opposite: it is the shell that runs every script here, and a missing applet fails silently at boot | P1 / P2 |
| [`5da7f2a3`](https://github.com/cizia64/CrossMix-OS/commit/5da7f2a3) | Mechanical rename of `Current_device`/`device` → `current_device` across 8 shared files | **RISK** | Zero functional gain, wide surface (Activities, BootLogo, `common_functions.sh`, `common_launcher.sh`, `themepack_apply.sh`); pure churn | P3 |
| [`011644bf`](https://github.com/cizia64/CrossMix-OS/commit/011644bf) | `FW Settings Save-Load.sh` per-device paths, 86 lines of `_FirmwareCheck.sh`, 8 lines in `°customization.sh` | **RISK** | The settings-backup path (`System/backups/firmware_settings/$device/…`) is **already in our `main`**; the `_FirmwareCheck.sh` half is the firmware rewrite we reject | P0 |
| [`82315764`](https://github.com/cizia64/CrossMix-OS/commit/82315764) | Adds `libpng12.so.0` and GL symlinks for the TSPS file manager | **NOT APPLICABLE** | TSPS packaging | P3 |
| [`45d79058`](https://github.com/cizia64/CrossMix-OS/commit/45d79058) | Replaces the shell EmuCleaner with a C binary (source included, 306 lines): 100 ms instead of ~7 s, and drops the `infoscreen.sh` call for `pic2fb`/`pic2fb_drm` | **RISK** | Real performance win, but EmuCleaner is inside the first-boot recovery path this project documented (`°customization.sh` re-runs it over all `Roms/` when the version stamp is missing). Changing it changes that recovery path; it needs a device test on a card with a full library | P2 |
| [`159da7a2`](https://github.com/cizia64/CrossMix-OS/commit/159da7a2) | Titled "Fix activities app"; the diff is ~95 % reindentation of `common_functions.sh` plus one new `TG5050_rotate_screen()` helper and 5-6 line additions in the Activities launchers | **NOT APPLICABLE** | No behavioural fix for TG5040. Concrete example of why titles are not evidence | P3 |
| [`c35e8bd0`](https://github.com/cizia64/CrossMix-OS/commit/c35e8bd0) | Binary-only change to `Apps/user_guide/user_guide` (14,568 → 14,280 B) | **RISK** | No source, no message beyond the title: applicability to TG5040 cannot be established from the artifact | P3 |
| [`b27bd415`](https://github.com/cizia64/CrossMix-OS/commit/b27bd415) | Intermediate `tsp_inputd`/`tsps_inputd` (46,408 → 36,848 B) | **ADOPT (superseded)** | Superseded by `321a16cd`; no separate action | P3 |
| [`89770dfe`](https://github.com/cizia64/CrossMix-OS/commit/89770dfe) | `common_launcher.sh`: rotate DSI-1 for `tsps` | **NOT APPLICABLE** | TSPS rotation | P3 |
| [`578f975e`](https://github.com/cizia64/CrossMix-OS/commit/578f975e) | Each launcher derives `LOG_FILE` from `/tmp/log/messages` with `/tmp/messages` fallback | **NOT APPLICABLE** | On TG5040 the first path exists, so behaviour is identical — no benefit, extra surface | P3 |
| [`3a84ac02`](https://github.com/cizia64/CrossMix-OS/commit/3a84ac02) | Rewrites `°post_starts.sh` (251 lines) plus input-device detection in MusicPlayer, JAVA, PICO, VIDEOS, OSD widgets | **NOT APPLICABLE** | Multi-device input mapping; the rewrite is not separable from the hardware it targets | P3 |
| [`5951b165`](https://github.com/cizia64/CrossMix-OS/commit/5951b165) | Adds `\| grep "You selected"` to `selector` calls in `Apps/RetroArch/launch.sh`, `Emus/DOOM/launch.sh`, romscript launcher (stray `LIBGL: Shuting down` on stdout) | **ADOPT** | Defensive parsing of a shared binary's stdout; same pattern already used elsewhere in the tree | P1 |
| [`a984db64`](https://github.com/cizia64/CrossMix-OS/commit/a984db64) | Pro S control maps + inputd binaries | **NOT APPLICABLE** | TSPS hardware | P3 |
| [`0ca9e766`](https://github.com/cizia64/CrossMix-OS/commit/0ca9e766) | Two lines in `°customization.sh` for TSPS Wi-Fi | **NOT APPLICABLE** | TSPS Wi-Fi driver | P3 |
| [`7ffc43e4`](https://github.com/cizia64/CrossMix-OS/commit/7ffc43e4) | 91 lines in `°customization.sh` (per-device FN keys, OSD, GL symlinks), `FW Settings Save-Load.sh`, `inputd_switcher.sh` | **RISK** | Rewrites the boot customization block that carries our favourites guard (GH#36) | P0 |
| [`f9271e17`](https://github.com/cizia64/CrossMix-OS/commit/f9271e17) | 97 lines of `_FirmwareCheck.sh`: device detection from `/proc/cpuinfo` (`TG5040/TG5050/TG3040`), per-device `FIRMWARE_FILENAME`, and **removal of the `MinFwVersion.txt` contract** — required version now parsed from the payload filename found on the card | **RISK** | Direct conflict with our firmware design, see §8.1 | P0 |
| [`62f1397c`](https://github.com/cizia64/CrossMix-OS/commit/62f1397c) | SSH state sync: `systemval enablessh 1/0`, `-s` silent flag, IP display, custom `/etc/init.d/sshd` disabled by default, `asound.conf` removed | **HAVE EQUIVALENT** | All of it is already in our `main` via #548 (verified: `enablessh` at line 41 of the enable script, `init.d/sshd` present in the tree, `asound.conf` absent) | P3 |
| [`6ab6421a`](https://github.com/cizia64/CrossMix-OS/commit/6ab6421a) | `vn.lang` strings for firmware 1.1.1 | **HAVE EQUIVALENT** | `git diff upstream/main branch -- trimui/res/lang/vn.lang` is empty | P3 |
| [`2c7c0ea3`](https://github.com/cizia64/CrossMix-OS/commit/2c7c0ea3) | `.lang` keys for firmware 1.1.1 across 11 languages | **HAVE EQUIVALENT** | `en.lang` and `fr.lang` are byte-identical between `main` and the branch (#548 carried the same edits) | P3 |
| [`3e9df870`](https://github.com/cizia64/CrossMix-OS/commit/3e9df870) | Restores the root password (`chpasswd`) in the boot script | **HAVE EQUIVALENT** | Our `°customization.sh` already runs `echo "root:tina" \| chpasswd` at every boot | P3 |

**Branch-level verdict:** do not merge the branch, and do not rebase our work onto it. It is a coherent multi-device redesign, not a set of independent fixes; the parts that matter for TG5040 are extractable as 12 small patches, and the parts that would break this fork are concentrated in two files.

## 6. Open pull requests (17)

| PR | What it actually does (body/diff read) | Verdict | Why | Pri |
|---|---|---|---|---|
| [#573](https://github.com/cizia64/CrossMix-OS/pull/573) | New `Apps/PPSSPP/{config.json,launch.sh}`: opens PPSSPP 1.17.1 GL without a ROM, `cpufreq.sh ondemand 3 6`, reuses existing config/saves. Tested by the author on a TSP running v1.3.0 | **ADOPT** | Additive, self-contained, on-target hardware; must be reflected in `docs/emulators-inventory.tsv` | P2 |
| [#320](https://github.com/cizia64/CrossMix-OS/pull/320) | Brick adaptation: overlays switcher, per-device themes (3,098 files, mostly `Themes/`), brick inputd binaries, mupen64 resolution | **NOT APPLICABLE** | Brick hardware; base branch is `Brick`, not `main` | P3 |
| [#542](https://github.com/cizia64/CrossMix-OS/pull/542) | Per-game PPSSPP settings for TSP: 27 commits, 13 files, 7,759 added lines, plus a weekly GitHub Action that scrapes a Google Sheet and opens PRs | **RISK** | Introduces a scheduled bot and a generated dataset into the repo. Interesting, but it is a product decision and a maintenance commitment, not a patch | P3 |
| [#543](https://github.com/cizia64/CrossMix-OS/pull/543) | `zip -s 2000m` split + upload `.z01` in the release workflow, for GitHub's 2 GiB asset limit | **HAVE EQUIVALENT** | Our workflow already packages with `7zz -mx=7`, rebuilds with `-v1900m` when the archive is ≥ 2,000,000,000 B, and uploads `"$ASSET"*` | P3 |
| [#466](https://github.com/cizia64/CrossMix-OS/pull/466) | Two `ppsspp_1.17.1_*` launchers: resets `GlobalVolume` to 10 in the `[Sound]` section on start (muting PPSSPP used to persist) | **ADOPT** | Real state bug, two files, no overlap with our work | P1 |
| [#505](https://github.com/cizia64/CrossMix-OS/pull/505) | PPSSPP 1.19.3 binary by a third party, "compatible with trimui firmwares 1.1.0", needs `libIMGegl` | **RISK** | Built and validated against firmware 1.1.0; we require 1.1.1 and nobody has published a 1.1.1 result. Also 192 files and an unclear provenance chain for the binary | P2 |
| [#506](https://github.com/cizia64/CrossMix-OS/pull/506) | PPSSPP 1.18.1 + 1.19.0, new version-chooser menus, updated cheats, Select+Start/R2/L2 shortcuts, 194 files | **RISK** | Conflicts with our PSP launcher set and inventory; the shortcut bindings collide with #369 and #466's launchers | P2 |
| [#482](https://github.com/cizia64/CrossMix-OS/pull/482) | Rewrites `GoTo_SystemTools_List.json` (title 198→206, `type` 0→48, `tabstartidx` 2→3) and adds per-tab scripts; fixes the `state.json` crash that left MainUI on the homepage after restart on fw 1.1.0 | **RISK** | The crash fix is valuable and matches our own boot-loop experience, but it renames the Start Tab scripts our `°customization.sh` calls (`Tab Game.sh`), and GitHub reports `mergeable=false` | P2 |
| [#481](https://github.com/cizia64/CrossMix-OS/pull/481) | Device split in `_FirmwareCheck.sh`, TSP payload to 1.1.0, Brick payload added, dependency raised to fw 1.1.0 | **NOT APPLICABLE** | Superseded: our floor is 1.1.1/20251128 and our payload is `firmware_tsp_v1.1.1_20251128` | P3 |
| [#475](https://github.com/cizia64/CrossMix-OS/pull/475) | Six binary libraries (`libmodplug.so.1` replaced, five added) for the Balatro port | **NOT APPLICABLE** | Port-specific libs; we do not ship that port | P3 |
| [#416](https://github.com/cizia64/CrossMix-OS/pull/416) | PCSX-ReARMed hi-res launcher, SwanStation wide/no-wide merge, pre-created configs, per-game overrides; fixes upstream #206 and a wrong `.opt` target | **ADOPT** | PS is a first-class system here and the bug (patching an empty `PS.opt` instead of `SwanStation.opt`) is real; needs a PS boot test on the device | P2 |
| [#418](https://github.com/cizia64/CrossMix-OS/pull/418) | Replaces the `fbset` display check with `hwserial` from `/proc/cpuinfo` (`TG5040` prefix) in `_FirmwareCheck.sh` | **ADOPT** | Our `main` still detects the device from `fbset` geometry; the SoC check is cheaper and survives panel changes. Note: upstream writes `${hwserial::6}`, a bashism — use the branch's portable `case "$cpuinfo" in *TG5040*)` form instead | P1 |
| [#405](https://github.com/cizia64/CrossMix-OS/pull/405) | Vendors the Helix editor (`System/opt/`), 1,109 files / 51,263 lines | **NOT APPLICABLE** | Scope: a text editor is not part of this fork's surface | P3 |
| [#369](https://github.com/cizia64/CrossMix-OS/pull/369) | PPSSPP Select+button shortcut bindings for v1.17 | **RISK** | Duplicates and contradicts the bindings in #506; adopting both would double-map buttons | P3 |
| [#372](https://github.com/cizia64/CrossMix-OS/pull/372) | System Tools action that deletes covers with no matching ROM (walks all of `Roms/`) | **ADOPT** | Useful, self-contained tool; must be read-only-by-default and confirmed before deleting, because it walks the user's library | P3 |
| [#331](https://github.com/cizia64/CrossMix-OS/pull/331) | `kill_apps.sh`: recursive `kill_childs()` that kills every descendant and waits with `kill -0`, replacing the "deepest child" walk | **ADOPT** | Fixes autosave-on-power-off for launchers that fork; touches shutdown, so it needs a save-state test | P2 |
| [#269](https://github.com/cizia64/CrossMix-OS/pull/269) | PSP launcher presets: detect the ROM and store the launcher choice | **RISK** | Superseded by #416/#506's chooser rework; adopting now would be undone by either | P3 |

## 7. Upstream issues used as context

Not adoption candidates — they establish that upstream has not solved what this fork already fixed.

| Issue | State | Relation to our work |
|---|---|---|
| [#61 "OTA updates"](https://github.com/cizia64/CrossMix-OS/issues/61) | open since 2024-07-01 | Upstream `main` still has no OTA channel; our `ota_update.sh` + hotfix pipeline is ahead, not behind. Nothing to sync |
| [#324 "OTA update freezes"](https://github.com/cizia64/CrossMix-OS/issues/324) | open since 2024-12-30 | Same failure class our error-propagation work (GH#29) addresses |
| [#314 "Not enough space on internal storage to update"](https://github.com/cizia64/CrossMix-OS/issues/314) | open since 2024-12-27 | Justifies the `rm /etc/1.mp4` line from `db366aae` (ADOPT, P1) |
| [#421 "No Sound after Firmware Update"](https://github.com/cizia64/CrossMix-OS/issues/421) | open since 2025-05-15 | Context for the `asound.conf` removal already merged via #548; no action here |

## 8. Direct conflicts with our recent work

Only two files are touched by both sides — `System/starts/_FirmwareCheck.sh` and `System/starts/°customization.sh` — but they are precisely where this fork's recent fixes live. Any merge attempt must be resolved by hand, design first.

### 8.1 Firmware floor and payload selection (GH#5, firmware 1.1.1)

| Our side | Upstream branch side |
|---|---|
| `trimui/firmwares/MinFwVersion.txt` = `1.1.1` / `20251128` is the declared floor | `MinFwVersion.txt` is deleted; the floor is derived from whichever payload filename is on the card |
| `_FirmwareCheck.sh`: exact payload first, then newest bundled payload via `ls … \| sort \| tail -1` | `FW_ARCHIVE_FILE=$(ls …/firmware_${current_device}_v*.7z* \| head -n1)` — **lexicographic first**, i.e. the *oldest* payload when two are present (`v1.0.4…` sorts before `v1.1.1…`) |
| `Apps/SystemTools/Menu/TOOLS/Firmware Update.sh` reads `MinFwVersion.txt` (lines 21, 45, 70, 105) to build `firmware_tsp_v${req_ver}_${req_rev}.7z.001` and to download a missing payload | No consumer of `MinFwVersion.txt` left |
| CI step "Validate firmware payload consistency" fails the release when `MinFwVersion.txt` and the payload disagree (`.github/workflows/CrossMix Release.yml`) | The file the check reads no longer exists |
| Missing payload ⇒ explicit message and no flash | `Required_FW_Revision=""` ⇒ `[ -z … ]` branch ⇒ **silently no firmware check at all** (fails open) |

Consequence: taking the branch's firmware check would remove the 1.1.1 floor, break the release gate, and make `Firmware Update.sh` read a file nothing else honours. The SoC-based device detection inside it (also PR #418) is worth taking on its own.

### 8.2 Boot customization and the favourites guard (GH#36)

Our `°customization.sh` runs `favorites_guard.sh` under a 120 s timeout at every boot, immediately before the menu starts; that block is inside the region the branch rewrites (`7ffc43e4`, `a5265eda`, `1f3b7fb0`). A three-way merge here risks either dropping the guard — the exact bug that left MainUI on its loading screen — or calling it after the menu has already started.

Also note: the branch keeps the malformed `if -f "…/Last_Automatic_Backup.txt"; then` (missing brackets, line 155) in the fresh-install path, and it inherits another copy from `main` (line 156 in ours). Our tree carries that same defect today, unfixed; it is a cheap independent fix, unrelated to anything else in this triage.

### 8.3 Version comparator and OTA error propagation (GH#29, GH#34)

Upstream adds nothing here, so there is no textual conflict — but `°customization.sh` is rewritten to read `crossmix-version.txt` with `read -r version < file` instead of `cat`, and the version stamp is written at a different point in the boot (`sync` moved, `rm /usr/trimui/fw_mod_done` retained). Our comparator and hotfix channel key off that file. **Any** adoption from this branch requires re-running the OTA test set (CE/dev/legacy keys, `.2.9` vs `.2.10`, downgrade, child-failure propagation), because the stamp's write path is one of the moved pieces.

### 8.4 Firmware payload inventory

Branch `f020a97b` adds a 292 MB TSPS payload and `c4b24518` deletes `System/updates/update_001/busybox`. Our release image is assembled from this tree; a stray payload or a missing busybox in the update path changes image size and first-boot behaviour without touching any script we test.

## 9. Recommended order (no implementation in this issue)

1. **P1 patches, one PR per item:** `#418` SoC detection (portable form), `db366aae` (`rm /etc/1.mp4`), `5951b165` + the two quote fixes from `c484a50e`, `cd91ece8`, `#466`, `51fc2647` guards, busybox source publication from `c4b24518`.
2. **P2 with a device session:** `321a16cd` inputd (controls + DPAD), `#331` (autosave on power-off), `#416` (PS hi-res), `#573`/`#506` (PPSSPP path, pick one), `45d79058` EmuCleaner (full-library first boot), `es.lang`/`de.lang` + generated `lang_es.png`, `372cbb55` infoscreen lookup.
3. **Reconcile, do not merge:** a design note for the firmware check that keeps `MinFwVersion.txt` as the floor *and* takes the branch's SoC detection and per-device `FIRMWARE_FILENAME`. That is the only way the 41-commit branch can be consumed safely.
4. **Reject:** branch merge, `3bb14e47` binary rename, `5da7f2a3` rename churn, `54dce8b6` global `gl_sdl`, `c35e8bd0` unverifiable binary, `#542`, `#405`, `#320`, `#481`, `#475`.

## 10. What this triage does not establish

- **Binary-only commits cannot be validated statically:** `321a16cd`/`b27bd415` (inputd), `c35e8bd0` (user_guide), `9bd2ee2b` (PUAE + libvpx), `54dce8b6` (config value only). Verdicts for these rest on the commit message and on file provenance, not on behaviour.
- **No device was used.** Every P2 above is a hypothesis until it runs on a TG5040 with a real SD card. Nothing here should be merged on the strength of a diff alone.
- **Sampling:** upstream has 252 open issues and PRs combined (17 of them pull requests); four issues were read in full as context (§7). The remaining issues were not individually triaged and could contain hardware reports relevant to TG5040.
- **API health:** all upstream reads succeeded (commits, PRs, issues, branches, releases); no rate-limit errors, no fallbacks to memory.

### How to reproduce

```sh
git fetch upstream --prune
git merge-base origin/main upstream/main                 # 206d612f
git rev-list --left-right --count upstream/main...upstream/TrimUI-Smart-Pro-S-compatibility
git log --oneline upstream/main..upstream/TrimUI-Smart-Pro-S-compatibility
git cherry -v upstream/main upstream/TrimUI-Smart-Pro-S-compatibility   # patch-ids only; verify content too
gh api 'repos/cizia64/CrossMix-OS/pulls?state=open&per_page=100'
gh api repos/cizia64/CrossMix-OS/commits/<sha>            # resolves each SHA cited above
```

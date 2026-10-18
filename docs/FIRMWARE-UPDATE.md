# Firmware update — runbook (TrimUI Smart Pro / TG5040)

CrossMix-OS SE lives on the SD card. The TrimUI firmware lives in internal
storage and is **not** a CrossMix build. The payload shipped in this fork is
the official TrimUI image `1.1.1 / 20251128`. Its git blob OIDs match
`cizia64/CrossMix-OS` `main` (`58ffdd4e…` / `26d9eb5b…`): the fork did not
modify the firmware bytes.

**Primary method: the manufacturer's manual flash.** The boot-time check in
`System/starts/_FirmwareCheck.sh` is a convenience. It is not accredited on
hardware. A silent reboot does not mean the check ran.

Verified once on hardware (2026-10-18): a TSP reporting `1.0.4 / 20240410`
reached `1.1.1 / 20251128` with the steps below. Stock UI booted with the SD
removed. CrossMix-on-SD after that flash is a separate recovery, documented
in section 5, and was **not** re-confirmed after the SD cleanup in the same
session.

## 1. When an update is actually required

Read **System Tools → Information** (or the stock info screen) and compare
both numbers with `trimui/firmwares/MinFwVersion.txt`:

| Line | Meaning | Current target |
|---|---|---|
| 1 | Version | `1.1.1` |
| 2 | Revision (the number the boot check compares) | `20251128` |

The boot script compares the revision only (`cut -d '.' -f 3` of
`DISTRIB_DESCRIPTION` in `/etc/openwrt_release`) and flashes only when it is
**strictly lower**. Equal or higher: it prints nothing and deletes a leftover
`trimui_tg5040.awimg`. "Nothing happened" is success when the installed
revision is already ≥ required. It is a defect only when INFO shows a lower
revision.

Upstream CrossMix 1.4.x expects firmware ≥ `1.1.0 / 20250505`. A console on
`1.0.4` is below the original project's minimum, not a fork-only requirement.

## 2. Manual flash (do this)

Gates, all of them:

- Full SD backup on a PC first. A firmware flash does not touch the SD, but
  the first CrossMix boot rewrites internal storage and can force a long
  reinstall. The backup is the way back.
- Battery above 50 % or the console plugged in. Interrupting the green bar
  can brick the unit.
- The card that holds `trimui_tg5040.awimg` must be **FAT32**. The bootloader
  does not read exFAT for updates. The CrossMix card can be used if it is
  already FAT32; do not reformat it. Otherwise use any spare FAT32 card ≥ 1 GB.
- Keep the previous payload (`trimui_tg5040_20240413_v1.0.4_hotfix6.7z` on
  an existing CrossMix card). It is the rollback image.

Extract (7-Zip joins `.001` + `.002` and checks CRC; a 7-Zip error means stop):

```powershell
$sd = "E:"   # CrossMix card, only to read the two parts
$w  = "$env:USERPROFILE\Desktop\fw"
New-Item -ItemType Directory -Force $w | Out-Null
Copy-Item "$sd\trimui\firmwares\firmware_tsp_v1.1.1_20251128.7z.001" $w
Copy-Item "$sd\trimui\firmwares\firmware_tsp_v1.1.1_20251128.7z.002" $w
& "C:\Program Files\7-Zip\7z.exe" x "$w\firmware_tsp_v1.1.1_20251128.7z.001" -o"$w" -y
```

Copy `trimui_tg5040.awimg` to the **root** of the FAT32 card (next to the
folders, not inside `trimui\firmwares`). The name must be exact. Expected
size 584329216 bytes. Optional check:

```powershell
certutil -hashfile F:\trimui_tg5040.awimg SHA256
```

Expected: `b2c8d1eb3d42aca027babbf9aa038fdcfc60ef4430b529b6e26ccf1280541ebd`.

Flash:

1. Console **off**. Insert the FAT32 card.
2. Hold **VOLUME− + POWER** until the green bar appears, then release.
3. Do not touch buttons, do not pull the card, do not cut power until the
   console reboots by itself.
4. Boot **without** the CrossMix card. INFO must show `1.1.1 / 20251128`.
   That reading is the acceptance check. The bootloader step is not visible
   from the server.

## 3. What the boot check does (not the procedure)

`System/starts/_FirmwareCheck.sh` runs at boot. It does not replace section 2.

1. Parse the installed revision. Empty parse: exit, no screen.
2. If installed ≥ required: delete a leftover `.awimg` and continue.
3. If installed < required: swap busybox, extract the `.7z` to
   `trimui_tg5040.awimg`, check CRC, show "Ready for update". **A** powers
   off; **B** cancels. The next boot is still the manufacturer's flash.
4. Missing payload, bad CRC and low space show a failure screen. A silent
   reboot with a lower revision is therefore not "missing payload". It means
   the script did not run, or the revision parse was empty.

Closed by hotfix `1.4.0-ce.2.16`: the zip ships
`System/starts/_FirmwareCheck.sh` (with the `NEWEST_PAYLOAD` fallback) and
`trimui/firmwares/MinFwVersion.txt` (`1.1.1` / `20251128`). Hotfix
`.14`/`.15` never deployed those two files, so an SD installed from the
`v1.4.0-ce.2` image kept the base script that looked for
`firmware_tsp_v1.1.0_20250505.7z.001`. Run **Check Update** once after
this hotfix lands on `main` so existing cards pick it up.

Rebuild the zip from the tree after every rebase onto `main` (do not
hand-edit it). The payload also carries the current OTA scripts
(`update_notification.sh`, `update_ota_release.sh`); publishing a stale
zip would overwrite newer comparator/error-propagation fixes on
consoles:

```sh
sh _assets/scripts/build-hotfix-zip.sh
```

## 3b. System Tools → TOOLS → Firmware Update

Restored after #27 (product decision 2026-10-18). Path:
`Apps/SystemTools/Menu/TOOLS/Firmware Update.sh`.

What it does:

- Shows installed vs required firmware from `MinFwVersion.txt`.
- Downloads and verifies the `.7z.001`/`.002` payload from the latest
  release when missing or corrupt (~158 MB, Wi-Fi required).
- Optionally extracts `trimui_tg5040.awimg` to the SD root.
- Always ends on the **manual** flash steps (FAT32, awimg on root,
  console off, **VOLUME− + POWER** until the green bar).

What it does **not** do:

- It does not flash the console by itself.
- It does not claim that a reboot or the boot-time check writes the
  image unattended. That path is still not accredited on hardware.
  Section 2 remains the primary method.

## 4. Rollback

CrossMix, games and saves are on the SD. The flash does not delete them.
To return to the previous firmware, repeat section 2 with the previous
payload extracted to the same filename `trimui_tg5040.awimg`. Keep that
payload. If the console does not boot after a flash, boot without the
CrossMix card first and confirm whether the failure is the firmware or the
SD.

## 5. First CrossMix boot after a flash

A flash resets internal storage. That is expected. Stock UI with the SD
removed proves the console is healthy. A black screen **with** the SD is a
CrossMix install problem, not a brick.

On the next boots with the SD, `System/bin/ex_update.sh` runs
`System/updates/update_001.sh` because the completion stamp
`/etc/ex_update/001` lived in the storage the flash erased. The screen
`Installing TRIMUI_EX 001` is that script: it replaces busybox and unzips
`python.zip` (~82 MB compressed) onto the SD. **Do not reboot and do not
suspend it.** The stamp is written only at the end. An interrupted run
repeats the unzip. `update.log` reaching `Done!` for `001`, `002` and `00X`
means that pass finished.

Also expected, and not a failure by themselves:

- Several self-reboots while TRIMUI_EX / PortMaster reinstall.
- Factory settings and Wi-Fi credentials gone. SSH stays configured in
  `ex_config` and is still unreachable until Wi-Fi is set up again in the UI.
- `dimtime` defaults to 300 seconds. Sleep mid-scan does not resume cleanly.
  Raise it in the stock settings (SD removed) before the long first scan, or
  leave the console on a charger and wake it if it sleeps.
- macOS `._*` sidecar files (AppleDouble, magic `00 05 16 07`) in `Themes/`
  and `RetroArch/` make the theme loader and the first scan much slower.
  Delete only those sidecars; keep the real file next to each one.
- Menu caches `Apps/*/Menu/*cache7.db` are safe to delete. They rebuild.

`°customization.sh` from a December 2024 image copies a 7-line `preload.sh`
over the firmware one when the internal version stamp is missing. The
`v1.4.0-ce.2` tag no longer does that. An SD whose version file says
`1.4.0-ce.2` can still be carrying the old script. Compare the file with the
tag before assuming the image matches the version string.

Acceptance after recovery: CrossMix theme visible, one game launches and
returns to the menu, INFO still shows `1.1.1 / 20251128`.

## 6. The library: what actually stalls the menu

`Loading` / `cargando` after the CrossMix splash is MainUI building the game
list. A first scan of a large library is slow, but it finishes. If it never
finishes, the cause is not the firmware and is not the number of ROMs. Two
things have been verified on hardware, in this order:

1. **`Roms/favourite2.json` reproduced the hang, twice.** With that file in
   `Roms/`, every boot stayed on `cargando` indefinitely. Moved out to
   `Roms.off/`, the menu loaded on the first try, with the full library
   already restored. `recentlist.json` in the same folder is read fine.
   **The exact defect is not isolated** (issue #36): `favourite2.json` is
   line-delimited JSON — one object per line — read line by line by
   `Favorites - Sort.sh` and `Favorites - Fix No Emus.sh` (`jq empty` per
   line). A plain `json.load()` fails on it by design, so "not valid JSON" is
   the wrong test and the wrong conclusion. The hang is either one line that
   does not parse, or an entry whose `.launch` points at an emulator that is
   not present. Check both before rewriting the file:
   ```sh
   cd Roms
   # 1. every line must parse on its own
   while IFS= read -r l; do
     if [ -n "$l" ] && ! echo "$l" | jq empty >/dev/null 2>&1; then
       echo "BAD LINE: $l"
     fi
   done < favourite2.json
   # 2. every .launch must point at an emulator script that exists
   jq -r '.launch' favourite2.json | sed 's#^/mnt/SDCARD#/mnt/crossmix#' |
   while read -r p; do [ -f "$p" ] || echo "MISSING: $p"; done
   ```
2. **Volume alone did not reproduce it.** The library was restored in
   batches. Game Boy, GBC, SNES, Master System, Mega Drive, PSX and PSP
   scanned in seconds. The whole set was then moved in one go (110 systems,
   ~78 GB, NES with 3 224 files) and that boot also loaded. The stall was the
   JSON, not the size.

Rules that came out of it, for anyone doing the same:

- Move ROM folders only. Never move `favourite2.json`, `recentlist.json`,
  `*.launch` or `*.m3u` into `Roms/` from a backup: they are menu state, not
  ROMs, and a bad one blocks the launcher rather than one game.
- `MUSIC`, `VIDEOS`, `PORTS`, `PICO` and `SCUMMVM` folders contain playlists
  and launchers, not ROMs. They are not part of a library restore.
- When a console has no ROM folder, MainUI creates an empty stub with only
  `*_cache7.db`. Remove that stub before moving the real folder in, or the
  real folder ends up nested inside it.
- Do not delete `*_cache7.db` from a scan that already succeeded. It is the
  difference between a fast boot and a full rescan.
- `show.json` in `Emus/` is written by `Apps/EmuCleaner/launch.sh`. Keep a
  copy before editing it: a hand-edited `show.json` with the wrong set of
  `show` flags is another way to make the menu look wrong, and it was edited
  and restored during this session. The generated file is the reference.
- `Menu/*cache7.db` (app menus) and `Roms/*_cache7.db` (game lists) are
  different things. Only the app-menu ones are safe to delete blindly.

## 7. What this document does not authorize

- A custom boot logo. That is a firmware image change and needs its own
  permission, a backup, and a recovery image.
- Recompressing theme PNGs or swapping emulator cores as part of a flash.
  Those are separate issues (`#3`, `#6`). MainUI reads PNG/JPG; a smaller
  format it cannot decode is not an optimization.
- Treating a merged PR as a console that has been updated. A hotfix is the
  only channel that reaches an existing SD, and only for files the hotfix
  actually ships.

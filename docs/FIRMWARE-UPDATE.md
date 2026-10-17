# Firmware update — runbook (TrimUI Smart Pro / TG5040)

CrossMix-OS SE runs from the SD card and does **not** include the firmware: the
TrimUI firmware lives in internal storage. This document describes the flow the
device actually executes, taken from `System/starts/_FirmwareCheck.sh`, plus the
rollback plan.

## 1. Where the update lives

There is **no menu entry upstream**. The check runs at boot
(`System/starts/_FirmwareCheck.sh`). Since 1.4.0-ce.2.4 there is a manual entry:

**System Tools → TOOLS → Firmware Update**

It shows the current firmware, the required one and whether the payload is
present, then launches the same flow with an explicit A/B confirmation.

## 2. Prerequisites

| Item | Value |
|---|---|
| Payload | `trimui/firmwares/firmware_tsp_v1.1.1_20251128.7z.001` + `.002` (153 MB) |
| Minimum declared | `trimui/firmwares/MinFwVersion.txt` → `1.1.1` / `20251128` |
| Free space on SD | ≥ 1 GB (the payload is extracted to `trimui_tg5040.awimg` at the SD root) |
| Power | Console charged (> 50 %) or plugged in |
| Backup | Full SD image on a PC — non-negotiable before flashing |

If the payload is missing, download the two `.7z.00*` assets from the release
page and place them in `trimui/firmwares/` **with the exact names** — the script
builds the path from the file names.

## 3. What the flow does (code path)

1. Reads `DISTRIB_DESCRIPTION` from `/etc/openwrt_release` → current revision.
2. Compares it with `MinFwVersion.txt`; if current ≥ required → "Firmware version OK", removes any leftover `.awimg` and exits.
3. If current < required: swaps in the newer busybox, frees space (removes `zformatter_fat32`, `bgm2.mp3`, swapfile).
4. Backs up console settings with `Apps/SystemTools/Menu/TOOLS/FW Settings Save-Load.sh --backup` and records the backup name in `trimui/firmwares/Last_Automatic_Backup.txt`.
5. Extracts the payload with `7zz` → `/mnt/SDCARD/trimui_tg5040.awimg` and **verifies its CRC** against the archive.
6. Shows "Ready for update!": **A** continues (kills running apps and powers off after ~30 s), **B** cancels.
7. On the next boot the stock firmware finds `trimui_tg5040.awimg` at the SD root and flashes it. ⚠️ *This last step is the device's own bootloader, not CrossMix code — confirm on hardware the first time.*

## 4. Steps

1. Full SD backup to the PC.
2. Apply the latest hotfix (Check Update) so `_FirmwareCheck.sh` and `MinFwVersion.txt` are current.
3. System Tools → TOOLS → Firmware Update. Read the status line: current / required / payload.
4. If the payload is missing, copy the two parts into `trimui/firmwares/` and repeat step 3.
5. Press **A**. The console saves settings and powers off.
6. Power on and **do not touch it** while the firmware progress screen is shown. Do not remove the SD and do not power off mid-flash.
7. After it boots: check the version in the console info screen (expected `1.1.1` / `20251128`).
8. If settings were reset, restore them with `FW Settings Save-Load.sh --restore <backup>` (the path is in `trimui/firmwares/Last_Automatic_Backup.txt`).

## 5. Rollback

- CrossMix and the games live on the SD: a firmware flash does not touch them.
- To go back to a previous firmware, repeat the flow with the previous payload
  (`firmware_tsp_v<version>_<revision>.7z.001/.002`) placed in `trimui/firmwares/`.
  Keep the previous payload in the backup — it is the only way back.
- If the console does not boot after flashing: put a known-good payload on the SD,
  let the bootloader retry, and restore the SD image from the PC backup.

## 6. Known state (2026-10-17)

| Field | Console value |
|---|---|
| Firmware | 1.0.4 |
| Revision | 20240410 |
| Kernel | 4.9.191 |
| Required by CrossMix SE | 1.1.1 / 20251128 |

The console is **below** the minimum, and until 1.4.0-ce.2.3 the flow could never
run: `MinFwVersion.txt` declared `1.1.0/20250505` while the image shipped
`v1.1.1/20251128`, so the built path pointed at a file that did not exist.

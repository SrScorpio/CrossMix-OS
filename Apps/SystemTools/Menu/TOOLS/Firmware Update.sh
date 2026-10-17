#!/bin/sh
# CrossMix-OS SE - manual entry for the firmware check/update flow.
#
# The real flow lives in /mnt/SDCARD/System/starts/_FirmwareCheck.sh and runs
# automatically at boot: upstream has no menu item, so it is undiscoverable.
# This wrapper shows the real state and hands over to the official flow.
#
# UI: infoscreen2.sh (presenter) with the Scorpio Edition background - themed
# screen, centred text, labelled buttons. infoscreen.sh is NOT used: it paints
# a single line through sdl2imgshow.

export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"

FWFILE="/mnt/SDCARD/trimui/firmwares/MinFwVersion.txt"
FWDIR="/mnt/SDCARD/trimui/firmwares"
CHECK="/mnt/SDCARD/System/starts/_FirmwareCheck.sh"
I2="infoscreen2.sh"
BG="/mnt/SDCARD/trimui/res/crossmix-os/se/bg-firmware.png"
[ -f "$BG" ] || BG="bg-info.png"

LOG="/mnt/SDCARD/Apps/SystemTools/Logs/Firmware Update.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/tmp/firmware_update.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

say()  { $I2 -i "$BG" -m "$1" -fs 22 -fi 2 -p middle-center -fb -ts "${2:-6}"; }
ask()  { $I2 -i "$BG" -m "$1" -fs 20 -fi 2 -p middle-center -fb -k rout A "$2" -k rin B "$3"; }
back() { $I2 -i "$BG" -m "$1" -fs 20 -fi 2 -p middle-center -fb -k rout B "${2:-Back}"; }

log "--- start"

if [ ! -f "$FWFILE" ]; then
    back "Firmware update\n\nMissing file:\ntrimui/firmwares/MinFwVersion.txt\n\nApply the latest hotfix first."
    log "abort: MinFwVersion.txt missing"
    exit 1
fi

cur_rev=$(grep DISTRIB_DESCRIPTION /etc/openwrt_release | cut -d '.' -f 3)
cur_ver=$(cat /etc/version 2>/dev/null)
req_ver=$(sed -n '1p' "$FWFILE" | tr -d '\r ')
req_rev=$(sed -n '2p' "$FWFILE" | tr -d '\r ')
log "current=$cur_ver/$cur_rev required=$req_ver/$req_rev"

case "$cur_rev" in
    ''|*[!0-9]*)
        back "Firmware update\n\nCannot read the installed revision."
        log "abort: unreadable revision"
        exit 1
        ;;
esac

P1="$FWDIR/firmware_tsp_v${req_ver}_${req_rev}.7z.001"
payload=$(ls -1 "$FWDIR"/firmware_*_v*.7z.001 2>/dev/null | sort | tail -1)

# --- payload ausente: indicar la entrada de descarga ---
if [ -z "$payload" ]; then
    back "Firmware update\n\nInstalled    $cur_ver   ($cur_rev)\nRequired     $req_ver   ($req_rev)\nPayload      not on SD card\n\nRun  TOOLS / Firmware Download  first."
    log "abort: payload missing (use Firmware Download)"
    exit 1
fi

payload_ver=$(basename "$payload" | sed -n 's/^firmware_[a-z0-9]*_v\([0-9.]*\)_.*/\1/p')

# --- al dia? ---
if [ "$cur_rev" -ge "$req_rev" ]; then
    say "Firmware update\n\nInstalled    $cur_ver   ($cur_rev)\nRequired     $req_ver   ($req_rev)\n\nAlready up to date." 8
    log "up to date, exit"
    exit 0
fi

# --- confirmacion ---
ask "Firmware update\n\nInstalled    $cur_ver   ($cur_rev)\nRequired     $req_ver   ($req_rev)\nPayload      v$payload_ver  on SD\n\nBack up the SD card before continuing." "Update" "Cancel"
rc=$?
log "confirm rc=$rc"

if [ "$rc" -eq 14 ]; then
    log "handing over to _FirmwareCheck.sh"
    exec "$CHECK"
fi

log "cancelled by user"
exit 0

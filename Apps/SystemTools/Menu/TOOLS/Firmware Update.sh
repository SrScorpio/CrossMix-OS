#!/bin/sh
# CrossMix-OS SE - manual entry for the firmware check/update flow.
#
# The real flow lives in /mnt/SDCARD/System/starts/_FirmwareCheck.sh and runs
# automatically at boot: upstream has no menu item, so it is undiscoverable.
# This wrapper shows the real state and hands over to the official flow.
#
# UI: infoscreen.sh only, one short line per screen. It is the primitive
# verified to paint on this device, so no entry can end in a black screen.

export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"

FWFILE="/mnt/SDCARD/trimui/firmwares/MinFwVersion.txt"
FWDIR="/mnt/SDCARD/trimui/firmwares"
CHECK="/mnt/SDCARD/System/starts/_FirmwareCheck.sh"
I1="infoscreen.sh"

LOG="/mnt/SDCARD/Apps/SystemTools/Logs/Firmware Update.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/tmp/firmware_update.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
show() { log "$1"; $I1 -m "$1" -fs "${2:-18}" -t "${3:-4}"; }

log "--- start"

if [ -f /tmp/infoscreen_disabled ]; then
    log "clearing stale /tmp/infoscreen_disabled"
    rm -f /tmp/infoscreen_disabled
fi

if [ ! -f "$FWFILE" ]; then
    show "Missing trimui/firmwares/MinFwVersion.txt" 16 8
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
        show "Cannot read firmware revision" 16 8
        log "abort: unreadable revision"
        exit 1
        ;;
esac

show "Installed: $cur_ver / $cur_rev" 18 3

if [ "$cur_rev" -ge "$req_rev" ]; then
    show "Required $req_ver / $req_rev: up to date" 16 8
    log "up to date, exit"
    exit 0
fi

show "Required: $req_ver / $req_rev" 18 3

payload=$(ls -1 "$FWDIR"/firmware_*_v*.7z.001 2>/dev/null | sort | tail -1)

if [ -z "$payload" ]; then
    show "Payload missing: run Firmware Download" 15 8
    log "abort: payload missing (use Firmware Download)"
    exit 1
fi

payload_ver=$(basename "$payload" | sed -n 's/^firmware_[a-z0-9]*_v\([0-9.]*\)_.*/\1/p')
show "Payload ready: v$payload_ver" 18 3

button=$($I1 -m "Run firmware update?  A: yes  B: no" -fs 18 -k "A B")
log "button=$button"

if [ "$button" = "A" ]; then
    log "handing over to _FirmwareCheck.sh"
    exec "$CHECK"
fi

log "cancelled by user"
exit 0

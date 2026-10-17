#!/bin/sh
# CrossMix-OS SE - manual entry for the firmware check/update flow.
#
# The real flow lives in /mnt/SDCARD/System/starts/_FirmwareCheck.sh and runs
# automatically at boot: upstream has no menu item, so it is undiscoverable.
# This wrapper shows the actual state and hands over to the official flow.
#
# UI: infoscreen.sh, blocking, returns the pressed key - same pattern as the
# other TOOLS scripts. infoscreen2 in background does not work here: the
# subshell is killed when the menu entry returns, so nothing gets displayed.

export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"

FWFILE="/mnt/SDCARD/trimui/firmwares/MinFwVersion.txt"
CHECK="/mnt/SDCARD/System/starts/_FirmwareCheck.sh"
INFO="infoscreen.sh"
LOG="/mnt/SDCARD/Apps/SystemTools/Logs/Firmware Update.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/tmp/firmware_update.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

log "--- start"
log "FWFILE exists=$([ -f "$FWFILE" ] && echo yes || echo no) CHECK exists=$([ -f "$CHECK" ] && echo yes || echo no)"

if [ ! -f "$FWFILE" ]; then
    $INFO -m "Firmware check unavailable.

Missing file:
trimui/firmwares/MinFwVersion.txt

Apply the latest hotfix (Check Update)
or reinstall the SE payload." -fs 22 -t 8
    log "abort: MinFwVersion.txt missing"
    exit 1
fi

cur_rev=$(grep 'DISTRIB_DESCRIPTION' /etc/openwrt_release | cut -d '.' -f 3)
cur_ver=$(cat /etc/version 2>/dev/null)
req_ver=$(sed -n '1p' "$FWFILE" | tr -d '\r ')
req_rev=$(sed -n '2p' "$FWFILE" | tr -d '\r ')

payload=$(ls -1 /mnt/SDCARD/trimui/firmwares/firmware_*_v*.7z.001 2>/dev/null | sort | tail -1)
log "current=$cur_ver/$cur_rev required=$req_ver/$req_rev payload=$payload"

case "$cur_rev" in
    ''|*[!0-9]*)
        $INFO -m "Cannot read the installed firmware revision.

DISTRIB_DESCRIPTION:
$(grep 'DISTRIB_DESCRIPTION' /etc/openwrt_release)" -fs 20 -t 8
        log "abort: unreadable revision"
        exit 1
        ;;
esac

if [ -n "$payload" ]; then
    payload_name=$(basename "$payload")
else
    payload_name="NOT FOUND in trimui/firmwares"
fi

msg="Firmware status

Current  FW: $cur_ver - $cur_rev
Required FW: $req_ver - $req_rev
Payload: $payload_name"

if [ "$cur_rev" -ge "$req_rev" ]; then
    $INFO -m "$msg

Firmware is up to date.
Nothing to do." -fs 20 -t 8
    log "up to date, exit"
    exit 0
fi

if [ -z "$payload" ]; then
    $INFO -m "$msg

The update payload is missing.

Download firmware_tsp_v${req_ver}_${req_rev}.7z.001
and .002 from the SE release assets and
copy both into trimui/firmwares/." -fs 18 -t 12
    log "abort: payload missing"
    exit 1
fi

button=$($INFO -m "$msg

A: run the firmware update
B: cancel" -fs 20 -k "A B")
log "button=$button"

if [ "$button" = "A" ]; then
    log "handing over to _FirmwareCheck.sh"
    exec "$CHECK"
fi

log "cancelled by user"
exit 0

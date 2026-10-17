#!/bin/sh
# CrossMix-OS SE - manual entry for the firmware check/update flow.
#
# The real flow lives in /mnt/SDCARD/System/starts/_FirmwareCheck.sh and runs
# automatically at boot: upstream has no menu item, so it is undiscoverable.
# This wrapper shows the actual state, downloads the payload when it is missing,
# and hands over to the official flow.
#
# UI: infoscreen.sh renders with sdl2imgshow -t and paints a SINGLE line, so the
# status is shown as short one-line screens; the key prompt uses the blocking
# -k "A B" pattern of the other TOOLS entries.

export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"

FWFILE="/mnt/SDCARD/trimui/firmwares/MinFwVersion.txt"
FWDIR="/mnt/SDCARD/trimui/firmwares"
CHECK="/mnt/SDCARD/System/starts/_FirmwareCheck.sh"
INFO="infoscreen.sh"

LOG="/mnt/SDCARD/Apps/SystemTools/Logs/Firmware Update.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/tmp/firmware_update.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

log "--- start"

if [ ! -f "$FWFILE" ]; then
    $INFO -m "Missing trimui/firmwares/MinFwVersion.txt" -fs 18 -t 8
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
        $INFO -m "Cannot read firmware revision" -fs 20 -t 6
        log "abort: unreadable revision"
        exit 1
        ;;
esac

$INFO -m "FW installed: $cur_ver / $cur_rev" -fs 20 -t 4

if [ "$cur_rev" -ge "$req_rev" ]; then
    $INFO -m "Required: $req_ver / $req_rev - up to date" -fs 18 -t 8
    log "up to date, exit"
    exit 0
fi

$INFO -m "FW required: $req_ver / $req_rev" -fs 20 -t 4

P1="$FWDIR/firmware_tsp_v${req_ver}_${req_rev}.7z.001"
P2="${P1%.001}.002"
payload=$(ls -1 "$FWDIR"/firmware_*_v*.7z.001 2>/dev/null | sort | tail -1)

# --- payload ausente: se descarga desde la entrada Firmware Download ---
if [ -z "$payload" ]; then
    $INFO -m "Payload missing - run Firmware Download first" -fs 15 -t 10
    log "abort: payload missing (use Firmware Download)"
    exit 1
fi

payload_ver=$(basename "$payload" | sed -n 's/^firmware_[a-z0-9]*_v\([0-9.]*\)_.*/\1/p')
$INFO -m "Payload ready: v$payload_ver" -fs 20 -t 4

button=$($INFO -m "Run firmware update? A: yes  B: no" -fs 20 -k "A B")
log "button=$button"

if [ "$button" = "A" ]; then
    log "handing over to _FirmwareCheck.sh"
    exec "$CHECK"
fi

log "cancelled by user"
exit 0

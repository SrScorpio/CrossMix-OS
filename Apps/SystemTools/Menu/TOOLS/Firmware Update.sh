#!/bin/sh
# CrossMix-OS SE - manual entry for the upstream firmware check/update flow.
#
# Deliberately thin: it verifies that the payload is on the card and hands over
# to /mnt/SDCARD/System/starts/_FirmwareCheck.sh, the official flow with its own
# screens and rollback logic. No custom UI here.
#
# The payload is downloaded by the hotfix channel during Check Update, so this
# entry never fetches anything and nothing depends on the user pressing keys.

export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"

FWFILE="/mnt/SDCARD/trimui/firmwares/MinFwVersion.txt"
FWDIR="/mnt/SDCARD/trimui/firmwares"
CHECK="/mnt/SDCARD/System/starts/_FirmwareCheck.sh"
I1="infoscreen.sh"

LOG="/mnt/SDCARD/Apps/SystemTools/Logs/Firmware Update.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/tmp/firmware_update.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# flag de modo silencioso que puede dejar una actualizacion interrumpida
[ -f /tmp/infoscreen_disabled ] && rm -f /tmp/infoscreen_disabled

log "--- start"

if [ ! -f "$FWFILE" ]; then
    log "abort: MinFwVersion.txt missing"
    $I1 -m "Firmware check unavailable - missing MinFwVersion.txt" -fs 16 -t 10
    exit 1
fi

payload=$(ls -1 "$FWDIR"/firmware_*_v*.7z.001 2>/dev/null | sort | tail -1)

if [ -z "$payload" ]; then
    log "abort: payload missing"
    $I1 -m "Firmware payload not on SD - run Check Update" -fs 16 -t 10
    exit 1
fi

log "payload=$payload - handing over to _FirmwareCheck.sh"
exec "$CHECK"

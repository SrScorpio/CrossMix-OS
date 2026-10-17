#!/bin/sh
# CrossMix-OS SE - download the firmware payload into the SD.
#
# Separate from "Firmware Update" on purpose: downloading 158 MB is one job,
# flashing is another. This entry fetches the two archive parts that match
# MinFwVersion.txt, stores them in trimui/firmwares/ and validates the archive,
# so the update entry finds everything ready.
#
# UI: infoscreen.sh paints a single line (sdl2imgshow -t), hence short screens.

export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"

FWFILE="/mnt/SDCARD/trimui/firmwares/MinFwVersion.txt"
FWDIR="/mnt/SDCARD/trimui/firmwares"
INFO="infoscreen.sh"
WGET="/mnt/SDCARD/System/bin/wget"
SEVENZ="/mnt/SDCARD/System/bin/7zz"
[ -x "$WGET" ] || WGET="wget"
[ -x "$SEVENZ" ] || SEVENZ="7zz"
DL_BASE="https://github.com/SrScorpio/CrossMix-OS-SE/releases/latest/download"

LOG="/mnt/SDCARD/Apps/SystemTools/Logs/Firmware Download.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/tmp/firmware_download.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

busy() { $INFO -m "$1" -fs 18 -t 900 & echo $!; }
stop_busy() { kill "$1" 2>/dev/null; pkill -f sdl2imgshow 2>/dev/null; }
size_mb() { echo $(( $(stat -c %s "$1" 2>/dev/null || echo 0) / 1048576 ))MB; }

log "--- start"

if [ ! -f "$FWFILE" ]; then
    $INFO -m "Missing trimui/firmwares/MinFwVersion.txt" -fs 18 -t 8
    log "abort: MinFwVersion.txt missing"
    exit 1
fi

req_ver=$(sed -n '1p' "$FWFILE" | tr -d '\r ')
req_rev=$(sed -n '2p' "$FWFILE" | tr -d '\r ')
mkdir -p "$FWDIR"

P1="$FWDIR/firmware_tsp_v${req_ver}_${req_rev}.7z.001"
P2="${P1%.001}.002"
log "target=$req_ver/$req_rev p1=$P1 p2=$P2"

$INFO -m "Firmware payload v$req_ver / $req_rev" -fs 18 -t 4

# --- ya presente y valido? ---
if [ -f "$P1" ] && [ -f "$P2" ]; then
    $INFO -m "Already on SD ($(size_mb "$P1") + $(size_mb "$P2"))" -fs 16 -t 4
    pid=$(busy "Checking the archive...")
    "$SEVENZ" t "$P1" >/tmp/fw_dl_verify.log 2>&1
    vrc=$?
    stop_busy "$pid"
    log "already present, 7zz test rc=$vrc"
    if [ "$vrc" -eq 0 ]; then
        $INFO -m "Payload OK - nothing to download" -fs 18 -t 8
        exit 0
    fi
    $INFO -m "Payload corrupt - downloading again" -fs 16 -t 4
    rm -f "$P1" "$P2"
fi

# --- confirmar descarga (~158 MB) ---
button=$($INFO -m "Download $req_ver payload? ~158MB  A: yes  B: no" -fs 14 -k "A B")
log "confirm button=$button"
[ "$button" = "A" ] || { log "declined"; exit 0; }

pid=$(busy "Downloading part 1 of 2 - do not power off")
"$WGET" -q -O "$P1" "$DL_BASE/$(basename "$P1")"
rc1=$?
stop_busy "$pid"
log "p1 rc=$rc1 size=$(size_mb "$P1")"

pid=$(busy "Downloading part 2 of 2 - do not power off")
"$WGET" -q -O "$P2" "$DL_BASE/$(basename "$P2")"
rc2=$?
stop_busy "$pid"
log "p2 rc=$rc2 size=$(size_mb "$P2")"

if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
    $INFO -m "Download failed - check WiFi and retry" -fs 18 -t 10
    rm -f "$P1" "$P2"
    log "abort: download failed"
    exit 1
fi

# --- verificar ---
pid=$(busy "Verifying the archive...")
"$SEVENZ" t "$P1" >/tmp/fw_dl_verify.log 2>&1
vrc=$?
stop_busy "$pid"
log "7zz test rc=$vrc"
if [ "$vrc" -ne 0 ]; then
    $INFO -m "Archive corrupt - files deleted" -fs 18 -t 10
    rm -f "$P1" "$P2"
    exit 1
fi

$INFO -m "Done: $(size_mb "$P1") + $(size_mb "$P2") verified" -fs 16 -t 5
$INFO -m "Ready: TOOLS / Firmware Update" -fs 18 -t 8
log "done"
exit 0

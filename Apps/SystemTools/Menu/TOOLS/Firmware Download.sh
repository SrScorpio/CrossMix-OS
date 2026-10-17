#!/bin/sh
# CrossMix-OS SE - download the firmware payload into the SD card.
#
# UI: infoscreen.sh only. It is the primitive verified to paint on this device,
# so the flow can never end in a black screen. One short line per screen, plus
# a text progress bar during the download.

export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"

FWFILE="/mnt/SDCARD/trimui/firmwares/MinFwVersion.txt"
FWDIR="/mnt/SDCARD/trimui/firmwares"
I1="infoscreen.sh"
WGET="/mnt/SDCARD/System/bin/wget"
SEVENZ="/mnt/SDCARD/System/bin/7zz"
[ -x "$WGET" ] || WGET="wget"
[ -x "$SEVENZ" ] || SEVENZ="7zz"
DL_BASE="https://github.com/SrScorpio/CrossMix-OS-SE/releases/latest/download"

SIZE_P1=102760448
SIZE_P2=55340257

LOG="/mnt/SDCARD/Apps/SystemTools/Logs/Firmware Download.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/tmp/firmware_download.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

show() { log "$1"; $I1 -m "$1" -fs "${2:-18}" -t "${3:-4}"; }

# barra de 20 bloques a partir del porcentaje
bar() {
    n=$(( $1 / 5 ))
    [ "$n" -gt 20 ] && n=20
    s=""; i=1
    while [ "$i" -le 20 ]; do
        if [ "$i" -le "$n" ]; then s="${s}#"; else s="${s}-"; fi
        i=$((i + 1))
    done
    echo "$s"
}

# Descarga con progreso. $1 url  $2 destino  $3 bytes  $4 "Part x/y"
dl_part() {
    url="$1"; dest="$2"; total="$3"; title="$4"
    "$WGET" -q -T 30 -t 2 -O "$dest.part" "$url" &
    dl_pid=$!
    stall=0; last=-1

    while kill -0 "$dl_pid" 2>/dev/null; do
        cur=$(stat -c %s "$dest.part" 2>/dev/null || echo 0)
        mb=$((cur / 1048576))
        total_mb=$((total / 1048576))
        [ "$total" -gt 0 ] && pct=$((cur * 100 / total)) || pct=0
        [ "$pct" -gt 100 ] && pct=100
        $I1 -m "$title $pct% [$(bar "$pct")] $mb/$total_mb" -fs 16 -t 2
        if [ "$cur" -le "$last" ]; then
            stall=$((stall + 1))
        else
            stall=0
        fi
        last=$cur
        if [ "$stall" -ge 30 ]; then
            log "stall at $mb MB, aborting"
            kill "$dl_pid" 2>/dev/null
            break
        fi
    done

    wait "$dl_pid" 2>/dev/null
    rc=$?
    [ "$rc" -eq 0 ] && [ -s "$dest.part" ] && mv -f "$dest.part" "$dest"
    return "$rc"
}

log "--- start"

# infoscreen2 sale en silencio si quedo el flag de "modo silencioso" de una
# actualizacion interrumpida; se limpia antes de pintar nada.
if [ -f /tmp/infoscreen_disabled ]; then
    log "clearing stale /tmp/infoscreen_disabled"
    rm -f /tmp/infoscreen_disabled
fi

if [ ! -f "$FWFILE" ]; then
    show "Missing trimui/firmwares/MinFwVersion.txt" 16 8
    log "abort: MinFwVersion.txt missing"
    exit 1
fi

req_ver=$(sed -n '1p' "$FWFILE" | tr -d '\r ')
req_rev=$(sed -n '2p' "$FWFILE" | tr -d '\r ')
mkdir -p "$FWDIR"

P1="$FWDIR/firmware_tsp_v${req_ver}_${req_rev}.7z.001"
P2="${P1%.001}.002"
log "target=$req_ver/$req_rev"

show "Firmware payload v$req_ver / $req_rev" 18 3

if [ -f "$P1" ] && [ -f "$P2" ]; then
    show "Already on SD - verifying..." 16 3
    "$SEVENZ" t "$P1" >/tmp/fw_dl_verify.log 2>&1
    vrc=$?
    log "already present, 7zz rc=$vrc"
    if [ "$vrc" -eq 0 ]; then
        show "Payload OK - nothing to download" 18 8
        exit 0
    fi
    show "Payload corrupt - downloading again" 16 4
    rm -f "$P1" "$P2"
fi

button=$($I1 -m "Download v$req_ver (~158 MB)?  A: yes  B: no" -fs 16 -k "A B")
log "confirm=$button"
[ "$button" = "A" ] || { log "declined"; exit 0; }

rm -f "$P1" "$P2" "${P1}.part" "${P2}.part"

log "downloading part1"
dl_part "$DL_BASE/$(basename "$P1")" "$P1" "$SIZE_P1" "Part 1/2"
rc1=$?
log "p1 rc=$rc1"

if [ "$rc1" -ne 0 ]; then
    rm -f "$P1" "${P1}.part" "$P2" "${P2}.part"
    show "Part 1 failed - check WiFi, retry" 16 10
    log "abort: part1 failed"
    exit 1
fi

log "downloading part2"
dl_part "$DL_BASE/$(basename "$P2")" "$P2" "$SIZE_P2" "Part 2/2"
rc2=$?
log "p2 rc=$rc2"

if [ "$rc2" -ne 0 ]; then
    rm -f "$P1" "${P1}.part" "$P2" "${P2}.part"
    show "Part 2 failed - check WiFi, retry" 16 10
    log "abort: part2 failed"
    exit 1
fi

show "Verifying archive..." 16 3
"$SEVENZ" t "$P1" >/tmp/fw_dl_verify.log 2>&1
vrc=$?
log "7zz rc=$vrc"

if [ "$vrc" -ne 0 ]; then
    rm -f "$P1" "$P2"
    show "Archive corrupt - files deleted" 16 10
    exit 1
fi

mb1=$(( $(stat -c %s "$P1") / 1048576 ))
mb2=$(( $(stat -c %s "$P2") / 1048576 ))
show "Done: ${mb1} MB + ${mb2} MB verified" 16 6
show "Next: TOOLS / Firmware Update" 18 8
log "done"
exit 0

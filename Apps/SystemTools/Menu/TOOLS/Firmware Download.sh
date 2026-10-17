#!/bin/sh
# CrossMix-OS SE - download the firmware payload into the SD card.
#
# Separate from "Firmware Update" on purpose: downloading 158 MB is one job,
# flashing is another. This entry fetches the two archive parts that match
# MinFwVersion.txt, verifies them and leaves them in trimui/firmwares/.
#
# UI: infoscreen2.sh (presenter) with the Scorpio Edition background, same
# screen style as the rest of CrossMix: centred text, animated spinner and
# labelled buttons. The progress loop repaints every 4 s, so the spinner keeps
# moving and the percentage stays honest - a still screen means a dead download.

export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"

FWFILE="/mnt/SDCARD/trimui/firmwares/MinFwVersion.txt"
FWDIR="/mnt/SDCARD/trimui/firmwares"
I2="infoscreen2.sh"
BG="/mnt/SDCARD/trimui/res/crossmix-os/se/bg-firmware.png"
[ -f "$BG" ] || BG="bg-info.png"
WGET="/mnt/SDCARD/System/bin/wget"
SEVENZ="/mnt/SDCARD/System/bin/7zz"
[ -x "$WGET" ] || WGET="wget"
[ -x "$SEVENZ" ] || SEVENZ="7zz"
DL_BASE="https://github.com/SrScorpio/CrossMix-OS-SE/releases/latest/download"

# Tamaños de los assets del release (bytes), solo para el porcentaje
SIZE_P1=102760448
SIZE_P2=55340257

LOG="/mnt/SDCARD/Apps/SystemTools/Logs/Firmware Download.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/tmp/firmware_download.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

say()  { $I2 -i "$BG" -m "$1" -fs 22 -fi 2 -p middle-center -fb -ts "${2:-6}"; }
spin() { $I2 -i "$BG" -sp -m "$1" -fs 20 -fi 2 -p middle-center -fb -ts "${2:-4}"; }
back() { $I2 -i "$BG" -m "$1" -fs 20 -fi 2 -p middle-center -fb -k rout B "${2:-Back}"; }

# Descarga con progreso visible. $1 url  $2 destino  $3 bytes  $4 titulo
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
        spin "$title\n\n$pct%\n\n$mb of $total_mb MB" 4
        if [ "$cur" -le "$last" ]; then
            stall=$((stall + 1))
        else
            stall=0
        fi
        last=$cur
        if [ "$stall" -ge 8 ]; then
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

if [ ! -f "$FWFILE" ]; then
    back "Firmware download\n\nMissing file:\ntrimui/firmwares/MinFwVersion.txt"
    log "abort: MinFwVersion.txt missing"
    exit 1
fi

req_ver=$(sed -n '1p' "$FWFILE" | tr -d '\r ')
req_rev=$(sed -n '2p' "$FWFILE" | tr -d '\r ')
mkdir -p "$FWDIR"

P1="$FWDIR/firmware_tsp_v${req_ver}_${req_rev}.7z.001"
P2="${P1%.001}.002"
log "target=$req_ver/$req_rev"

# --- ya presente y valido? ---
if [ -f "$P1" ] && [ -f "$P2" ]; then
    "$SEVENZ" t "$P1" >/tmp/fw_dl_verify.log 2>&1 &
    vpid=$!
    while kill -0 "$vpid" 2>/dev/null; do
        spin "Firmware payload\n\nAlready on the SD card\n\nVerifying..." 4
    done
    wait "$vpid" 2>/dev/null
    vrc=$?
    log "already present, 7zz test rc=$vrc"
    if [ "$vrc" -eq 0 ]; then
        say "Firmware payload\n\nv$req_ver   ($req_rev)\n\nAlready on the SD card\nand verified.\n\nNothing to download." 8
        exit 0
    fi
    say "Firmware payload\n\nThe files on the SD are corrupt.\nDownloading them again." 6
    rm -f "$P1" "$P2"
fi

# --- confirmacion ---
$I2 -i "$BG" -m "Firmware payload\n\nVersion      $req_ver   ($req_rev)\nSize         ~158 MB\nDestination  trimui/firmwares\n\nDownload now?" \
    -fs 20 -fi 2 -p middle-center -fb \
    -k rout A "Download" -k rin B "Cancel"
rc=$?
log "confirm rc=$rc"
[ "$rc" -eq 14 ] || { log "declined"; exit 0; }

rm -f "$P1" "$P2" "${P1}.part" "${P2}.part"

log "downloading part1"
dl_part "$DL_BASE/$(basename "$P1")" "$P1" "$SIZE_P1" "Part 1 of 2\n\nDownloading firmware"
rc1=$?
log "p1 rc=$rc1"

if [ "$rc1" -ne 0 ]; then
    rm -f "$P1" "${P1}.part" "$P2" "${P2}.part"
    back "Firmware download\n\nPart 1 failed.\n\nCheck the WiFi connection and try again."
    log "abort: part1 failed"
    exit 1
fi

log "downloading part2"
dl_part "$DL_BASE/$(basename "$P2")" "$P2" "$SIZE_P2" "Part 2 of 2\n\nDownloading firmware"
rc2=$?
log "p2 rc=$rc2"

if [ "$rc2" -ne 0 ]; then
    rm -f "$P1" "${P1}.part" "$P2" "${P2}.part"
    back "Firmware download\n\nPart 2 failed.\n\nCheck the WiFi connection and try again."
    log "abort: part2 failed"
    exit 1
fi

# --- verificar ---
"$SEVENZ" t "$P1" >/tmp/fw_dl_verify.log 2>&1 &
vpid=$!
while kill -0 "$vpid" 2>/dev/null; do
    spin "Verifying the firmware archive...\n\nPlease wait" 4
done
wait "$vpid" 2>/dev/null
vrc=$?
log "7zz test rc=$vrc"

if [ "$vrc" -ne 0 ]; then
    rm -f "$P1" "$P2"
    back "Firmware download\n\nThe archive is corrupt.\nThe files were deleted."
    exit 1
fi

mb1=$(( $(stat -c %s "$P1") / 1048576 ))
mb2=$(( $(stat -c %s "$P2") / 1048576 ))
say "Firmware payload\n\nv$req_ver   ($req_rev)\n\nPart 1   $mb1 MB\nPart 2   $mb2 MB\nVerified OK" 6
$I2 -i "$BG" -m "Ready\n\nNext step:\nTOOLS / Firmware Update" -fs 22 -fi 2 -p middle-center -fb -ts 8
log "done"
exit 0

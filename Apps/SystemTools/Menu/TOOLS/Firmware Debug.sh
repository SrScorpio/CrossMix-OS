#!/bin/sh
# CrossMix-OS SE - self check for the firmware entries.
#
# Diagnoses why a firmware screen may not render: verifies the UI helpers,
# scratch space, network, MinFwVersion and the payload, and prints one short
# line per check with infoscreen.sh (the primitive that always paints), then
# writes the same data to Apps/SystemTools/Logs/Firmware Debug.log.

export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"

I1="infoscreen.sh"
LOG="/mnt/SDCARD/Apps/SystemTools/Logs/Firmware Debug.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/tmp/firmware_debug.log"
log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
show() { log "$1"; $I1 -m "$1" -fs "${2:-18}" -t 3; }

: > "$LOG"
log "=== debug start"

# flag de modo silencioso (hace que infoscreen2 salga sin pintar)
if [ -f /tmp/infoscreen_disabled ]; then
    show "infoscreen_disabled: PRESENT" 16
    rm -f /tmp/infoscreen_disabled
    log "removed stale /tmp/infoscreen_disabled"
else
    show "infoscreen_disabled: absent" 14
fi

# prueba real de infoscreen2 (presenter)
if command -v infoscreen2.sh >/dev/null 2>&1; then
    infoscreen2.sh -m "UI test - infoscreen2" -fs 16 -fi 0 -p top-left -fb -ts 2 >/tmp/fw_dbg_i2.log 2>&1
    i2rc=$?
    log "infoscreen2 rc=$i2rc out=$(tail -3 /tmp/fw_dbg_i2.log | tr '\n' ' ')"
    show "infoscreen2 test rc=$i2rc" 14
else
    show "infoscreen2: not in PATH" 16
fi

# 1) helpers de UI
for b in infoscreen.sh infoscreen2.sh presenter; do
    p=$(command -v "$b" 2>/dev/null)
    [ -z "$p" ] && [ -x "/mnt/SDCARD/System/bin/$b" ] && p="/mnt/SDCARD/System/bin/$b"
    [ -z "$p" ] && [ -x "/mnt/SDCARD/System/usr/trimui/scripts/$b" ] && p="/mnt/SDCARD/System/usr/trimui/scripts/$b"
    if [ -n "$p" ]; then
        show "$b: OK" 16
    else
        show "$b: MISSING" 16
    fi
done

# 2) fondo SE y fuente del tema
[ -f /mnt/SDCARD/trimui/res/crossmix-os/se/bg-firmware.png ] \
    && show "SE background: OK" 16 || show "SE background: MISSING" 16

# 3) espacio libre
free_kb=$(df /mnt/SDCARD | awk 'NR==2 {print $4}')
free_mb=$((free_kb / 1024))
show "SD free: ${free_mb} MB" 16

# 4) red
if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
    show "Network: OK" 16
else
    show "Network: NO PING" 16
fi

# 5) versiones
cur_rev=$(grep DISTRIB_DESCRIPTION /etc/openwrt_release | cut -d '.' -f 3)
cur_ver=$(cat /etc/version 2>/dev/null)
show "FW installed: $cur_ver / $cur_rev" 16

if [ -f /mnt/SDCARD/trimui/firmwares/MinFwVersion.txt ]; then
    req_ver=$(sed -n '1p' /mnt/SDCARD/trimui/firmwares/MinFwVersion.txt | tr -d '\r ')
    req_rev=$(sed -n '2p' /mnt/SDCARD/trimui/firmwares/MinFwVersion.txt | tr -d '\r ')
    show "FW required: $req_ver / $req_rev" 16
else
    show "MinFwVersion.txt: MISSING" 16
fi

# 6) payload
p1=$(ls -1 /mnt/SDCARD/trimui/firmwares/firmware_*_v*.7z.001 2>/dev/null | sort | tail -1)
if [ -n "$p1" ]; then
    mb=$(( $(stat -c %s "$p1") / 1048576 ))
    show "Payload part 1: ${mb} MB" 16
    if [ -x /mnt/SDCARD/System/bin/7zz ]; then
        /mnt/SDCARD/System/bin/7zz t "$p1" >/tmp/fw_dbg_7zz.log 2>&1
        [ $? -eq 0 ] && show "Archive: VALID" 16 || show "Archive: CORRUPT" 16
        log "7zz: $(tail -2 /tmp/fw_dbg_7zz.log | tr '\n' ' ')"
    else
        show "7zz: MISSING" 16
    fi
else
    show "Payload: not on SD" 16
fi

# 7) versiones CrossMix / hotfix
cv=$(cat /mnt/SDCARD/System/usr/trimui/crossmix-version.txt 2>/dev/null)
hv=$(cat /mnt/SDCARD/System/usr/trimui/crossmix-hotfix-version.txt 2>/dev/null)
show "CrossMix $cv  hotfix $hv" 14
log "crossmix=$cv hotfix=$hv"

log "=== debug end"
$I1 -m "Log: Apps/SystemTools/Logs/Firmware Debug.log" -fs 14 -t 6
exit 0

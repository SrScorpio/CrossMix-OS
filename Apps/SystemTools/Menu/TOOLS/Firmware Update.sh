#!/bin/sh
# CrossMix-OS SE - manual entry point for the firmware check/update flow.
#
# The real flow lives in /mnt/SDCARD/System/starts/_FirmwareCheck.sh and runs
# automatically at boot, which makes it invisible: there is no menu item
# upstream. This wrapper exposes it from System Tools and shows the current
# state (current FW, required FW, bundled payload) before doing anything.

export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"

FWFILE="/mnt/SDCARD/trimui/firmwares/MinFwVersion.txt"
CHECK="/mnt/SDCARD/System/starts/_FirmwareCheck.sh"
INFOSCREEN="/mnt/SDCARD/System/usr/trimui/scripts/infoscreen2.sh"
FONT="/mnt/SDCARD/Themes/CrossMix - OS/wqy-microhei.ttf"
[ -f "$FONT" ] || FONT="/mnt/SDCARD/System/res/font.ttf"

show() { # show <mensaje>  (informativo, se cierra solo)
    $INFOSCREEN -m "$1" -fs 12 -fi 0 -p top-left -fb -ff "$FONT" &
    sleep 5
    pkill -f infoscreen2
}

if [ ! -f "$FWFILE" ]; then
    show "Firmware check unavailable\n \nMissing: trimui/firmwares/MinFwVersion.txt\nReinstall the SE payload or apply the latest hotfix."
    exit 1
fi

if [ ! -x "$CHECK" ] && [ ! -f "$CHECK" ]; then
    show "Firmware check unavailable\n \nMissing: System/starts/_FirmwareCheck.sh"
    exit 1
fi

cur_rev=$(grep 'DISTRIB_DESCRIPTION' /etc/openwrt_release | cut -d '.' -f 3)
cur_ver=$(cat /etc/version 2>/dev/null)
req_ver=$(sed -n '1p' "$FWFILE" | tr -d '\r ')
req_rev=$(sed -n '2p' "$FWFILE" | tr -d '\r ')

# Newest bundled payload, same rule as _FirmwareCheck.sh
payload=$(ls -1 /mnt/SDCARD/trimui/firmwares/firmware_*_v*.7z.001 2>/dev/null | sort | tail -1)
if [ -n "$payload" ]; then
    payload_info="Payload: $(basename "$payload")"
else
    payload_info="Payload: NOT FOUND in trimui/firmwares"
fi

msg="Firmware status\n \nCurrent FW:  ${cur_ver:-unknown} - ${cur_rev:-unknown}\nRequired FW: $req_ver - $req_rev\n$payload_info\n \n"

case "$cur_rev" in
    ''|*[!0-9]*)
        show "${msg}Cannot read the installed firmware revision."
        exit 1
        ;;
esac

if [ "$cur_rev" -ge "$req_rev" ]; then
    show "${msg}Firmware is up to date. Nothing to do."
    exit 0
fi

if [ -z "$payload" ]; then
    show "${msg}The update payload is missing.\nDownload it from the SE release assets\nand place it in trimui/firmwares/."
    exit 1
fi

$INFOSCREEN -m "${msg}A: run the firmware update flow\nB: cancel" -fs 12 -fi 0 -p top-left -fb -ff "$FONT" -k rout A "" -k rin B ""
if [ "$?" -eq 14 ]; then
    pkill -f infoscreen2
    exec "$CHECK"
fi
pkill -f infoscreen2
exit 0

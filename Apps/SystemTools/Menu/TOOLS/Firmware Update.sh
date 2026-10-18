#!/bin/sh
# CrossMix-OS SE - System Tools → TOOLS → Firmware Update
#
# What this entry does:
#   - reads installed firmware vs MinFwVersion.txt
#   - downloads/verifies the payload (.7z.001/.002) when missing
#   - shows the manufacturer's manual flash steps (VOL− + POWER)
#
# What it does NOT do:
#   - it does not flash the console by itself
#   - it does not promise that a reboot or the boot-time check will write
#     the image unattended (that path is not accredited on hardware)
#
# Primary flash method (always):
#   put trimui_tg5040.awimg on the root of a FAT32 card, console off,
#   hold VOLUME− + POWER until the green bar, then release.

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

LOG="/mnt/SDCARD/Apps/SystemTools/Logs/Firmware Update.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/tmp/firmware_update.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

show() { log "$1"; $I1 -m "$1" -fs "${2:-16}" -t "${3:-4}"; }
busy() { $I1 -m "$1" -fs 16 -t 900 & echo $!; }
stop_busy() { kill "$1" 2>/dev/null; pkill -f sdl2imgshow 2>/dev/null; }
size_mb() { echo $(($(stat -c %s "$1" 2>/dev/null || echo 0) / 1048576)); }

# stale silent-mode flag can leave screens blank
[ -f /tmp/infoscreen_disabled ] && rm -f /tmp/infoscreen_disabled

log "--- start"

if [ ! -f "$FWFILE" ]; then
	show "Missing MinFwVersion.txt - run Check Update" 15 10
	exit 1
fi

cur_rev=$(grep 'DISTRIB_DESCRIPTION' /etc/openwrt_release 2>/dev/null | cut -d '.' -f 3)
cur_ver=$(cat /etc/version 2>/dev/null)
req_ver=$(sed -n '1p' "$FWFILE" | tr -d '\r ')
req_rev=$(sed -n '2p' "$FWFILE" | tr -d '\r ')
log "current=$cur_ver/$cur_rev required=$req_ver/$req_rev"

show "Installed: ${cur_ver:-?} / ${cur_rev:-?}  Target: $req_ver / $req_rev" 14 5

case "$cur_rev" in
'' | *[!0-9]*)
	# still allow download/instructions even if revision parse failed
	log "warn: unreadable installed revision"
	;;
*)
	if [ -n "$req_rev" ] && [ "$cur_rev" -ge "$req_rev" ] 2>/dev/null; then
		show "Firmware already at or above target" 16 5
	fi
	;;
esac

mkdir -p "$FWDIR"
P1="$FWDIR/firmware_tsp_v${req_ver}_${req_rev}.7z.001"
P2="${P1%.001}.002"

# Prefer the exact MinFwVersion payload; fall back to any bundled part.
payload=""
if [ -f "$P1" ]; then
	payload="$P1"
else
	payload=$(ls -1 "$FWDIR"/firmware_*_v*.7z.001 2>/dev/null | sort | tail -1)
fi

need_dl=0
if [ -z "$payload" ] || [ ! -f "$payload" ]; then
	need_dl=1
else
	pid=$(busy "Checking payload archive...")
	"$SEVENZ" t "$payload" >/tmp/fw_menu_verify.log 2>&1
	vrc=$?
	stop_busy "$pid"
	log "7zz test rc=$vrc path=$payload"
	if [ "$vrc" -ne 0 ]; then
		show "Payload corrupt - will re-download" 15 4
		rm -f "$payload" "${payload%.001}.002" 2>/dev/null
		need_dl=1
		payload=""
	else
		show "Payload OK: $(basename "$payload") ($(size_mb "$payload") MB)" 14 4
	fi
fi

if [ "$need_dl" -eq 1 ]; then
	if [ -z "$req_ver" ] || [ -z "$req_rev" ]; then
		show "Cannot download: bad MinFwVersion.txt" 15 8
		exit 1
	fi
	P1="$FWDIR/firmware_tsp_v${req_ver}_${req_rev}.7z.001"
	P2="${P1%.001}.002"
	button=$($I1 -m "Download payload ~158MB? A:yes B:skip" -fs 14 -k "A B")
	log "download confirm=$button"
	if [ "$button" = "A" ]; then
		pid=$(busy "Downloading part 1/2 - keep WiFi on")
		"$WGET" -q -T 30 -t 3 -O "$P1" "$DL_BASE/$(basename "$P1")"
		rc1=$?
		stop_busy "$pid"
		log "p1 rc=$rc1 size=$(size_mb "$P1")"
		pid=$(busy "Downloading part 2/2 - keep WiFi on")
		"$WGET" -q -T 30 -t 3 -O "$P2" "$DL_BASE/$(basename "$P2")"
		rc2=$?
		stop_busy "$pid"
		log "p2 rc=$rc2 size=$(size_mb "$P2")"
		if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ] || [ ! -s "$P1" ]; then
			show "Download failed - check WiFi, retry" 15 10
			rm -f "$P1" "$P2"
			exit 1
		fi
		pid=$(busy "Verifying archive...")
		"$SEVENZ" t "$P1" >/tmp/fw_menu_verify.log 2>&1
		vrc=$?
		stop_busy "$pid"
		if [ "$vrc" -ne 0 ]; then
			show "Archive invalid - deleted" 16 8
			rm -f "$P1" "$P2"
			exit 1
		fi
		payload="$P1"
		show "Download OK ($(size_mb "$P1")+$(size_mb "$P2") MB)" 14 5
	else
		log "download skipped"
		if [ -z "$payload" ]; then
			show "No payload on SD - cannot prepare .awimg" 14 8
		fi
	fi
fi

# Offer optional extract of trimui_tg5040.awimg to SD root (manual flash input)
awimg="/mnt/SDCARD/trimui_tg5040.awimg"
if [ -n "$payload" ] && [ -f "$payload" ]; then
	button=$($I1 -m "Extract awimg to SD root? A:yes B:skip" -fs 14 -k "A B")
	log "extract confirm=$button"
	if [ "$button" = "A" ]; then
		pid=$(busy "Extracting trimui_tg5040.awimg...")
		"$SEVENZ" x "$payload" -o"/mnt/SDCARD" -y >/tmp/fw_menu_extract.log 2>&1
		xrc=$?
		stop_busy "$pid"
		log "extract rc=$xrc"
		if [ "$xrc" -ne 0 ] || [ ! -f "$awimg" ]; then
			show "Extract failed - see log" 16 8
		else
			show "awimg ready on SD root ($(size_mb "$awimg") MB)" 14 5
		fi
		sync
	fi
fi

# Always end on the accredited manual procedure — never claim auto-flash.
show "Flash is MANUAL - not automatic on boot" 16 5
show "1) FAT32 card  2) awimg on ROOT" 14 6
show "3) OFF then hold VOL- + POWER" 16 8
show "4) Green bar - wait for reboot" 16 6
show "5) Boot without SD - check INFO 1.1.1" 14 8
show "Full steps: docs/FIRMWARE-UPDATE.md" 14 6

log "--- end"
exit 0

#!/bin/sh
# =============================================================================
# CrossMix-OS SE - shared OTA helpers.
#
# OTA EXIT CODE CONTRACT (GH#29)
# -----------------------------
# The OTA chain is a tree of parents and children:
#
#   ota_update.sh
#     +- ota_bootstrap.sh            (fetched, run with sh)
#     +- update_ota_release.sh       (release download/verify/apply)
#     |    +- shellect.sh            (interactive choice)
#     |    +- crossmix_update.sh     (staged at boot by _FirmwareCheck.sh)
#     |         +- crossmix_update.sh (re-exec of the copy inside the zip)
#     +- CrossMix-OS_v<local>.sh     (hotfix, fetched, run with sh)
#
# Every script reports the outcome of ITS OWN work through its exit status.
# A parent MUST check that status, MUST log it, and MUST NOT report success
# (nor write an "applied" marker) when a child failed.
#
#    0  OTA_EXIT_OK          everything requested was done; if an update was
#                            applied, every step of it succeeded.
#    1  OTA_EXIT_ERROR       unspecified/unexpected failure.
#    2  OTA_EXIT_DOWNLOAD    network, HTTP or file download failure.
#    3  OTA_EXIT_VERIFY      downloaded artifact failed verification (size,
#                            archive integrity) or version metadata invalid.
#    4  OTA_EXIT_APPLY       applying failed (extraction, file moves,
#                            backup/restore) - the system may be partial.
#    5  OTA_EXIT_PRECOND     precondition not met (free space, missing files,
#                            filesystem check).
#   10  OTA_EXIT_NO_RELEASE  nothing to do: no newer release/hotfix (benign).
#   11  OTA_EXIT_CANCEL      user declined (benign, nothing was changed).
#
# 10 and 11 are NOT failures, but they are NOT "update applied" either.
# Any other value must be treated as a failure.
#
# SHELL NOTE: busybox ash (1.36) accepts `set -o pipefail`, but dash and other
# POSIX shells do not, and the console only ships busybox. So this chain never
# relies on pipefail: use ota_run_logged, which splits the pipeline and
# recovers the child's real status.
# =============================================================================
UPDATE_VERSION=1.1.0
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"
export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"

if [ "$1" = "-v" ]; then
    echo -n $UPDATE_VERSION
    exit
fi

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[01;35m'
NC='\033[0m' # No Color

GITHUB_REPOSITORY=SrScorpio/CrossMix-OS-SE
updatedir="/mnt/SDCARD/System/updates"

# Network timeouts (GH#44 follow-up). A curl call with no --max-time waits
# forever on a dead connection, and the UI that spawned the update waits with
# it: the menu freezes instead of reporting an error. Overridable for tests.
OTA_WGET_TIMEOUT="${OTA_WGET_TIMEOUT:-30}"
OTA_CURL_CONNECT_TIMEOUT="${OTA_CURL_CONNECT_TIMEOUT:-15}"
OTA_CURL_MAX_TIME="${OTA_CURL_MAX_TIME:-900}"
OTA_CURL_API_MAX_TIME="${OTA_CURL_API_MAX_TIME:-30}"
Local_CrossMixVersion="$(cat "/mnt/SDCARD/System/usr/trimui/crossmix-version.txt")"
current_date=$(date "+%Y-%m-%d")
timestamp=$(date +'%Y%m%d-%Hh%M')

# --- GH#29 exit codes (see contract at the top of this file) -----------------
OTA_EXIT_OK=0
OTA_EXIT_ERROR=1
OTA_EXIT_DOWNLOAD=2
OTA_EXIT_VERIFY=3
OTA_EXIT_APPLY=4
OTA_EXIT_PRECOND=5
OTA_EXIT_NO_RELEASE=10
OTA_EXIT_CANCEL=11

# Machine-readable companion of the exit codes, kept for backwards
# compatibility with the existing UI/reporting that reads this file.
OTA_RESULT_FILE=/tmp/ota_release_result

ota_rc_name() {
    case "$1" in
    0) echo "ok" ;;
    1) echo "error" ;;
    2) echo "download failed" ;;
    3) echo "verification failed" ;;
    4) echo "apply failed" ;;
    5) echo "precondition failed" ;;
    10) echo "no release" ;;
    11) echo "user cancel" ;;
    *) echo "unknown failure ($1)" ;;
    esac
}

# ota_set_result <exit code> - record the outcome; the words "success",
# "no release" and "user cancel" keep their historical spelling.
ota_set_result() {
    case "$1" in
    0) _osr="success" ;;
    10) _osr="no release" ;;
    11) _osr="user cancel" ;;
    *) _osr="$(ota_rc_name "$1")" ;;
    esac
    printf '%s\n' "$_osr" >"$OTA_RESULT_FILE"
    sync 2>/dev/null
}

# ota_run_logged <logfile> <cmd> [args...]
# Runs <cmd>, mirroring stdout+stderr to the console and appending it to
# <logfile>, and returns <cmd>'s OWN exit status.
# `cmd | tee log` returns tee's status instead, and pipefail is not portable.
ota_run_logged() {
    _orl_log="$1"
    shift
    [ $# -gt 0 ] || return "$OTA_EXIT_ERROR"
    mkdir -p "$(dirname "$_orl_log")" 2>/dev/null
    _orl_rc="/tmp/ota_rc.$$"
    rm -f "$_orl_rc"
    { "$@" 2>&1; echo $? >"$_orl_rc"; } | tee -a "$_orl_log"
    _orl_status=$(cat "$_orl_rc" 2>/dev/null)
    rm -f "$_orl_rc"
    # No status file means the child never ran to completion: do not report
    # success on a missing verdict.
    [ -n "$_orl_status" ] || return "$OTA_EXIT_ERROR"
    return "$_orl_status"
}

check_connection() {
    echo -n "Checking internet connection... "
    if wget -q --spider https://github.com >/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAIL${NC}\nError: https://github.com not reachable. Check your wifi connection."
        echo -ne "${YELLOW}"
        read -n 1 -s -r -p "Press A to exit"
        exit 2
    fi
}

enable_wifi() {
    # Check if the Wi-Fi interface already has an IP
    IP=$(ip route get 1 | awk '/src/ {print $NF; exit}')
    if [ -n "$IP" ]; then
        echo "Wi-Fi is already enabled. IP: $IP"
        return 0
    fi

    echo "Wi-Fi is disabled - trying to enable it..."

    pkill -9 wpa_supplicant 2>/dev/null
    pkill -9 udhcpc 2>/dev/null
    rm -rf /etc/wifi/sockets/wlan0 2>/dev/null

    # Bring up the loopback interface
    if ! ifconfig lo up; then
        echo "Failed to bring up loopback interface (lo)."
        return 1
    fi

    sleep 1

    # Bring up the Wi-Fi interface
    if ! ifconfig wlan0 up; then
        echo "Failed to bring up Wi-Fi interface (wlan0)."
        return 1
    fi

    sleep 1

    # Start wpa_supplicant
    if ! wpa_supplicant -B -D nl80211 -i wlan0 -c /etc/wifi/wpa_supplicant.conf -O /etc/wifi/sockets; then
        echo "Failed to start wpa_supplicant."
        return 1
    fi

    sleep 5

    # Start udhcpc to obtain an IP address
    if
        ! udhcpc -i wlan0 &
        >/dev/null &
    then
        echo "Failed to start udhcpc."
        return 1
    fi

    # Verify if an IP address has been obtained
    IP=$(ip route get 1 | awk '/src/ {print $NF; exit}')
    if [ -n "$IP" ]; then
        echo "Wi-Fi enabled successfully. IP: $IP"
        return 0
    else
        echo "Failed to obtain an IP address."
        return 1
    fi
}
check_filesystem() {
    echo -e "\n${BLUE}================== CHECKDISK ==================${NC}\n"

    force=0
    if [ "$1" = "--force" ]; then
        force=1
    fi

    # Check the filesystem
    last_fsck_date=$(cat /mnt/SDCARD/System/updates/last_fsck.txt 2>/dev/null)

    if [ "$force" -eq 0 ] && [ "$last_fsck_date" = "$current_date" ]; then
        echo -e "The last fsck was performed today ($current_date).\nNo need to rerun."
    else
        echo -ne "\n" \
            "Please wait during FAT file system integrity check.\n" \
            "Issues should be fixed automatically.\n" \
            "The process can be long:\n" \
            "about 2 minutes for 128GB SD card\n\n"

        mount_point=$(mount | grep -m 1 '/mnt/SDCARD' | awk '{print $1}')
        /mnt/SDCARD/System/bin/fsck.fat -a "$mount_point" 2>&1 | awk 'NR > 3'

        echo "$current_date" >/mnt/SDCARD/System/updates/last_fsck.txt

        if ls /mnt/SDCARD/FSCK*.REC 1>/dev/null 2>&1; then
            rec_dir="/mnt/SDCARD/rec_files"
            mkdir -p "$rec_dir"
            mv /mnt/SDCARD/FSCK*.REC "$rec_dir"
            echo "FSCK*.REC files moved to $rec_dir"

            cat >"$rec_dir/_description.txt" <<EOL
The files with the extension .REC are recovery files generated by the fsck.fat tool during a file system integrity check.
These files are created when the tool encounters potential issues with the file system. 
They may contain data that was recovered or repaired. In general, these files can be ignored if no issues are noticed with the system.
However, they may also contain partial or deleted data that may not be fully usable.
You can safely delete them if you're sure the file system is working properly.
EOL
        fi
    fi
}

ReadableSizeValue() {
    local size_bytes=$1
    local result

    if [ -z "$size_bytes" ]; then
        size_bytes=0
    fi

    if [ "$size_bytes" -lt 1024 ]; then
        result="${size_bytes} Bytes"
    elif [ "$size_bytes" -lt $((1024 * 1024)) ]; then
        size_kb=$((size_bytes / 1024))
        result="${size_kb} KB"
    else
        size_mb=$(echo "$size_bytes" | awk '{printf "%.2f", $1 / (1024 * 1024)}')
        result="${size_mb} MB"
    fi

    echo "$result"
}

check_available_space() {
    required_space=$1
    echo -e "\n${BLUE}=== Checking available space on the SD Card ===${NC}\n"
    # Available space in MB
    mount_point=$(mount | grep -m 1 '/mnt/SDCARD' | awk '{print $1}')
    available_space=$(df -m $mount_point | awk 'NR==2{print $4}')
    echo "Required space: $required_space MB"
    # Check available space
    if [ "$available_space" -lt "$required_space" ]; then
        echo -e "${RED}Available space is insufficient on SD card${NC}\n"
        echo "CrossMix-OS update requires $required_space MB of free space."
        return 1
    else
        echo -e "${GREEN}Available space is sufficient on SD card (${available_space}MB)${NC}\n"
        return 0
    fi
}

download_file() {
    local url=""
    local destination_dir="."
    local destination_file=""
    local title=""

    # Parse options
    while [ $# -gt 0 ]; do
        case "$1" in
        -d)
            destination_dir="$2"
            shift 2
            ;;
        -f)
            destination_file="$2"
            shift 2
            ;;
        -t)
            title="$2"
            shift 2
            ;;
        *)
            url="$1"
            shift
            ;;
        esac
    done

    local filename=$(basename "$url")

    # Ensure the URL is provided
    if [ -z "$url" ]; then
        echo "Error: URL is required."
        return 1
    fi

    # Determine the filename if not explicitly set
    if [ -z "$destination_file" ]; then
        destination_file="$destination_dir/$filename"
    fi

    # Create destination directory if it doesn't exist
    mkdir -p "$(dirname "$destination_file")"

    # Use the title if provided, otherwise fallback to the filename
    local display_name="${title:-$filename}"

    # Temporary file name
    local temp_file="${destination_file}_tmp"

    # Download the file
    echo -e "\n${BLUE}==== Downloading: $display_name ====${NC}"
    # Timeouts, always. A stalled connection used to keep this process alive with
    # no output for minutes; the UI that launched the update waits on it, so the
    # menu froze with the icons on screen and never came back. -T is the socket
    # timeout and -t the retry count, both understood by GNU wget and busybox.
    wget --no-check-certificate --quiet --show-progress -T "${OTA_WGET_TIMEOUT:-30}" -t 2 -O "$temp_file" "$url"
    if [ $? -eq 0 ] && [ -f "$temp_file" ]; then
        mv "$temp_file" "$destination_file"
        sync
        echo -e "$display_name: ${GREEN}OK${NC}\n"
        return 0
    else
        # Remove the temporary file if download failed
        [ -f "$temp_file" ] && rm "$temp_file"
        sync
        echo -e "$display_name: ${RED}Failed${NC}\n"
        return 1
    fi
}

# --- GH#29 canonical version comparison -------------------------------------
# Accepted forms: <base>[-dev[.N] | -ce.N[.M]] where <base> is 3..6
# dot-separated integers 0..999 (e.g. 1.4.0, 1.4.0.1). Anything else
# (empty, garbage, missing components, non-numeric suffix) is INVALID:
# no output, return 1. Versions never fall through to "equal".
# Ordering: base ascending (zero-padded); same base: dev < plain < ce,
# then suffix numbers ascending (so 1.4.0 < 1.4.0-ce.1 < 1.4.0-ce.2.9
# < 1.4.0-ce.2.10 < 1.4.1). Key is fixed-width digits, compared
# lexicographically (fits no integer type).
_cmx_key() {
    _cmx_v="$1"
    [ -n "$_cmx_v" ] || return 1
    case "$_cmx_v" in *[!0-9.a-zA-Z-]*) return 1 ;; *-) return 1 ;; esac
    _cmx_base="${_cmx_v%%-*}"
    if [ "$_cmx_base" = "$_cmx_v" ]; then _cmx_sfx=""; else _cmx_sfx="${_cmx_v#*-}"; fi
    case "$_cmx_base" in ""|.*|*.|*..*) return 1 ;; esac
    case "$_cmx_sfx" in
        "")          _cmx_cls=2; _cmx_ek="0000000000000000" ;;
        dev)         _cmx_cls=1; _cmx_ek="0000000000000000" ;;
        dev.[0-9]*)  _cmx_n="${_cmx_sfx#dev.}"
                     case "$_cmx_n" in ""|*[!0-9]*) return 1 ;; esac
                     _cmx_cls=1; _cmx_ek=$(printf '%08d%08d' "$_cmx_n" 0) ;;
        ce.[0-9]*)   _cmx_r="${_cmx_sfx#ce.}"; _cmx_n="${_cmx_r%%.*}"; _cmx_m="${_cmx_r#*.}"
                     [ "$_cmx_m" = "$_cmx_r" ] && _cmx_m=0
                     case "$_cmx_n" in ""|*[!0-9]*) return 1 ;; esac
                     case "$_cmx_m" in ""|*[!0-9]*) return 1 ;; esac
                     _cmx_cls=3; _cmx_ek=$(printf '%08d%08d' "$_cmx_n" "$_cmx_m") ;;
        *)           return 1 ;;
    esac
    _cmx_kb=$(printf '%s\n' "$_cmx_base" | awk -F. '{
        if (NF < 3 || NF > 6) exit 1;
        for (i = 1; i <= NF; i++) if ($i !~ /^[0-9][0-9]?[0-9]?$/) exit 1;
        printf "%03d%03d%03d%03d%03d%03d", $1, $2, $3, (NF >= 4 ? $4 : 0), (NF >= 5 ? $5 : 0), (NF >= 6 ? $6 : 0);
    }') || return 1
    [ -n "$_cmx_kb" ] || return 1
    printf '%s%d%s' "$_cmx_kb" "$_cmx_cls" "$_cmx_ek"
}

# Output on stdout: "-1" (A < B), "0" (equal), "1" (A > B).
# Invalid input: no output, return 1 (callers must handle explicitly).
cmp_crossmix_versions() {
    _cmx_ka=$(_cmx_key "$1") || return 1
    _cmx_kb=$(_cmx_key "$2") || return 1
    if [ "$_cmx_ka" \< "$_cmx_kb" ]; then
        echo "-1"
    elif [ "$_cmx_ka" \> "$_cmx_kb" ]; then
        echo "1"
    else
        echo "0"
    fi
}
# --- end GH#29 ---------------------------------------------------------------

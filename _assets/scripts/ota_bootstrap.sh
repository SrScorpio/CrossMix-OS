#!/bin/sh
# GH#29: refresh the OTA scripts from main before the update runs.
# Exit status follows the OTA exit code contract in update_common.sh: a failed
# refresh is a download failure (2), not a silent no-op, because ota_update.sh
# aborts when this script does not report success.
export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"
export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"

# Used before update_common.sh is sourced, so it cannot come from there.
OTA_EXIT_DOWNLOAD=${OTA_EXIT_DOWNLOAD:-2}

CommonUpdateScript="/mnt/SDCARD/System/usr/trimui/scripts/update_common.sh"
currentUpdatePack=$("$CommonUpdateScript" -v)

GITHUB_REPOSITORY=SrScorpio/CrossMix-OS-SE
UpdatePackUrl="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/main/System/usr/trimui/scripts/update_common.sh"
wget --no-check-certificate --quiet --show-progress -O "/tmp/update_common.sh" "$UpdatePackUrl"
chmod +x "/tmp/update_common.sh"
onlineUpdatePack=$("/tmp/update_common.sh" -v)

# Without the online helper pack the refresh cannot be trusted: report it
# instead of continuing with a half-updated script set.
if [ ! -s "/tmp/update_common.sh" ] || [ -z "$onlineUpdatePack" ]; then
    echo "ERROR: could not fetch update_common.sh from $UpdatePackUrl"
    rm -f "/tmp/update_common.sh"
    exit "$OTA_EXIT_DOWNLOAD"
fi

if [ ! "$currentUpdatePack" = "$onlineUpdatePack" ]; then
    mv "/tmp/update_common.sh" "$CommonUpdateScript"
    sync
fi
. "$CommonUpdateScript"

FILES_TO_CHECK="/mnt/SDCARD/System/usr/trimui/scripts/crossmix_update.sh
/mnt/SDCARD/System/usr/trimui/scripts/update_ota_release.sh
/mnt/SDCARD/System/usr/trimui/scripts/ota_update.sh
/mnt/SDCARD/Apps/OTA-update/launch.sh
/mnt/SDCARD/Apps/OTA-update/keys.gptk
/mnt/SDCARD/System/usr/trimui/scripts/shellect.sh
/mnt/SDCARD/System/usr/trimui/scripts/update_common.sh"

# Check if all required files exist
missing_files=0
for file in $FILES_TO_CHECK; do
    if [ ! -f "$file" ]; then
        missing_files=1
        break
    fi
done

download_failed=0

if [ -f "/mnt/SDCARD/betatest" ]; then
    download_file "update_ota_release.sh - beta" "https://dl.dropbox.com/scl/fi/3omlfp6tb13hadh25ivod/update_ota_release.sh?rlkey=2if0wx1k4dta8ozzhevr1mfn9" -f "/mnt/SDCARD/System/usr/trimui/scripts/update_ota_release.sh" || download_failed=1
else
    download_file "update_ota_release.sh" "https://raw.githubusercontent.com/SrScorpio/CrossMix-OS-SE/refs/heads/main/System/usr/trimui/scripts/update_ota_release.sh" -d "/mnt/SDCARD/System/usr/trimui/scripts" || download_failed=1
fi

if [ ! "$currentUpdatePack" = "$onlineUpdatePack" ] || [ "$missing_files" -eq 1 ]; then
    download_file "crossmix_update.sh" "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/refs/heads/main/System/usr/trimui/scripts/crossmix_update.sh" -d "/mnt/SDCARD/System/usr/trimui/scripts" || download_failed=1
    download_file "ota_update.sh" "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/refs/heads/main/System/usr/trimui/scripts/ota_update.sh" -d "/mnt/SDCARD/System/usr/trimui/scripts" || download_failed=1
    download_file "launch.sh" "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/refs/heads/main/Apps/OTA-update/launch.sh" -f "/mnt/SDCARD/Apps/OTA-update/launch.sh" || download_failed=1
    download_file "keys.gptk" "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/refs/heads/main/Apps/OTA-update/keys.gptk" -f "/mnt/SDCARD/Apps/OTA-update/keys.gptk" || download_failed=1
    download_file "Terminal launch.sh" "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/refs/heads/main/Apps/Terminal/launch.sh" -f "/mnt/SDCARD/Apps/Terminal/launch.sh" || download_failed=1
    download_file "shellect.sh" "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/refs/heads/main/System/usr/trimui/scripts/shellect.sh" -d "/mnt/SDCARD/System/usr/trimui/scripts" || download_failed=1
    download_file "infoscreen.sh" "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/refs/heads/main/System/usr/trimui/scripts/infoscreen.sh" -d "/mnt/SDCARD/System/usr/trimui/scripts" || download_failed=1
    sync
    if [ "$download_failed" -eq 1 ]; then
        # Do NOT tell the user the scripts were upgraded: they were not.
        echo "ERROR: one or more OTA scripts could not be downloaded; aborting."
        /mnt/SDCARD/System/usr/trimui/scripts/infoscreen.sh -m "OTA preparation failed: could not download the update scripts. Check your connection and retry." -k "A B" -fs 28
        exit "$OTA_EXIT_DOWNLOAD"
    fi
    /mnt/SDCARD/System/usr/trimui/scripts/infoscreen.sh -m "Update scripts upgraded, please launch OTA update again." -t 5
    killall -2 SimpleTerminal
elif [ "$download_failed" -eq 1 ]; then
    echo "ERROR: could not download update_ota_release.sh; aborting."
    exit "$OTA_EXIT_DOWNLOAD"
fi

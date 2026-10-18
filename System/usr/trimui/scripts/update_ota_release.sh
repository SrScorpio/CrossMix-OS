#!/bin/sh
# GH#29 - parent/child error propagation for the OTA chain.
#
# Invoked by ota_update.sh (interactive OTA flow) or in "check" mode by the UI.
# Exit status: see the OTA exit code contract at the top of update_common.sh.
# This script must never report success / write the "success" marker unless
# download, size verification and staging all succeeded.
. /mnt/SDCARD/System/usr/trimui/scripts/update_common.sh

cmd=$1

# channel : stable or beta
channel=$(cat "$updatedir/ota_channel.txt" 2>/dev/null)
if [ "$channel" = "" ]; then
    channel="stable"
fi

run() {

    # enable_wifi
    check_connection
    clear

    if [ "$cmd" = "check" ]; then
        IP=$(ip route get 1 | awk '{print $NF;exit}')
        if [ "$IP" != "" ]; then
            get_release_info
            exit $?
        fi
        exit "$OTA_EXIT_ERROR"
    fi

    rm /tmp/cmd_to_run.sh 2>/dev/null # avoid any resume at boot

    get_release_info
    release_rc=$?
    if [ "$release_rc" -ne 0 ]; then
        # Propagate what actually happened: "no newer release" (10) is benign,
        # a failed lookup (2) or invalid metadata (3) is not.
        echo -ne "${YELLOW}"
        if [ -t 0 ]; then read -n 1 -s -r -p "Press A to exit"; fi
        exit "$release_rc"
    else
        touch "$updatedir/.CrossMixUpdateAvailable"
        sync
    fi
    echo -ne "${YELLOW}"
    if [ -t 0 ]; then read -n 1 -s -r -p "Press A to continue"; fi
    echo -ne "${NC}\n"
    clear

    if [ -f "$updatedir/CrossMix-OS_v$Release_Version.zip" ] || [ -f "/mnt/SDCARD/CrossMix-OS_v$Release_Version.zip" ]; then

        if [ ! -f "$updatedir/CrossMix-OS_v$Release_Version.zip" ] && [ -f "/mnt/SDCARD/CrossMix-OS_v$Release_Version.zip" ]; then
            echo -e "File found in SDCARD root,\nmoving to $updatedir"
            if ! mv "/mnt/SDCARD/CrossMix-OS_v$Release_Version.zip" "$updatedir/"; then
                echo -e "${RED}Could not move the update archive to $updatedir.${NC}"
                exit "$OTA_EXIT_APPLY"
            fi
            sleep 4
        fi
        echo -e "\nCrossMix-OS_v$Release_Version.zip already present,\nchecking file size:"
        check_update
        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}Local archive is incomplete, downloading it again.${NC}"
            sleep 5
            # A failed re-download is fatal: never fall through to apply.
            download_update || exit $?
            check_update || exit "$OTA_EXIT_VERIFY"
        fi
    else
        sleep 5
        download_update || exit $?
        check_update || exit "$OTA_EXIT_VERIFY"
    fi

    apply_update
    exit $?
}

get_release_info() {
    echo -ne "${PURPLE}Retrieving release information.. ${NC}"

    # Github source api url

    Release_assets_info=$(curl -k -s -L https://api.github.com/repos/$GITHUB_REPOSITORY/releases/latest)
    if [ $? -ne 0 ] || [ -z "$Release_assets_info" ]; then
        echo -e "${RED}FAIL${NC}\nCould not reach the GitHub release API."
        return "$OTA_EXIT_DOWNLOAD"
    fi

    if echo "$Release_assets_info" | grep -q '"message": "Not Found"'; then
        rm "$updatedir/.CrossMixUpdateAvailable" 2>/dev/null
        echo -e "${GREEN}DONE${NC}\n\nNo update available for $channel channel\n"
        sync
        return "$OTA_EXIT_NO_RELEASE"
    fi

    Release_asset=$(echo "$Release_assets_info" | jq '.assets[]? | select(.name | contains("CrossMix-OS_v"))')
    Release_url=$(echo $Release_asset | jq '.browser_download_url' | tr -d '"')
    Release_FullVersion=$(echo $Release_asset | jq '.name' | tr -d "\"" | sed 's/^CrossMix-OS_v//g' | sed 's/\.zip$//g' | sed 's/\.7z$//g')
    Release_Version=$(echo $Release_FullVersion | sed 's/-dev.*$//g')
    Release_size=$(echo $Release_asset | jq -r '.size')

    # A missing/!numeric size would make every later size check meaningless.
    case "$Release_size" in
    '' | *[!0-9]*)
        echo -e "${RED}FAIL${NC}\nRelease metadata has no usable asset size."
        rm "$updatedir/.CrossMixUpdateAvailable" 2>/dev/null
        sync
        return "$OTA_EXIT_VERIFY"
        ;;
    esac

    Release_size_MB=$((Release_size / 1024 / 1024))
    Release_Date=$(echo "$Release_asset" | jq -r '.created_at')
    Release_info=$(echo "$Release_assets_info" | jq '.body')

    Local_CrossMixVersion="$(cat /mnt/SDCARD/System/usr/trimui/crossmix-version.txt)"
    Local_Version=$(echo $Local_CrossMixVersion | sed 's/-dev.*$//g')

    echo -e "${GREEN}DONE${NC}"

    echo -ne "\n\n\n\n" \
        "${BLUE}======= Installed Version ========${NC}\n" \
        " Version: $Local_CrossMixVersion \n" \
        "${BLUE}==================================${NC}\n"
    echo -ne "\n\n" \
        "${BLUE}======== Online Version  =========${NC}\n" \
        " Version: $Release_FullVersion \n" \
        " Size:    ${Release_size_MB}MB \n" \
        " Date:    $Release_Date \n" \
        " URL:     $Release_url \n" \
        "${BLUE}==================================${NC}\n\n\n\n\n"

    # GH#29: canonical comparison; update only if remote strictly newer than
    # local (no downgrade, no equal re-flag). Invalid -> explicit no-update.
    vcmp=$(cmp_crossmix_versions "$Local_CrossMixVersion" "$Release_FullVersion")
    if [ -z "$vcmp" ]; then
        echo -e "Invalid local or remote version ('$Local_CrossMixVersion' vs '$Release_FullVersion').\n"
        rm "$updatedir/.CrossMixUpdateAvailable" 2>/dev/null
        sync
        return "$OTA_EXIT_VERIFY"
    fi

    if [ "$vcmp" != "-1" ]; then
        echo -e "No new major version of CrossMix available.\n"
        rm "$updatedir/.CrossMixUpdateAvailable" 2>/dev/null
        sync
        return "$OTA_EXIT_NO_RELEASE"
    fi

    echo -e "${GREEN}Update available!${NC}\n"
    touch "$updatedir/.CrossMixUpdateAvailable"
    sync
    return 0
}

download_update() {
    Mychoice=$(echo -e "No\nYes" | /mnt/SDCARD/System/usr/trimui/scripts/shellect.sh -t "Download v$Release_Version (${Release_size_MB}MB) ?" -b "Press A to validate your choice.")

    if [ "$Mychoice" = "Yes" ]; then
        check_available_space "$(($Release_size_MB + 500))"
        if [ $? -ne 0 ]; then
            echo -ne "${YELLOW}"
            if [ -t 0 ]; then read -n 1 -s -r -p "Press A to exit"; fi
            return "$OTA_EXIT_PRECOND"
        fi
        clear
        check_filesystem
        rm "$updatedir/CrossMix-OS_v$Release_Version.zip" 2>/dev/null
        download_file $Release_url -f "$updatedir/CrossMix-OS_v$Release_Version.zip" -t "Downloading CrossMix $Release_Version"
        if [ $? -ne 0 ] || [ ! -s "$updatedir/CrossMix-OS_v$Release_Version.zip" ]; then
            echo -e "${RED}CrossMix update download has failed!${NC}"
            echo -ne "${YELLOW}"
            if [ -t 0 ]; then read -n 1 -s -r -p "Press A to exit"; fi
            return "$OTA_EXIT_DOWNLOAD"
        fi
        sleep 2
        return 0
    else
        echo "Download canceled"
        return "$OTA_EXIT_CANCEL"
    fi
}

# Returns 0 only when the archive on disk has exactly the announced size.
check_update() {

    if [ ! -f "$updatedir/CrossMix-OS_v$Release_Version.zip" ]; then
        echo -e "\n${RED}Error: the update archive is missing${NC}\n"
        return "$OTA_EXIT_VERIFY"
    fi

    Downloaded_size=$(stat -c %s "$updatedir/CrossMix-OS_v$Release_Version.zip")
    if [ "$Downloaded_size" -eq "$Release_size" ]; then
        echo -e "${GREEN}File size OK!${NC} ($Downloaded_size)"
        sleep 4
        return 0
    else
        echo -ne "\n\n${RED}Error: Wrong download size${NC} ($Downloaded_size instead of $Release_size)\n"
        return "$OTA_EXIT_VERIFY"
    fi
}

apply_update() {
    Mychoice=$(echo -e "No\nYes" | /mnt/SDCARD/System/usr/trimui/scripts/shellect.sh -t "Apply update $Release_Version ?" -b "Press A to validate your choice.")
    clear
    if [ "$Mychoice" = "Yes" ]; then

        UpdateScript="https://raw.githubusercontent.com/SrScorpio/CrossMix-OS-SE/refs/tags/v$Release_Version/System/usr/trimui/scripts/crossmix_update.sh"
        DownloadPath="/mnt/SDCARD/System/usr/trimui/scripts/crossmix_update.sh"

        download_file $UpdateScript -f "$DownloadPath" -t "Upgrading Update Script"
        if [ $? -ne 0 ] || ! [ -s "$DownloadPath" ]; then
            echo -e "${RED}Update Script upgrade has failed!${NC}"
            echo -ne "${YELLOW}"
            if [ -t 0 ]; then read -n 1 -s -r -p "Press A to exit"; fi
            return "$OTA_EXIT_DOWNLOAD"
        fi

        echo -e "\n${BLUE}=============== Applying update ===============${NC}\n"

        if ! mv "$updatedir/CrossMix-OS_v$Release_Version.zip" "/mnt/SDCARD/"; then
            echo -e "${RED}Could not stage the update archive on the SD card root.${NC}"
            return "$OTA_EXIT_APPLY"
        fi
        if [ ! -f "/mnt/SDCARD/CrossMix-OS_v$Release_Version.zip" ]; then
            echo -e "${RED}The staged update archive is not where the boot installer expects it.${NC}"
            return "$OTA_EXIT_APPLY"
        fi

        # Reached only when everything above really succeeded: this is the
        # "update staged, will be applied at boot" marker.
        echo "success" >"${OTA_RESULT_FILE:-/tmp/ota_release_result}"
        echo -ne "\n\n" \
            "${GREEN}Update $Release_Version staged.${NC}\n" \
            "Rebooting to run installation...\n"
        echo -ne "${YELLOW}"
        sync
        sleep 6
        reboot
        return "$OTA_EXIT_OK"

    else
        echo "Applying update canceled"
        return "$OTA_EXIT_CANCEL"
    fi
}

# Run the flow in a subshell so an `exit` from a helper (check_connection)
# still lands here, then record the outcome before leaving.
(run)
_rc=$?
# "check" is a query, not an action: recording a result there would claim an
# outcome ("success") for an update that was never downloaded or applied.
if [ "$cmd" != "check" ]; then
    ota_set_result "$_rc"
fi
echo "[update_ota_release] exit $_rc ($(ota_rc_name "$_rc"))"
exit "$_rc"

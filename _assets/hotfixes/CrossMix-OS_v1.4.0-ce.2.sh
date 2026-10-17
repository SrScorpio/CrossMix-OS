#!/bin/sh
# CrossMix-OS SE/CE - hotfix v1.4.0-ce.2.6
# Channel: served by ota_update.sh when releases/latest has nothing newer.
# Fixes:
#  - crossmix-version.txt pinned to 1.4.0-ce.2 (legacy upstream hotfixes
#    can no longer fire by version-key on migrated consoles)
#  - update_ota_release.sh parses .7z release assets correctly
#  - firmware wizard: MinFwVersion matches the bundled payload (1.1.1/20251128)
#    and _FirmwareCheck.sh falls back to the newest bundled firmware
#  - new System Tools entry: TOOLS / Firmware Update (status + on-demand run)
#  - System Tools rebuilds its menu cache when scripts change (entry visible)
# Non-interactive by design: the OTA flow runs it as `curl ... | sh`.
source /mnt/SDCARD/System/usr/trimui/scripts/update_common.sh
cmd=$1

Remote_HotfixVersion="1.4.0-ce.2.8"
Remote_HotfixDate="2026-10-17"
Remote_HotfixDesc="- Firmware Update: payload download + verify"

hotfix_fileUrl="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/main/_assets/hotfixes/CrossMix-OS_v1.4.0-ce.2.zip"
local_hotfix_file="/mnt/SDCARD/System/usr/trimui/crossmix-hotfix-version.txt"

version_num() { tr -cd '0-9'; }

get_hotfix_info() {
    echo -e "\n${BLUE}========== Hotfix available ==========${NC}"
    echo -e " Version:  v$Remote_HotfixVersion"
    echo -e " Date:     $Remote_HotfixDate"
    echo -e " Changes:  $Remote_HotfixDesc"
    echo -e "${BLUE}======================================${NC}\n"
}

main() {
    if [ "$cmd" = "check" ]; then
        get_hotfix_info
        exit 0
    fi

    Local_HotfixVersion=""
    [ -f "$local_hotfix_file" ] && Local_HotfixVersion=$(cat "$local_hotfix_file")

    if [ -n "$Local_HotfixVersion" ]; then
        if [ "$(echo "$Remote_HotfixVersion" | version_num)" -le "$(echo "$Local_HotfixVersion" | version_num)" ]; then
            echo "Hotfix v$Remote_HotfixVersion already applied (local: v$Local_HotfixVersion). Nothing to do."
            exit 0
        fi
    fi

    get_hotfix_info
    echo -ne "Downloading hotfix payload.. "
    wget -q "$hotfix_fileUrl" -O /tmp/crossmix_hotfix.zip 2>/dev/null \
        || /mnt/SDCARD/System/bin/wget -q "$hotfix_fileUrl" -O /tmp/crossmix_hotfix.zip 2>/dev/null
    if [ ! -s /tmp/crossmix_hotfix.zip ]; then
        echo -e "${RED}FAILED${NC} (download)"
        echo "download failed" >/tmp/ota_release_result
        exit 1
    fi
    echo -e "${GREEN}DONE${NC}"

    echo -ne "Applying.. "
    /mnt/SDCARD/System/bin/7zz x -aoa /tmp/crossmix_hotfix.zip -o"/mnt/SDCARD" >/tmp/crossmix_hotfix.log 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}FAILED${NC} (extract - see /tmp/crossmix_hotfix.log)"
        exit 1
    fi

    # los scripts deben quedar ejecutables aunque el zip no traiga los permisos
    chmod a+x "/mnt/SDCARD/Apps/SystemTools/Menu/TOOLS/Firmware Update.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/Apps/SystemTools/launch.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/starts/_FirmwareCheck.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/usr/trimui/scripts/update_ota_release.sh" 2>/dev/null

    # System Tools cachea el menu en SQLite y no lo reescanea: se borra para que
    # la entrada nueva aparezca al abrirlo (se reconstruye en ~2 s).
    rm -f "/mnt/SDCARD/Apps/SystemTools/Menu/Menu_cache7.db"

    echo "$Remote_HotfixVersion" > "$local_hotfix_file"
    rm -f /tmp/crossmix_hotfix.zip
    sync
    echo -e "${GREEN}DONE${NC}"
    echo -e "\n${GREEN}Hotfix v$Remote_HotfixVersion applied successfully.${NC}"
    exit 0
}

main

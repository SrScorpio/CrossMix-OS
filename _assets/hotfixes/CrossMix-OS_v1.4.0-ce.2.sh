#!/bin/sh
# CrossMix-OS SE/CE - hotfix v1.4.0-ce.2.20
# Channel: served by ota_update.sh when releases/latest has nothing newer.
# Fixes:
#  - ssh autostart: helper copied to /etc (S95done can run before the card is
#    mounted) + /tmp/rc-beacon.log to prove init reached rc.local
#  - ssh autostart via /etc/rc.local: ex_init and °customization are NOT run by
#    this firmware, /etc/init.d/sshd is the OpenSSH one (dead path)
#  - ssh_start: pidof+lock instead of ps (busybox ps cannot see the server, so
#    the guard never matched and the surviving dropbear accepted passwords)
#  - telnetd no longer starts as unauthenticated root (#66)
#  - cpufreq accepts schedutil and applies to every policy
#  - noop I/O scheduler + 1MB read-ahead for SD/eMMC
#  - dropbear now starts from °customization.sh too: ex_init is not run on
#    every boot, so SSH died on reboot. Keys only (-s) when a key is installed.
#  - crossmix-version.txt pinned to 1.4.0-ce.2 (legacy upstream hotfixes
#    can no longer fire by version-key on migrated consoles)
#  - update_ota_release.sh parses .7z release assets correctly
#  - firmware wizard: MinFwVersion matches the bundled payload (1.1.1/20251128)
#    and _FirmwareCheck.sh falls back to the newest bundled firmware
#  - deploys System/starts/_FirmwareCheck.sh + trimui/firmwares/MinFwVersion.txt
#    (hotfix .14/.15 never shipped them; existing SDs still had the base script)
#  - System Tools entry: TOOLS / Firmware Update (download/check + manual flash
#    instructions; does not claim boot auto-flashes)
#  - System Tools rebuilds its menu cache when scripts change (entry visible)
# Non-interactive by design: the OTA flow runs it as `curl ... | sh`.
source /mnt/SDCARD/System/usr/trimui/scripts/update_common.sh
cmd=$1

Remote_HotfixVersion="1.4.0-ce.2.24"
Remote_HotfixDate="2026-10-19"
Remote_HotfixDesc="- The boot logo flashed on first boot is now the SE mark, with a fallback to the stock one on cards that lack it; splash already shows CrossMix-OS SE"

hotfix_fileUrl="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/main/_assets/hotfixes/CrossMix-OS_v1.4.0-ce.2.zip"
local_hotfix_file="/mnt/SDCARD/System/usr/trimui/crossmix-hotfix-version.txt"

version_num() { sed 's/[^0-9.]/./g' | tr -s '.' | sed 's/^\.//; s/\.$//' | awk -F. '{printf "%03d%03d%03d%03d%03d", $1, $2, $3, $4, $5}'; }

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

    # scripts must stay executable even if the zip stripped bits
    chmod a+x "/mnt/SDCARD/Apps/SystemTools/launch.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/starts/_FirmwareCheck.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/usr/trimui/scripts/update_ota_release.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/usr/trimui/scripts/update_notification.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/Apps/SystemTools/Menu/TOOLS/Firmware Update.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/starts/°customization.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/usr/trimui/scripts/favorites_guard.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/usr/trimui/scripts/ssh_start.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/starts/°post_starts.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/usr/trimui/scripts/cpufreq.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/usr/trimui/scripts/io_scheduler.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/Apps/SystemTools/Menu/NETWORK##TELNET (state)/TELNET Server  - enable.sh" 2>/dev/null
    chmod a+x "/mnt/SDCARD/System/usr/trimui/scripts/install-ssh-autostart.sh" 2>/dev/null

# SSH on every boot: rc.local is the only init hook this firmware runs reliably.
# ex_init.sh and °customization.sh are not executed, so the helper never ran.
if [ -x "/mnt/SDCARD/System/usr/trimui/scripts/install-ssh-autostart.sh" ]; then
    /mnt/SDCARD/System/usr/trimui/scripts/install-ssh-autostart.sh
fi

    # retire obsolete debug/download-only entries; keep Firmware Update.sh
    rm -f "/mnt/SDCARD/Apps/SystemTools/Menu/TOOLS/Firmware Download.sh"
    rm -f "/mnt/SDCARD/Apps/SystemTools/Menu/TOOLS/Firmware Debug.sh"

    # System Tools caches the menu in SQLite and does not rescan: drop it so
    # the restored entry appears on next open (rebuild takes ~2 s).
    rm -f "/mnt/SDCARD/Apps/SystemTools/Menu/Menu_cache7.db"
    rm -f "/mnt/SDCARD/Apps/SystemTools/Menu/.cache_stamp"

    # --- firmware payload: updater downloads it, no interaction ---
    # ~158 MB from release assets; retries and verifies with 7zz.
    fw_dir="/mnt/SDCARD/trimui/firmwares"
    wget_bin="/mnt/SDCARD/System/bin/wget"; [ -x "$wget_bin" ] || wget_bin="wget"
    sevenz_bin="/mnt/SDCARD/System/bin/7zz"; [ -x "$sevenz_bin" ] || sevenz_bin="7zz"
    fw_ver=$(sed -n '1p' "$fw_dir/MinFwVersion.txt" 2>/dev/null | tr -d '\r ')
    fw_rev=$(sed -n '2p' "$fw_dir/MinFwVersion.txt" 2>/dev/null | tr -d '\r ')
    if [ -n "$fw_ver" ] && [ -n "$fw_rev" ]; then
        p1="$fw_dir/firmware_tsp_v${fw_ver}_${fw_rev}.7z.001"
        p2="${p1%.001}.002"
        need=0
        if [ -f "$p1" ] && [ -f "$p2" ]; then
            "$sevenz_bin" t "$p1" >/dev/null 2>&1 || need=1
        else
            need=1
        fi
        if [ "$need" -eq 1 ]; then
            echo -e "\nFirmware payload v$fw_ver ($fw_rev): downloading ~158 MB..."
            for part in "$p1" "$p2"; do
                name=$(basename "$part")
                rm -f "$part"
                ok=0
                for attempt in 1 2 3; do
                    if "$wget_bin" -q -T 30 \
                        "https://github.com/$GITHUB_REPOSITORY/releases/latest/download/$name" -O "$part"; then
                        ok=1
                        break
                    fi
                    echo "  retry $attempt for $name"
                    sleep 3
                done
                if [ "$ok" -eq 0 ]; then
                    echo -e "  ${RED}FAILED${NC} $name"
                else
                    echo "  $name  $(( $(stat -c %s "$part") / 1048576 )) MB"
                fi
            done
            if "$sevenz_bin" t "$p1" >/tmp/fw_payload_test.log 2>&1; then
                echo -e "  ${GREEN}payload verified${NC}"
            else
                rm -f "$p1" "$p2"
                fail_payload=1
                echo -e "  ${RED}payload could not be verified${NC}"
            fi
        else
            echo -e "Firmware payload v$fw_ver ($fw_rev): already present and valid."
        fi
    fi

    if [ "${fail_payload:-0}" -eq 1 ]; then
        # Scripts are already applied by the unzip above. Stamp the hotfix so the
        # next boot does not re-download the ~158 MB payload in a loop; the
        # payload is retried from TOOLS / Firmware Update, which is explicit.
        echo "$Remote_HotfixVersion" > "$local_hotfix_file"
        rm -f /tmp/crossmix_hotfix.zip
        sync
        echo -e "\n${RED}Payload pending.${NC} Scripts are applied and the hotfix is stamped; open TOOLS / Firmware Update to retry the payload download."
        exit 1
    fi

    echo "$Remote_HotfixVersion" > "$local_hotfix_file"
    rm -f /tmp/crossmix_hotfix.zip
    sync
    echo -e "${GREEN}DONE${NC}"
    echo -e "\n${GREEN}Hotfix v$Remote_HotfixVersion applied successfully.${NC}"
    exit 0
}

main

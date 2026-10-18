#!/bin/sh
# Silent background update checker for CrossMix-OS
# - Runs at boot in background
# - No UI output; logs to $updatedir/update_check.log
# - Detects newer major/minor versions and sets flags consumed by UI scripts

# Common env, paths, helpers
source /mnt/SDCARD/System/usr/trimui/scripts/update_common.sh

# Set to 1 to write logs to file, 0 to print logs to console
LOG_TO_FILE=0

LOG_FILE="/mnt/SDCARD/System/logs/update_check.log"
RELEASE_META="$updatedir/available_release.json"
HOTFIX_META="$updatedir/available_hotfix.json"
STAMP_FILE="$updatedir/update_check_last_run.txt"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$updatedir"

log() {
    ts="$(date +'%Y-%m-%d %H:%M:%S') - $*"
    if [ "${LOG_TO_FILE:-1}" = "1" ]; then
        echo "$ts" >>"$LOG_FILE"
    else
        echo "$ts"
    fi
}

# Convert x.y.z[.w][-suffix] into comparable integer — replaced by the canonical
# cmp_crossmix_versions() in update_common.sh (GH#29).

has_ip() {
    ip route get 1 2>/dev/null | awk '/src/ {print $NF; exit}'
}

can_reach_github() {
    wget -q --spider https://github.com >/dev/null 2>&1
}

write_result_json() {
    # $1: name, $2: url, $3: size_bytes, $4: created_at
    # Serialize with jq so available_release.json is ALWAYS valid JSON, even if a
    # string field contains quotes/backslashes (contract: same keys, numeric size).
    jq -n --arg name "$1" --arg url "$2" --argjson size "$3" --arg created "$4" \
        '{name: $name, url: $url, size: $size, created_at: $created}' >"$RELEASE_META.tmp" 2>/dev/null \
        && mv "$RELEASE_META.tmp" "$RELEASE_META"
}

# Check major release availability from GitHub releases
check_major_release() {
    release_json=$(curl -k -s -L "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/latest")
    if echo "$release_json" | grep -q '"message": "Not Found"'; then
        log "No GitHub releases found."
        rm -f "$RELEASE_META"
        return 1
    fi

    # The image must belong to THIS release tag: exactly CrossMix-OS_v<tag>.7z/.zip.
    # Attachments (kit/firmware/tool/migration/...), other versions and split parts
    # never match. Candidates also need a usable url and a positive integer size.
    tag=$(echo "$release_json" | jq -r '.tag_name // ""' 2>/dev/null)
    release_version=""
    [ -n "$tag" ] && release_version="${tag#v}"
    if [ -z "$release_version" ]; then
        log "Release has no usable tag_name; skipping major release check."
        rm -f "$RELEASE_META"
        return 1
    fi

    asset=$(echo "$release_json" | jq -r --arg ver "$release_version" '
        [ .assets[]?
          | select(.name != null and (.name | type) == "string")
          | select(.name == ("CrossMix-OS_v" + $ver + ".7z")
                   or .name == ("CrossMix-OS_v" + $ver + ".zip"))
          | select((.browser_download_url // "") | (type == "string"
              and test("^https?://([^/[:space:][:cntrl:]])([^[:space:][:cntrl:]]*)$")))
          | select((.size // null) | type == "number")
          | select(.size > 0 and .size == (.size | floor))
          | select((.created_at // null) | type == "string")
          | {name: .name, url: .browser_download_url, size: .size, created: .created_at,
             prio: (if (.name | endswith(".7z")) then 0 else 1 end)} ]
        | sort_by(.prio, .name)
        | (if length > 0 then .[0] else null end)
        | tostring' 2>/dev/null)
    if [ -z "$asset" ] || [ "$asset" = "null" ]; then
        if echo "$release_json" | jq -e '[.assets[]? | select((.name // "") | test("\\.7z\\.00[0-9]$"))] | length > 0' >/dev/null 2>&1; then
            log "Release contains split multipart images (.7z.001); split archives are not supported by this updater."
        fi
        log "No valid CrossMix-OS_v image asset (.7z/.zip with usable url/size) for tag $tag."
        rm -f "$RELEASE_META"
        return 1
    fi

    url=$(echo "$asset" | jq -r '.url')
    name=$(echo "$asset" | jq -r '.name')
    size=$(echo "$asset" | jq -r '.size')
    created=$(echo "$asset" | jq -r '.created')

    release_full_version="${name#CrossMix-OS_v}"
    release_full_version="${release_full_version%.*}"
    remote_version_core="${release_full_version%-dev*}"

    local_full_version=$(cat /mnt/SDCARD/System/usr/trimui/crossmix-version.txt 2>/dev/null)

    if [ -z "$local_full_version" ]; then
        log "Local version missing; flagging update $release_full_version."
        write_result_json "$name" "$url" "$size" "$created" || { rm -f "$RELEASE_META"; return 1; }
        sync
        return 0
    fi

    # GH#29: single canonical comparison (CE builds, legacy and dev ordered;
    # equality exact; invalid versions handled explicitly, never as equal).
    cmp=$(cmp_crossmix_versions "$local_full_version" "$release_full_version")
    if [ -z "$cmp" ]; then
        log "Invalid version string (local '$local_full_version' / release '$release_full_version'); skipping update flag."
        rm -f "$RELEASE_META"
        return 1
    fi

    if [ "$cmp" = "-1" ]; then
        rm -f "$HOTFIX_META"
        write_result_json "$name" "$url" "$size" "$created" || { rm -f "$RELEASE_META"; return 1; }
        log "Update available: $local_full_version -> $release_full_version ($size bytes)."
        echo -e "{ \"type\":\"info\", \"size\":2, \"duration\":5000, \"x\":670, \"y\":640,  \"message\":\"       CrossMix v$release_full_version available.\",  \"icon\":\"\" }" >/tmp/trimui_osd/osd_toast_msg

        sync
        return 0
    fi

    rm -f "$RELEASE_META"
    return 1
}

# Check hotfix availability for a given base version (e.g., 1.3.0)
check_hotfix() {
    base_version="$1"
    url="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/main/_assets/hotfixes/CrossMix-OS_v${base_version}.sh"

    if ! wget -q --spider "$url" >/dev/null 2>&1; then
        rm -f "$HOTFIX_META"
        return 1
    fi

    content=$(curl -k -s "$url") || {
        rm -f "$HOTFIX_META"
        return 1
    }

    remote_hotfix=$(echo "$content" | sed -n 's/^Remote_HotfixVersion="\(.*\)"/\1/p' | head -n1)
    remote_date=$(echo "$content" | sed -n 's/^Remote_HotfixDate="\(.*\)"/\1/p' | head -n1)

    [ -z "$remote_hotfix" ] && {
        rm -f "$HOTFIX_META"
        return 1
    }

    if [ -f /mnt/SDCARD/System/usr/trimui/crossmix-hotfix-version.txt ]; then
        local_hotfix=$(cat /mnt/SDCARD/System/usr/trimui/crossmix-hotfix-version.txt)
    else
        # default to .0 of same width as remote last digit
        local_hotfix=$(echo "$remote_hotfix" | sed 's/\(.*\).$/\10/')
    fi

    # GH#29: canonical comparison; remote must be strictly greater (no downgrade,
    # no equal re-flag). Invalid local/remote hotfix version -> explicit skip.
    hcmp=$(cmp_crossmix_versions "$remote_hotfix" "$local_hotfix") || hcmp=""
    if [ "$hcmp" = "1" ]; then
        cat >"$HOTFIX_META" <<EOF
{
  "for_version": "$base_version",
  "remote_hotfix": "$remote_hotfix",
  "local_hotfix": "$local_hotfix",
  "date": "$remote_date",
  "script": "$url"
}
EOF
        sync
        return 0
    fi

    rm -f "$HOTFIX_META"
    return 1
}

main() {

    # Quick network check
    if [ -z "$(has_ip)" ]; then
        log "No IP at boot; skipping Update Check."
        exit 1
    fi
    if ! can_reach_github; then
        log "GitHub API not reachable; skipping Update Check."
        exit 1
    fi

    # Run at most once per day unless --force
    TODAY="$(date +%Y-%m-%d)"
    if [ "$1" != "--force" ]; then
        last_run_date=$(cat "$STAMP_FILE" 2>/dev/null)
        if [ "$last_run_date" = "$TODAY" ]; then
            log "Already ran today ($TODAY); skipping."
            exit 0
        fi
        echo "$TODAY" >"$STAMP_FILE"
        sync
    else
        log "Force run requested; bypassing daily guard."
    fi

    # Check major release first
    if check_major_release; then
        exit 0
    fi

    # No major update; check hotfix
    base_version=$(cat /mnt/SDCARD/System/usr/trimui/crossmix-version.txt 2>/dev/null)
    local_version_core="${base_version%-dev*}"
    rm -f "$RELEASE_META"
    log "No major update. Checking hotfix for $local_version_core."
    if check_hotfix "$local_version_core"; then
        log "Hotfix $remote_hotfix available for base $local_version_core."
        echo -e "{ \"type\":\"info\", \"size\":2, \"duration\":5000, \"x\":670, \"y\":640,  \"message\":\"CrossMix Hotfix $remote_hotfix available.\",  \"icon\":\"\" }" >/tmp/trimui_osd/osd_toast_msg
        exit 0
    fi

    log "No hotfix available."
    exit 1
}

main "$@"

#!/bin/bash
#
# Repair the MainUI favourites list.
#
# favourite2.json is NDJSON: one JSON object per line, not a single JSON
# document. This tool normalises the position of the label key, fills in a
# missing sublabel from the rompath and refreshes .launch against each
# emulator's config.json.
#
# Every stage writes into a temp file in the same directory and only replaces the
# list once the result has been verified (same number of entries), so an
# interrupted run or a failing helper can never leave a half-written favourites
# file behind. The original is always copied to favourite2.json_<timestamp>
# before the first write, and lines that are not valid JSON are preserved
# verbatim: they are reported, never dropped.

export PATH="/mnt/SDCARD/System/bin:/mnt/SDCARD/System/usr/trimui/scripts:$PATH"
export LD_LIBRARY_PATH="/mnt/SDCARD/System/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"

FAV_FILE="${FAV_FILE:-/mnt/SDCARD/Roms/favourite2.json}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/SDCARD/System/backups}"

TMP1=""
TMP2=""
TMP3=""
cleanup() {
    for f in "$TMP1" "$TMP2" "$TMP3"; do
        [ -n "$f" ] && rm -f "$f" 2>/dev/null
    done
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

die() {
    echo "$1"
    sleep 2
    exit 1
}

/mnt/SDCARD/System/usr/trimui/scripts/infoscreen.sh -m "Fixing favorites..." 2>/dev/null

JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ] && [ -x /mnt/SDCARD/System/bin/jq ]; then
    JQ=/mnt/SDCARD/System/bin/jq
fi
[ -n "$JQ" ] || die "jq not found, favourites left untouched."

entry_count() {
    awk 'END { print NR }' "$1" 2>/dev/null
}

line_is_json() {
    printf '%s\n' "$1" | "$JQ" empty >/dev/null 2>&1
}

# Replace the favourites file with a candidate, but only when the entry count is
# unchanged: a stage that loses or invents entries must never reach the SD card.
# usage: install_candidate <candidate> <stage label>
install_candidate() {
    local candidate="$1" stage="$2"
    if [ "$(entry_count "$candidate")" != "$(entry_count "$FAV_FILE")" ]; then
        echo "$stage step skipped: the result had a different number of entries."
        return 1
    fi
    chmod 644 "$candidate" 2>/dev/null
    mv -f "$candidate" "$FAV_FILE" || die "Cannot replace $FAV_FILE (backup: $backup)."
    return 0
}

if [ ! -f "$FAV_FILE" ]; then
    die "No favourites file at $FAV_FILE, nothing to fix."
fi

# Temp files from a run that was killed before its trap could fire are removed
# first: they are never the real list.
rm -f "$FAV_FILE".fix1-* "$FAV_FILE".fix2-* "$FAV_FILE".fix3-* 2>/dev/null || :

timestamp=$(date +'%Y%m%d-%Hh%M')
backup="${FAV_FILE}_$timestamp"
cp "$FAV_FILE" "$backup" 2>/dev/null ||
    die "Cannot write $backup, favourites left untouched."
mkdir -p "$BACKUP_DIR" 2>/dev/null
cp "$FAV_FILE" "$BACKUP_DIR/favourite2.before-fix-$timestamp.json" 2>/dev/null ||
    echo "Warning: could not copy the favourites file to $BACKUP_DIR."

############################## Stage 1: label first ##############################
# MainUI expects "label" as the first key of every entry. The order is rebuilt
# with jq so that no other field can be lost: the greedy sed this replaces ate
# every key that sat before "label", .launch included.

TMP1="$FAV_FILE.fix1-$$"
tmp1="$TMP1"
: >"$tmp1" || die "Cannot create $tmp1, favourites left untouched."

while IFS= read -r line || [ -n "$line" ]; do
    if line_is_json "$line"; then
        reordered=$(printf '%s\n' "$line" | "$JQ" -c '
            if type == "object" and has("label") and (keys_unsorted[0] != "label")
            then {label: .label} + (del(.label))
            else . end' 2>/dev/null)
        [ -n "$reordered" ] || reordered="$line"
        printf '%s\n' "$reordered" >>"$tmp1" || die "Cannot write $tmp1, favourites left untouched."
    else
        printf '%s\n' "$line" >>"$tmp1" || die "Cannot write $tmp1, favourites left untouched."
    fi
done <"$FAV_FILE"
install_candidate "$tmp1" "Label"

########################### Stage 2: fill in sublabels ##########################
# Needs an awk whose match() accepts a capture array (gawk). If the awk on this
# firmware cannot do it the stage is skipped and the list is left as it is.

TMP2="$FAV_FILE.fix2-$$"
tmp2="$TMP2"
if awk '{
  match ($0, /sublabel":"([^"]*)"/, sublabel)
  match ($0, /rompath":"([^"]*)"/, rompath)
  if (sublabel[1] ~ /^[[:space:]]*$/) {
    match(rompath[1], /.*\/Roms\/([^\/]+)\/.*/, emudir)
    gsub(/sublabel":"[^"]*"/, "sublabel\":\"" emudir[1] "\"")
  }
  print
}' "$FAV_FILE" >"$tmp2" 2>/dev/null; then
    install_candidate "$tmp2" "Sublabel"
else
    echo "Sublabel step skipped: awk on this firmware does not support capture groups."
fi

######################## Stage 3: refresh .launch paths #########################

get_launch_from_config() {
    local emulator_path="$1"
    local config_file="${emulator_path}config.json"

    if [ -f "$config_file" ]; then
        "$JQ" -r '.launch // empty' "$config_file" 2>/dev/null
    else
        return 1
    fi
}

TMP3="$FAV_FILE.fix3-$$"
tmp3="$TMP3"
: >"$tmp3" || die "Cannot create $tmp3, favourites left untouched."

invalid_lines=0
while IFS= read -r line || [ -n "$line" ]; do
    if ! line_is_json "$line"; then
        # Never drop an unreadable line: it is reported, and the boot guard is
        # the one that quarantines it (with a backup) on the next start.
        printf '%s\n' "$line" >>"$tmp3" || die "Cannot write $tmp3, favourites left untouched."
        invalid_lines=$((invalid_lines + 1))
        continue
    fi

    launch_path=$(printf '%s\n' "$line" | "$JQ" -r '.launch // ""' 2>/dev/null)
    if [ -z "$launch_path" ]; then
        printf '%s\n' "$line" >>"$tmp3" || die "Cannot write $tmp3, favourites left untouched."
        continue
    fi

    emulator_dir=$(dirname "$launch_path")
    if new_launch=$(get_launch_from_config "$emulator_dir/") && [ -n "$new_launch" ]; then
        full_launch_path="$emulator_dir/$new_launch"
        updated_line=$(printf '%s\n' "$line" |
            "$JQ" -c --arg new_launch "$full_launch_path" '.launch = $new_launch' 2>/dev/null)
        if [ -n "$updated_line" ]; then
            printf '%s\n' "$updated_line" >>"$tmp3" ||
                die "Cannot write $tmp3, favourites left untouched."
            continue
        fi
    fi
    printf '%s\n' "$line" >>"$tmp3" || die "Cannot write $tmp3, favourites left untouched."
done <"$FAV_FILE"

install_candidate "$tmp3" "Launch" ||
    die "Launch step produced a different number of entries, favourites left untouched."
sync 2>/dev/null

echo "Update completed."
if [ "$invalid_lines" -gt 0 ]; then
    echo "$invalid_lines line(s) are not valid JSON and were kept as they are."
    echo "Reboot once so favorites_guard.sh can quarantine them with a backup."
fi
sleep 1

#!/bin/sh
#
# Sort the MainUI favourites list alphabetically.
#
# favourite2.json is NDJSON: one JSON object per line. The file is rewritten
# atomically - the sorted output goes to a temp file in the same directory, it is
# validated (same number of entries, still valid NDJSON) and only then does it
# replace the original. A failed or interrupted run therefore leaves the previous
# list exactly as it was, and a timestamped copy is always kept in
# System/backups before the first write.

PATH="/mnt/SDCARD/System/bin:$PATH"
export PATH

ROMS_DIR="${ROMS_DIR:-/mnt/SDCARD/Roms}"
FAV_FILE="$ROMS_DIR/favourite2.json"
BACKUP_DIR="${BACKUP_DIR:-/mnt/SDCARD/System/backups}"

/mnt/SDCARD/System/usr/trimui/scripts/infoscreen.sh -m "Sorting favorites..." 2>/dev/null

TMP_FILE=""
cleanup() {
    if [ -n "$TMP_FILE" ] && [ -f "$TMP_FILE" ]; then
        rm -f "$TMP_FILE" 2>/dev/null || :
    fi
}
trap cleanup 0
trap 'exit 1' INT TERM HUP

fail() {
    echo "$1"
    sleep 1
    exit 1
}

if [ ! -f "$FAV_FILE" ]; then
    echo "No favourites file at $FAV_FILE, nothing to sort."
    sleep 1
    exit 0
fi

SORT=$(command -v sort 2>/dev/null || :)
if [ -z "$SORT" ] && [ -x /usr/bin/sort ]; then
    SORT=/usr/bin/sort
fi
[ -n "$SORT" ] || fail "sort binary not found, favourites left untouched."

# NDJSON parsing is only needed to prove the result is still readable.
JQ=$(command -v jq 2>/dev/null || :)
if [ -z "$JQ" ] && [ -x /mnt/SDCARD/System/bin/jq ]; then
    JQ=/mnt/SDCARD/System/bin/jq
fi

entry_count() {
    awk 'END { print NR }' "$1" 2>/dev/null || :
}

before_count=$(entry_count "$FAV_FILE")
if [ "$before_count" -eq 0 ] 2>/dev/null; then
    echo "Favourites file is empty, nothing to sort."
    exit 0
fi

# Rollback copies: the historical in-place .bak plus a dated one that survives a
# user running the sort again.
cp "$FAV_FILE" "$FAV_FILE.bak" 2>/dev/null ||
    fail "Cannot write $FAV_FILE.bak, favourites left untouched."

mkdir -p "$BACKUP_DIR" 2>/dev/null
stamp=$(date '+%Y%m%d-%H%M%S')
cp "$FAV_FILE" "$BACKUP_DIR/favourite2.before-sort-$stamp.json" 2>/dev/null ||
    fail "Cannot write a backup in $BACKUP_DIR, favourites left untouched."

# A run killed mid-way leaves a temp file behind; it is never the real list.
rm -f "$ROMS_DIR"/favourite2.json.sort-*.tmp 2>/dev/null || :
TMP_FILE="$FAV_FILE.sort-$$.tmp"
"$SORT" "$FAV_FILE" >"$TMP_FILE" 2>/dev/null ||
    fail "sort failed, favourites left untouched."

after_count=$(entry_count "$TMP_FILE")
if [ "$after_count" != "$before_count" ]; then
    fail "Sorting changed the entry count ($before_count -> $after_count), favourites left untouched."
fi

if [ -n "$JQ" ]; then
    if ! "$JQ" . "$TMP_FILE" >/dev/null 2>&1; then
        fail "The favourites file has lines that are not valid JSON. Nothing was changed; reboot to let the boot guard isolate them."
    fi
fi

chmod 644 "$TMP_FILE" 2>/dev/null || :
mv -f "$TMP_FILE" "$FAV_FILE" || fail "Cannot replace $FAV_FILE (backup: $BACKUP_DIR/favourite2.before-sort-$stamp.json)."
TMP_FILE=""
sync 2>/dev/null || :
sync 2>/dev/null || :

sleep 1

#!/bin/sh
#
# favorites_guard.sh - keep MainUI bootable when the favourites list is corrupt.
#
# /mnt/SDCARD/Roms/favourite2.json is NDJSON: one JSON object per line, NOT a
# single JSON document. MainUI parses it during startup and never leaves its
# "loading" screen when a line does not parse, or when an entry points to a
# launcher (.launch) that no longer exists. There is no in-UI way out of that
# state (rebooting does not help: the file is read again), so it must be
# repaired before the menu is launched.
#
# This guard validates every line on its own with jq, keeps the entries that are
# valid AND point to an existing launcher, and moves the original file to
# System/backups before writing the cleaned list. It never deletes data and it
# always exits 0: a broken favourites file must never become a broken boot.
#
# Overridable for testing / reuse (defaults are the real SD card paths):
#   SDCARD, FAVORITES_ROMS_DIR, FAVORITES_BACKUP_DIR, FAVORITES_LOG_FILE, JQ

SDCARD="${SDCARD:-/mnt/SDCARD}"
ROMS_DIR="${FAVORITES_ROMS_DIR:-$SDCARD/Roms}"
FAV_FILE="$ROMS_DIR/favourite2.json"
BACKUP_DIR="${FAVORITES_BACKUP_DIR:-$SDCARD/System/backups}"
LOG_FILE="${FAVORITES_LOG_FILE:-$SDCARD/Apps/SystemTools/Logs/favorites_guard.log}"

TMP_FILE=""

log() {
    # Never let logging failures affect the guard itself.
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
    if [ -f "$LOG_FILE" ]; then
        # Keep the log bounded: one rotation is enough for a diagnostics file.
        log_size=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')
        case "$log_size" in
            '' | *[!0-9]*) : ;;
            *)
                if [ "$log_size" -gt 65536 ]; then
                    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || :
                fi
                ;;
        esac
    fi
    printf '%s favorites_guard[%s]: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$1" >>"$LOG_FILE" 2>/dev/null || :
}

cleanup() {
    if [ -n "$TMP_FILE" ] && [ -f "$TMP_FILE" ]; then
        rm -f "$TMP_FILE" 2>/dev/null || :
    fi
}

# Exit 0 whatever happens: this script runs unattended during the boot.
trap cleanup 0
trap 'exit 1' INT TERM HUP

# Nothing to guard on a card without favourites.
if [ ! -f "$FAV_FILE" ]; then
    exit 0
fi

# Resolve jq explicitly: PATH is not guaranteed in the early boot environment.
if [ -z "${JQ:-}" ]; then
    if [ -x "$SDCARD/System/bin/jq" ]; then
        JQ="$SDCARD/System/bin/jq"
    elif command -v jq >/dev/null 2>&1; then
        JQ="jq"
    fi
fi
if [ -z "${JQ:-}" ]; then
    # Without jq nothing can be validated. Do not touch the file: a wrong guess
    # here would destroy a list that MainUI may still be able to read.
    log "ERROR jq not found, favourites file left untouched"
    exit 0
fi

# A jq that cannot parse a known-good object would classify every entry as
# broken and empty the list, so probe it before trusting any verdict.
if ! printf '{"probe":1}\n' | "$JQ" empty >/dev/null 2>&1; then
    log "ERROR jq unusable ($JQ), favourites file left untouched"
    exit 0
fi

# Count the entries (non-blank lines) of a favourites file.
count_entries() {
    grep -c . "$1" 2>/dev/null || :
}

# Resolve a .launch value to a path we can test. Relative values are taken
# relative to the SD card root, which is how the firmware scripts treat them.
launch_path() {
    case "$1" in
        "") return 1 ;;
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$SDCARD" "$1" ;;
    esac
}

# Fast path: the whole file is valid NDJSON and every entry points to an
# existing launcher. Nothing to do on the (very common) healthy card, so the
# per-line jq loop below is not paid for on every boot.
if "$JQ" . "$FAV_FILE" >/dev/null 2>&1 &&
    [ "$(awk 'END { print NR }' "$FAV_FILE" 2>/dev/null)" = "$(count_entries "$FAV_FILE")" ]; then
    launches_ok=1
    "$JQ" -r '(.launch // "") | tostring' "$FAV_FILE" 2>/dev/null |
        while IFS= read -r entry_launch; do
            if ! entry_path=$(launch_path "$entry_launch"); then
                exit 1
            fi
            if [ ! -f "$entry_path" ]; then
                exit 1
            fi
        done || launches_ok=0

    if [ "$launches_ok" -eq 1 ]; then
        log "OK entries=$(count_entries "$FAV_FILE") no change"
        exit 0
    fi
fi

# Slow path: something is wrong, rebuild the list line by line.
# Temp files from a run that was killed before its trap could fire (the boot hook
# time-boxes this script) are removed first: they are never the real list.
rm -f "$ROMS_DIR"/favourite2.json.guard-*.tmp 2>/dev/null || :
TMP_FILE="$ROMS_DIR/favourite2.json.guard-$$.tmp"
if ! : >"$TMP_FILE" 2>/dev/null; then
    TMP_FILE=""
    log "ERROR cannot create temp file in $ROMS_DIR, favourites file left untouched"
    exit 0
fi

valid_count=0
bad_parse=0
bad_launch=0
blank_count=0

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        *[![:space:]]*) : ;;
        *)
            # Empty / whitespace-only line: not an entry, cannot be kept.
            blank_count=$((blank_count + 1))
            continue
            ;;
    esac

    if ! printf '%s\n' "$line" | "$JQ" empty >/dev/null 2>&1; then
        bad_parse=$((bad_parse + 1))
        continue
    fi

    entry_launch=$(printf '%s\n' "$line" | "$JQ" -r '(.launch // "") | tostring' 2>/dev/null)
    if ! entry_path=$(launch_path "$entry_launch"); then
        bad_launch=$((bad_launch + 1))
        continue
    fi
    if [ ! -f "$entry_path" ]; then
        bad_launch=$((bad_launch + 1))
        continue
    fi

    # Keep the entry byte for byte: MainUI reads it as-is, and rewriting it
    # would hide the very thing the user may want to inspect in the backup.
    printf '%s\n' "$line" >>"$TMP_FILE" || {
        log "ERROR cannot write temp file, favourites file left untouched"
        exit 0
    }
    valid_count=$((valid_count + 1))
done <"$FAV_FILE"

dropped=$((bad_parse + bad_launch + blank_count))
if [ "$dropped" -eq 0 ]; then
    # Every line survived, so the file is fine (the fast path already checked
    # the launchers). Leave it untouched rather than rewrite it for nothing.
    log "OK entries=$valid_count no change"
    exit 0
fi

# Back up the original before anything replaces it. The backup is verified
# byte for byte: if it does not match, we abort with the original in place
# instead of gambling on the copy.
mkdir -p "$BACKUP_DIR" 2>/dev/null
stamp=$(date '+%Y%m%d-%H%M%S')
BACKUP_FILE="$BACKUP_DIR/favourite2.bad-$stamp.json"
suffix=1
while [ -e "$BACKUP_FILE" ]; do
    BACKUP_FILE="$BACKUP_DIR/favourite2.bad-$stamp-$suffix.json"
    suffix=$((suffix + 1))
done

if ! cp "$FAV_FILE" "$BACKUP_FILE" 2>/dev/null; then
    log "ERROR cannot write backup $BACKUP_FILE, favourites file left untouched"
    exit 0
fi
if ! cmp -s "$FAV_FILE" "$BACKUP_FILE" 2>/dev/null; then
    # Incomplete copy: quarantine it so it can never be mistaken for a good one.
    mv -f "$BACKUP_FILE" "$BACKUP_FILE.partial" 2>/dev/null || :
    log "ERROR backup verification failed for $BACKUP_FILE.partial, favourites file left untouched"
    exit 0
fi

# The rename is atomic: MainUI sees either the old file or the cleaned one.
chmod 644 "$TMP_FILE" 2>/dev/null || :
if ! mv -f "$TMP_FILE" "$FAV_FILE" 2>/dev/null; then
    log "ERROR cannot replace $FAV_FILE, original kept (backup: $BACKUP_FILE)"
    exit 0
fi
TMP_FILE=""
sync 2>/dev/null || :

log "REPAIRED kept=$valid_count dropped_parse=$bad_parse dropped_missing_launch=$bad_launch dropped_blank=$blank_count backup=$BACKUP_FILE"
exit 0

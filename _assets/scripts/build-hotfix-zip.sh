#!/bin/sh
# Rebuild _assets/hotfixes/CrossMix-OS_v1.4.0-ce.2.zip from the working tree.
#
# Run from the repo root (or any cwd; paths are resolved from this script).
# After rebasing onto main, regenerate the zip so it ships the same OTA scripts
# as the tree (canonical version comparator, error propagation, etc.). Do not
# hand-edit the zip.
#
# Contents (paths relative to SD root /mnt/SDCARD):
#   Apps/SystemTools/Menu/TOOLS/Firmware Update.sh
#   Apps/SystemTools/launch.sh
#   System/starts/_FirmwareCheck.sh
#   System/usr/trimui/crossmix-version.txt
#   System/usr/trimui/scripts/ota_update.sh
#   System/usr/trimui/scripts/update_common.sh
#   System/usr/trimui/scripts/update_notification.sh
#   System/usr/trimui/scripts/update_ota_release.sh
#   System/usr/trimui/scripts/favorites_guard.sh
System/usr/trimui/scripts/ssh_start.sh
#   System/starts/°customization.sh
#   trimui/firmwares/MinFwVersion.txt
#
# Usage: sh _assets/scripts/build-hotfix-zip.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
OUT="$ROOT/_assets/hotfixes/CrossMix-OS_v1.4.0-ce.2.zip"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM

# shellcheck disable=SC2086
FILES="
Apps/SystemTools/Menu/TOOLS/Firmware Update.sh
Apps/SystemTools/launch.sh
System/starts/_FirmwareCheck.sh
System/usr/trimui/crossmix-version.txt
System/usr/trimui/scripts/ota_update.sh
System/usr/trimui/scripts/update_common.sh
System/usr/trimui/scripts/update_notification.sh
System/usr/trimui/scripts/update_ota_release.sh
System/usr/trimui/scripts/favorites_guard.sh
System/usr/trimui/scripts/ssh_start.sh
System/starts/°customization.sh
trimui/firmwares/MinFwVersion.txt
"

missing=0
# IFS newline for paths with spaces
OLDIFS=$IFS
IFS='
'
for rel in $FILES; do
	[ -z "$rel" ] && continue
	src="$ROOT/$rel"
	if [ ! -f "$src" ]; then
		echo "missing: $rel" >&2
		missing=1
		continue
	fi
	dir=$(dirname "$rel")
	mkdir -p "$STAGE/$dir"
	cp -a "$src" "$STAGE/$rel"
done
IFS=$OLDIFS

if [ "$missing" -ne 0 ]; then
	echo "abort: required tree files missing (sparse checkout?)" >&2
	exit 1
fi

rm -f "$OUT"
# Prefer 7z (matches console tooling), fall back to zip.
if command -v 7z >/dev/null 2>&1; then
	(cd "$STAGE" && 7z a -tzip -mx=9 "$OUT" . >/dev/null)
elif command -v 7zz >/dev/null 2>&1; then
	(cd "$STAGE" && 7zz a -tzip -mx=9 "$OUT" . >/dev/null)
elif command -v zip >/dev/null 2>&1; then
	(cd "$STAGE" && zip -r -q "$OUT" .)
else
	echo "abort: need 7z, 7zz or zip" >&2
	exit 1
fi

echo "Wrote $OUT"
echo "--- contents ---"
if command -v unzip >/dev/null 2>&1; then
	unzip -l "$OUT"
else
	7z l "$OUT" 2>/dev/null || 7zz l "$OUT"
fi
echo "--- sha256 (zip) ---"
sha256sum "$OUT"
echo "--- sha256 (members) ---"
# list member digests for verification without extract order noise
python3 - <<PY
import hashlib, zipfile, sys
z = zipfile.ZipFile("$OUT")
rows = []
for info in z.infolist():
    if info.is_dir():
        continue
    data = z.read(info.filename)
    h = hashlib.sha256(data).hexdigest()
    rows.append((info.filename, len(data), h))
for name, size, h in sorted(rows):
    print(f"{h}  {size:6d}  {name}")
PY

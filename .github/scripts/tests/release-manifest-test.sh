#!/bin/sh
# release-manifest-test.sh - inclusion/exclusion fixture for release-manifest.sh
#
# Builds a throw-away tree that looks like the release payload, runs the generator on the
# pre-transform and post-transform variants, and asserts what the manifest must contain.
# No device binary is executed; the .7z archive used here only holds a text file.
#
# Usage: sh .github/scripts/tests/release-manifest-test.sh

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
GENERATOR="$HERE/../release-manifest.sh"
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t manifest-test)
FAILED=0

cleanup() {
	[ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

fail() {
	printf 'FAIL  %s\n' "$1"
	FAILED=1
}

pass() {
	printf 'ok    %s\n' "$1"
}

check() {
	desc=$1
	shift
	if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

need() {
	command -v "$1" >/dev/null 2>&1 || {
		printf 'missing required tool: %s\n' "$1" >&2
		exit 1
	}
}

need jq
need sha256sum

TREE="$WORK/tree"
mkdir -p "$TREE/System/usr/trimui" "$TREE/_assets/readme" "$TREE/Apps/SystemTools"
mkdir -p "$TREE/RetroArch/.retroarch/cores" "$TREE/Emus/SNES" "$TREE/BIOS" "$TREE/Roms"
mkdir -p "$TREE/empty-dir"

printf 'version 9.9.9\n' >"$TREE/System/usr/trimui/crossmix-version.txt"
printf 'autorun\n' >"$TREE/autorun.inf"
printf 'icon\n' >"$TREE/.VolumeIcon.icns"
printf 'readme\n' >"$TREE/README.md"
printf 'shot\n' >"$TREE/_assets/readme/shot.png"
printf 'keep\n' >"$TREE/Emus/SNES/.gitkeep"
printf 'launcher\n' >"$TREE/Apps/SystemTools/tool.sh"
printf 'emu\n' >"$TREE/Emus/SNES/snes9x"
printf 'bios\n' >"$TREE/BIOS/scph1001.bin"
printf 'rom\n' >"$TREE/Roms/demo.zip"

# A real GNU GPL-3.0 text so the license classifier has something to recognise.
sed -n '1,30p' "$HERE/../../../LICENSE" 2>/dev/null >"$TREE/LICENSE" ||
	printf 'GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\n' >"$TREE/LICENSE"

# One compressed core, mirroring the five real ones.
printf 'core payload\n' >"$WORK/core.bin"
# Some PATH entries carry foreign 7z builds (e.g. device payloads); trust the result, not the name.
make_archive() {
	for tool in 7zz 7z 7za; do
		command -v "$tool" >/dev/null 2>&1 || continue
		rm -f "$WORK/core.7z"
		( cd "$WORK" && "$tool" a -bso0 -bsp0 core.7z core.bin ) >/dev/null 2>&1 || true
		[ -f "$WORK/core.7z" ] && return 0
	done
	return 1
}
if make_archive; then
	mv "$WORK/core.7z" "$TREE/RetroArch/.retroarch/cores/mame_libretro.7z"
else
	printf 'no 7z available: core archive fixture skipped\n' >&2
fi

CORE_REL="RetroArch/.retroarch/cores/mame_libretro.7z"

# ---------------------------------------------------------------- record inputs

"$GENERATOR" --tree "$TREE" --record-inputs "$WORK/inputs.tsv" >/dev/null
if [ -f "$TREE/$CORE_REL" ]; then
	check "record-inputs captures the core archive" \
		awk -F'\t' -v p="$CORE_REL" '$1 == "core-archive" && $2 == p {found = 1} END {exit !found}' "$WORK/inputs.tsv"
	recorded_sha=$(awk -F'\t' -v p="$CORE_REL" '$1 == "core-archive" && $2 == p {print $4}' "$WORK/inputs.tsv")
	real_sha=$(sha256sum "$TREE/$CORE_REL" | cut -d' ' -f1)
	check "recorded archive sha256 matches sha256sum" test "$recorded_sha" = "$real_sha"
fi

# ---------------------------------------------------------------- pre-transform

"$GENERATOR" --tree "$TREE" --version 1.0.0 --tag v1.0.0 \
	--inputs "$WORK/inputs.tsv" --output "$WORK/pre.json" 2>/dev/null

check "pre-transform: JSON is valid" jq empty "$WORK/pre.json"
check "pre-transform: tree state is pre-transform" \
	jq -e '.tree.state == "pre-transform"' "$WORK/pre.json"
check "pre-transform: .gitkeep is listed" \
	jq -e '[.files[].path] | index("Emus/SNES/.gitkeep") != null' "$WORK/pre.json"
check "pre-transform: LICENSE is listed" \
	jq -e '[.files[].path] | index("LICENSE") != null' "$WORK/pre.json"
check "pre-transform: hidden files are counted" \
	jq -e '.tree.hidden_file_count >= 2' "$WORK/pre.json"
check "pre-transform: version stamp mismatch is a warning" \
	jq -e '[.warnings[] | select(contains("version stamp"))] | length == 1' "$WORK/pre.json"
check "pre-transform: core archive recorded as an input" \
	jq -e '[.inputs[] | select(.kind == "core-archive")] | length == 1' "$WORK/pre.json"
check "pre-transform: extraction still pending" \
	jq -e '[.transformations[] | select(.id == "extract-core-archives" and .observed == "pending")] | length == 1' "$WORK/pre.json"
check "pre-transform: repository LICENSE licenses the project code" \
	jq -e '.components[] | select(.id == "crossmix-se") | .license == "GPL-3.0"' "$WORK/pre.json"
check "pre-transform: BIOS has no license evidence" \
	jq -e '.components[] | select(.id == "bios") | .license == "DESCONOCIDA"' "$WORK/pre.json"
check "pre-transform: components cover every file" \
	jq -e '([.components[].file_count] | add) == .totals.file_count' "$WORK/pre.json"

# every file hash must match sha256sum on disk
bad=0
for rel in $(jq -r '.files[].path' "$WORK/pre.json"); do
	want=$(sha256sum "$TREE/$rel" | cut -d' ' -f1)
	got=$(jq -r --arg p "$rel" '.files[] | select(.path == $p) | .sha256' "$WORK/pre.json")
	[ "$want" = "$got" ] || bad=$((bad + 1))
done
check "pre-transform: all file sha256 match sha256sum" test "$bad" -eq 0

# ---------------------------------------------------------------- post-transform

rm -f "$TREE/Emus/SNES/.gitkeep"
rm -rf "$TREE/_assets"
rm -f "$TREE/LICENSE" "$TREE/README.md"
printf '1.0.0' >"$TREE/System/usr/trimui/crossmix-version.txt"
printf 'config\n' >"$TREE/RetroArch/default_config.7z"
rm -f "$TREE/$CORE_REL"
printf 'core payload\n' >"$TREE/RetroArch/.retroarch/cores/mame_libretro.so"

head -c 2048 /dev/urandom >"$WORK/post.7z"
"$GENERATOR" --tree "$TREE" --version 1.0.0 --tag v1.0.0 \
	--inputs "$WORK/inputs.tsv" --artifact "$WORK/post.7z" --output "$WORK/post.json" 2>/dev/null

check "post-transform: JSON is valid" jq empty "$WORK/post.json"
check "post-transform: tree state is post-transform" \
	jq -e '.tree.state == "post-transform"' "$WORK/post.json"
check "post-transform: LICENSE is not in the payload" \
	jq -e '[.files[].path] | index("LICENSE") == null' "$WORK/post.json"
check "post-transform: _assets is not in the payload" \
	jq -e '[.files[].path] | map(select(startswith("_assets/"))) | length == 0' "$WORK/post.json"
check "post-transform: no .gitkeep left" \
	jq -e '[.files[].path] | map(select(endswith(".gitkeep"))) | length == 0' "$WORK/post.json"
check "post-transform: version stamp accepted" \
	jq -e '[.transformations[] | select(.id == "stamp-version" and .observed == "match")] | length == 1' "$WORK/post.json"
check "post-transform: extraction observed as applied" \
	jq -e '[.transformations[] | select(.id == "extract-core-archives" and .observed == "applied")] | length == 1' "$WORK/post.json"
check "post-transform: default_config.7z is in the payload" \
	jq -e '[.files[].path] | index("RetroArch/default_config.7z") != null' "$WORK/post.json"
check "post-transform: license text is not shipped" \
	jq -e '.components[] | select(.id == "crossmix-se") | .license == "GPL-3.0"' "$WORK/post.json"

# ---------------------------------------------------------------- surfaces

"$GENERATOR" --tree "$TREE" --version 1.0.0 --surface kit --include Emus \
	--output "$WORK/kit.json" 2>/dev/null
check "kit surface: only the selected subtree is listed" \
	jq -e '(.files | length) == 1 and .files[0].path == "Emus/SNES/snes9x"' "$WORK/kit.json"
check "kit surface: selection is recorded" \
	jq -e '.release.selection == ["Emus"]' "$WORK/kit.json"

"$GENERATOR" --tree "$TREE" --version 1.0.0 --surface hotfix --include Apps/SystemTools \
	--output "$WORK/hotfix.json" 2>/dev/null
check "hotfix surface: manifest is valid" jq empty "$WORK/hotfix.json"
check "hotfix surface: files are marked distributed" \
	jq -e '.components[0].distributed == true' "$WORK/hotfix.json"

if "$GENERATOR" --tree "$TREE" --version 1.0.0 --surface image --include Apps \
	--output "$WORK/bad.json" >/dev/null 2>&1; then
	fail "image surface rejects --include"
else
	pass "image surface rejects --include"
fi

if "$GENERATOR" --tree "$TREE" --version 1.0.0 --surface kit \
	--output "$WORK/bad2.json" >/dev/null 2>&1; then
	fail "kit surface requires --include"
else
	pass "kit surface requires --include"
fi

# ---------------------------------------------------------------- reproducibility

"$GENERATOR" --tree "$TREE" --version 1.0.0 --generated-at 2026-01-01T00:00:00Z \
	--output "$WORK/r1.json" 2>/dev/null
"$GENERATOR" --tree "$TREE" --version 1.0.0 --generated-at 2026-01-01T00:00:00Z \
	--output "$WORK/r2.json" 2>/dev/null
check "pinned timestamp: two runs produce identical manifests" cmp -s "$WORK/r1.json" "$WORK/r2.json"

if [ "$FAILED" -ne 0 ]; then
	printf '\nmanifest fixture: FAILED\n' >&2
	exit 1
fi
printf '\nmanifest fixture: all checks passed\n'

#!/bin/sh
# release-manifest.sh - reproducible manifest for a CrossMix-OS SE release surface.
#
# Purpose
#   Tie together, in one machine-readable file:
#     tagged commit -> pre-transform inputs -> transformations -> payload tree -> published artifact
#   and record, per distributed component, the license the tree itself evidences.
#
# Two modes
#   manifest mode (default)   hash a tree, list transformations/components/artifacts, write JSON.
#   --record-inputs FILE      run BEFORE any transformation and record the inputs that packaging
#                             destroys (core .7z archives that get extracted, firmware parts).
#                             Read-only: it never extracts or executes anything.
#
# Design rules
#   * POSIX sh only (busybox sh -n clean), no bashisms, no arrays.
#   * Optional tools (7z, git) are never required: when absent the field is null and a status
#     string says why. The script never invents a value it could not measure.
#   * A license is reported only when a license file inside the tree says so. Otherwise the
#     component is DESCONOCIDA (unknown). A repository LICENSE does not license third-party
#     payloads, so it is never used as a blanket answer.
#
# Exit codes: 0 ok, 1 usage/IO error.

set -eu

LC_ALL=C
export LC_ALL

PROG=release-manifest.sh
# Kept under .github so the packaging step (which deletes .github) cannot ship tooling to the SD card.
GENERATOR_PATH=.github/scripts/release-manifest.sh
SCHEMA=crossmix-release-manifest/1

ROOT=
VERSION=
TAG=
COMMIT=
SURFACE=image
OUTPUT=
RECORD_INPUTS=
GENERATED_AT=
REPOSITORY=
WF_PATH=
WF_SHA=
WF_REF=
RUN_ID=
RUN_URL=
GIT_BYTES=
MEASURE_GIT=0
INSPECT_ARCHIVES=1

TMP=

usage() {
	cat <<'EOF'
usage: release-manifest.sh --tree DIR --version VERSION [options]
       release-manifest.sh --tree DIR --record-inputs FILE [options]

Required
  --tree DIR             Tree to describe (repository root or packaged payload).
  --version VERSION      Release version, without the leading "v" (e.g. 1.4.0-ce.2.15).

Surface
  --surface NAME         image (default) | hotfix | kit.
                         image : the whole tree, published as the SD image archive.
                         hotfix: a targeted subset published as an incremental payload.
                         kit   : a targeted subset that is NOT an image (tool/dev bundle).
  --include PATH         Restrict the manifest to PATH (repeatable). Required for
                         hotfix/kit, rejected for image (an image is the whole tree).

Provenance
  --tag TAG              Release tag (default: v$VERSION).
  --commit SHA           Commit the tree comes from.
  --repository OWNER/REPO
  --workflow PATH        Workflow file that produced the release.
  --workflow-sha256 HEX  sha256 of that workflow file (packaging deletes it from the payload).
  --ref REF              Git ref of the run (e.g. refs/tags/v1.4.0).
  --run-id ID            CI run id.
  --run-url URL          CI run URL.
  --generated-at TS      Pin the timestamp (UTC, YYYY-MM-DDTHH:MM:SSZ) for reproducibility.
  --git-object-bytes N   Physical size of the tagged tree's git blobs (measured before packaging).
  --measure-git-bytes    Measure it here with git ls-tree (needs a full, non-partial clone).
  --no-inspect-archives  Do not list .7z members with 7z (default: inspect when available).
  --inputs FILE          Pre-transform input recording from --record-inputs (repeatable).

Output
  --artifact PATH        Published artifact to hash (repeatable).
  --output FILE          Write JSON here (default: stdout).
  --note TEXT            Free-form note added to the manifest (repeatable).

Other
  --record-inputs FILE   Record pre-transform inputs as TSV and exit.
  -h, --help             This help.

Examples
  .github/scripts/release-manifest.sh --tree . --version 1.4.0 --surface image \
      --tag v1.4.0 --commit "$GITHUB_SHA" --artifact ../CrossMix-OS_v1.4.0.7z \
      --output /tmp/CrossMix-OS_v1.4.0.manifest.json
  .github/scripts/release-manifest.sh --tree . --surface kit --include Apps/SystemTools \
      --version 1.4.0 --output kit.json
EOF
}

die() {
	printf '%s: error: %s\n' "$PROG" "$1" >&2
	exit 1
}

note() {
	printf '%s: %s\n' "$PROG" "$1" >&2
}

cleanup() {
	if [ -n "$TMP" ] && [ -d "$TMP" ]; then
		rm -rf "$TMP"
	fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- primitives

now_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
}

file_size() {
	if [ "$STAT_GNU" = 1 ]; then
		stat -c %s -- "$1"
	else
		wc -c <"$1" | tr -d ' '
	fi
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum -- "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 -- "$1" | cut -d' ' -f1
	else
		die "no sha256 implementation found (sha256sum/shasum)"
	fi
}

abs_dir() {
	(cd "$1" 2>/dev/null && pwd -P) || die "not a directory: $1"
}


# Shared awk helper: emit a JSON-safe string body (no surrounding quotes).
AWK_JSON_LIB='
function jesc(s,   out, i, c, n) {
	out = ""
	n = length(s)
	for (i = 1; i <= n; i++) {
		c = substr(s, i, 1)
		if (c == "\\") out = out "\\\\"
		else if (c == "\"") out = out "\\\""
		else if (c == "\t") out = out "\\t"
		else out = out c
	}
	return out
}
'

# json_escape STRING -> JSON string body (no surrounding quotes).
json_escape() {
	printf '%s' "$1" | awk "$AWK_JSON_LIB"' { printf "%s", jesc($0) }'
}

# classify_license FILE -> SPDX-ish id, or UNRECOGNISED / UNREADABLE.
classify_license() {
	f=$1
	if ! head -c 4096 -- "$f" >"$TMP/head.$$" 2>/dev/null; then
		printf 'UNREADABLE'
		return 0
	fi
	headTxt=$(tr -d '\000' <"$TMP/head.$$")
	rm -f "$TMP/head.$$"
	if printf '%s' "$headTxt" | grep -qi 'GNU AFFERO GENERAL PUBLIC LICENSE'; then
		printf 'AGPL-3.0'
	elif printf '%s' "$headTxt" | grep -qi 'GNU LESSER GENERAL PUBLIC LICENSE'; then
		case $headTxt in
		*"Version 3"*) printf 'LGPL-3.0' ;;
		*"Version 2.1"*) printf 'LGPL-2.1' ;;
		*) printf 'LGPL' ;;
		esac
	elif printf '%s' "$headTxt" | grep -qi 'GNU GENERAL PUBLIC LICENSE'; then
		case $headTxt in
		*"Version 3"*) printf 'GPL-3.0' ;;
		*"Version 2"*) printf 'GPL-2.0' ;;
		*) printf 'GPL' ;;
		esac
	elif printf '%s' "$headTxt" | grep -qi 'Permission is hereby granted, free of charge'; then
		printf 'MIT'
	elif printf '%s' "$headTxt" | grep -qi 'Redistribution and use in source and binary forms'; then
		if printf '%s' "$headTxt" | grep -qi 'Neither the name'; then
			printf 'BSD-3-Clause'
		else
			printf 'BSD-2-Clause'
		fi
	elif printf '%s' "$headTxt" | grep -qi 'Apache License' &&
		printf '%s' "$headTxt" | grep -q 'Version 2.0'; then
		printf 'Apache-2.0'
	elif printf '%s' "$headTxt" | grep -qiE 'Attribution 4\.0 International|Creative Commons Attribution 4\.0'; then
		printf 'CC-BY-4.0'
	elif printf '%s' "$headTxt" | grep -qi 'SIL OPEN FONT LICENSE'; then
		printf 'OFL-1.1'
	elif printf '%s' "$headTxt" | grep -qi 'Mozilla Public License'; then
		printf 'MPL-2.0'
	elif printf '%s' "$headTxt" | grep -qi 'altered source versions must be plainly marked'; then
		printf 'Zlib'
	elif printf '%s' "$headTxt" | grep -qiE 'public domain|CC0 1\.0'; then
		printf 'CC0-1.0'
	else
		printf 'UNRECOGNISED'
	fi
}

# ---------------------------------------------------------------- arguments

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t manifest) || {
	printf '%s: error: cannot create temp dir\n' "$PROG" >&2
	exit 1
}
: >"$TMP/includes.txt"
: >"$TMP/artifacts.txt"
: >"$TMP/notes.txt"
: >"$TMP/warnings.txt"
: >"$TMP/inputs.tsv"

if stat -c %s /dev/null >/dev/null 2>&1; then STAT_GNU=1; else STAT_GNU=0; fi

while [ $# -gt 0 ]; do
	case $1 in
	--tree)
		[ $# -ge 2 ] || die "--tree needs a value"
		ROOT=$2
		shift 2
		;;
	--version)
		[ $# -ge 2 ] || die "--version needs a value"
		VERSION=$2
		shift 2
		;;
	--tag)
		[ $# -ge 2 ] || die "--tag needs a value"
		TAG=$2
		shift 2
		;;
	--commit)
		[ $# -ge 2 ] || die "--commit needs a value"
		COMMIT=$2
		shift 2
		;;
	--surface)
		[ $# -ge 2 ] || die "--surface needs a value"
		SURFACE=$2
		shift 2
		;;
	--include)
		[ $# -ge 2 ] || die "--include needs a value"
		printf '%s\n' "$2" >>"$TMP/includes.txt"
		shift 2
		;;
	--output)
		[ $# -ge 2 ] || die "--output needs a value"
		OUTPUT=$2
		shift 2
		;;
	--record-inputs)
		[ $# -ge 2 ] || die "--record-inputs needs a value"
		RECORD_INPUTS=$2
		shift 2
		;;
	--inputs)
		[ $# -ge 2 ] || die "--inputs needs a value"
		[ -f "$2" ] || die "--inputs file not found: $2"
		cat "$2" >>"$TMP/inputs.tsv"
		shift 2
		;;
	--generated-at)
		[ $# -ge 2 ] || die "--generated-at needs a value"
		GENERATED_AT=$2
		shift 2
		;;
	--repository)
		[ $# -ge 2 ] || die "--repository needs a value"
		REPOSITORY=$2
		shift 2
		;;
	--workflow)
		[ $# -ge 2 ] || die "--workflow needs a value"
		WF_PATH=$2
		shift 2
		;;
	--workflow-sha256)
		[ $# -ge 2 ] || die "--workflow-sha256 needs a value"
		WF_SHA=$2
		shift 2
		;;
	--ref)
		[ $# -ge 2 ] || die "--ref needs a value"
		WF_REF=$2
		shift 2
		;;
	--run-id)
		[ $# -ge 2 ] || die "--run-id needs a value"
		RUN_ID=$2
		shift 2
		;;
	--run-url)
		[ $# -ge 2 ] || die "--run-url needs a value"
		RUN_URL=$2
		shift 2
		;;
	--git-object-bytes)
		[ $# -ge 2 ] || die "--git-object-bytes needs a value"
		GIT_BYTES=$2
		shift 2
		;;
	--measure-git-bytes)
		MEASURE_GIT=1
		shift
		;;
	--no-inspect-archives)
		INSPECT_ARCHIVES=0
		shift
		;;
	--artifact)
		[ $# -ge 2 ] || die "--artifact needs a value"
		printf '%s\n' "$2" >>"$TMP/artifacts.txt"
		shift 2
		;;
	--note)
		[ $# -ge 2 ] || die "--note needs a value"
		printf '%s\n' "$2" >>"$TMP/notes.txt"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown argument: $1 (try --help)"
		;;
	esac
done

[ -n "$ROOT" ] || {
	usage >&2
	die "--tree is required"
}
[ -d "$ROOT" ] || die "tree is not a directory: $ROOT"
TREE_ROOT=$(abs_dir "$ROOT")

case $SURFACE in
image | hotfix | kit) ;;
*) die "invalid --surface: $SURFACE (image|hotfix|kit)" ;;
esac

INC_COUNT=$(wc -l <"$TMP/includes.txt" | tr -d ' ')
if [ "$SURFACE" = image ] && [ "$INC_COUNT" -gt 0 ]; then
	die "surface 'image' covers the whole tree by definition; use --surface hotfix|kit for a selection"
fi
if [ "$SURFACE" != image ] && [ "$INC_COUNT" -eq 0 ]; then
	die "surface '$SURFACE' is a selection: pass at least one --include PATH"
fi

if [ -z "$GENERATED_AT" ]; then
	GENERATED_AT=$(now_utc)
	TIMESTAMP_PINNED=false
else
	TIMESTAMP_PINNED=true
fi

# ---------------------------------------------------------------- inputs mode

archive_members() {
	# Echo "members<TAB>uncompressed_bytes" for a 7z archive, or "-<TAB>-".
	_a=$1
	if [ "$INSPECT_ARCHIVES" != 1 ]; then
		printf -- '-\t-'
		return 0
	fi
	_7z=
	if command -v 7zz >/dev/null 2>&1; then
		_7z=7zz
	elif command -v 7z >/dev/null 2>&1; then
		_7z=7z
	else
		printf -- '-\t-'
		return 0
	fi
	_listing="$TMP/7z.$$"
	if ! "$_7z" l -slt -- "$_a" >"$_listing" 2>/dev/null; then
		printf -- '-\t-'
		rm -f "$_listing"
		return 0
	fi
	awk -F' = ' '
		/^Path = / { n++; next }
		/^Size = / { if ($2 ~ /^[0-9]+$/) bytes += $2; next }
		END {
			if (n > 0) n = n - 1
			if (n < 0) n = 0
			if (bytes == "") bytes = 0
			printf "%d\t%.0f\n", n, bytes
		}' "$_listing"
	rm -f "$_listing"
}

record_inputs() {
	out=$1
	: >"$out"

	# Core archives: extracted and deleted by the release workflow.
	if [ -d "$TREE_ROOT/RetroArch/.retroarch/cores" ]; then
		find "$TREE_ROOT/RetroArch/.retroarch/cores" -maxdepth 1 -type f -name '*.7z' | sort |
			while IFS= read -r f; do
				rel=${f#"$TREE_ROOT"/}
				sz=$(file_size "$f")
				h=$(sha256_of "$f")
				m=$(archive_members "$f")
				printf '%s\t%s\t%s\t%s\t%s\trecorded\n' \
					"core-archive" "$rel" "$sz" "$h" "$m"
			done >>"$out"
	fi

	# Firmware payload split volumes shipped to the device.
	if [ -d "$TREE_ROOT/trimui/firmwares" ]; then
		find "$TREE_ROOT/trimui/firmwares" -maxdepth 1 -type f -name 'firmware_*.7z.*' | sort |
			while IFS= read -r f; do
				rel=${f#"$TREE_ROOT"/}
				sz=$(file_size "$f")
				h=$(sha256_of "$f")
				printf '%s\t%s\t%s\t%s\t-\t\trecorded\n' \
					"firmware-part" "$rel" "$sz" "$h"
			done >>"$out"
	fi

	# Minimum firmware declaration needed to interpret the payload.
	minf="$TREE_ROOT/trimui/firmwares/MinFwVersion.txt"
	if [ -f "$minf" ]; then
		sz=$(file_size "$minf")
		h=$(sha256_of "$minf")
		printf '%s\t%s\t%s\t%s\t-\t\trecorded\n' \
			"firmware-declaration" "trimui/firmwares/MinFwVersion.txt" "$sz" "$h" >>"$out"
	fi

	rows=$(wc -l <"$out" | tr -d ' ')
	note "recorded $rows pre-transform inputs in $out"
}

if [ -n "$RECORD_INPUTS" ]; then
	record_inputs "$RECORD_INPUTS"
	exit 0
fi

[ -n "$VERSION" ] || die "--version is required in manifest mode"
if [ -z "$TAG" ]; then TAG="v$VERSION"; fi

# ---------------------------------------------------------------- tree listing

: >"$TMP/files.tsv"

collect_file() {
	f=$1
	rel=${f#"$TREE_ROOT"/}
	if [ "$rel" != "$f" ]; then
		sz=$(file_size "$f")
		h=$(sha256_of "$f")
		printf '%s\t%s\t%s\n' "$h" "$sz" "$rel" >>"$TMP/files.tsv"
	fi
}

if [ "$SURFACE" = image ]; then
	find "$TREE_ROOT" -type f | sort | while IFS= read -r f; do
		case $f in
		"$TREE_ROOT"/.git | "$TREE_ROOT"/.git/*) continue ;;
		esac
		collect_file "$f"
	done
else
	while IFS= read -r inc; do
		[ -n "$inc" ] || continue
		case $inc in
		/*) die "--include must be relative to the tree: $inc" ;;
		../* | */../*) die "--include must stay inside the tree: $inc" ;;
		esac
		p="$TREE_ROOT/$inc"
		[ -e "$p" ] || die "--include path not found: $inc"
		if [ -d "$p" ]; then
			find "$p" -type f | sort | while IFS= read -r f; do collect_file "$f"; done
		else
			collect_file "$p"
		fi
	done <"$TMP/includes.txt"
	sort -u "$TMP/files.tsv" -o "$TMP/files.tsv"
fi

FILE_COUNT=$(wc -l <"$TMP/files.tsv" | tr -d ' ')
[ "$FILE_COUNT" -gt 0 ] || die "no files found under $TREE_ROOT"
LOGICAL_BYTES=$(awk -F'\t' '{s += $2} END {printf "%.0f", s + 0}' "$TMP/files.tsv")
LISTING_SHA=$(sha256_of "$TMP/files.tsv")
HIDDEN_COUNT=$(awk -F'\t' '$3 ~ /(^|\/)\./ {n++} END {print n + 0}' "$TMP/files.tsv")

# ---------------------------------------------------------------- provenance

if [ -z "$COMMIT" ]; then
	if command -v git >/dev/null 2>&1 && git -C "$TREE_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
		COMMIT=$(git -C "$TREE_ROOT" rev-parse HEAD)
	else
		COMMIT=
		printf '%s\n' "commit not provided and not derivable from the tree (no git metadata)" \
			>>"$TMP/warnings.txt"
	fi
fi

PARTIAL_CLONE=no
if command -v git >/dev/null 2>&1; then
	if [ -n "$(git -C "$TREE_ROOT" config --get remote.origin.partialclonefilter 2>/dev/null || true)" ]; then
		PARTIAL_CLONE=yes
	fi
fi

if [ "$MEASURE_GIT" = 1 ] && [ "$PARTIAL_CLONE" = yes ] && [ -z "$GIT_BYTES" ]; then
	printf '%s\n' "git object bytes not measured: partial (blobless) clone has no local blob sizes" \
		>>"$TMP/warnings.txt"
fi

if [ "$MEASURE_GIT" = 1 ] && [ "$PARTIAL_CLONE" = no ] && [ -z "$GIT_BYTES" ] && command -v git >/dev/null 2>&1; then
	_bytes=$(git -C "$TREE_ROOT" ls-tree -r -l HEAD 2>/dev/null |
		awk '{s += $4} END {printf "%.0f", s + 0}') || _bytes=
	case ${_bytes:-} in
	'' | *[!0-9]*) _bytes= ;;
	esac
	if [ -n "$_bytes" ]; then GIT_BYTES=$_bytes; fi
fi

if [ -n "$GIT_BYTES" ]; then
	GIT_BYTES_STATUS=measured
else
	GIT_BYTES_STATUS=unavailable
fi

# A sparse checkout is a subset of the commit: say so instead of implying the tree is complete.
if command -v git >/dev/null 2>&1; then
	if [ -n "$(git -C "$TREE_ROOT" sparse-checkout list 2>/dev/null || true)" ]; then
		printf '%s\n' "sparse checkout: the file list covers the checked-out paths, not the whole commit" \
			>>"$TMP/warnings.txt"
	fi
fi

# ---------------------------------------------------------------- components

# id|label|path prefixes (comma separated)|in-image-payload|note|declared license|declared evidence
# Assignment picks the longest matching prefix, so specific entries win over crossmix-se.
# "declared license" is only used where the repository itself states it (LICENSE/README);
# an empty field means the license must come from evidence found inside the component.
cat >"$TMP/components.table" <<'EOF'
core:mame_libretro|MAME libretro core|RetroArch/.retroarch/cores/mame_libretro.7z|true|Third-party emulator core shipped as a compressed archive.||
core:mame2016_libretro|MAME 2016 libretro core|RetroArch/.retroarch/cores/mame2016_libretro.7z|true|Third-party emulator core shipped as a compressed archive.||
core:mame219_libretro|MAME 0.219 libretro core|RetroArch/.retroarch/cores/mame219_libretro.7z|true|Third-party emulator core shipped as a compressed archive.||
core:mess_libretro|MESS libretro core|RetroArch/.retroarch/cores/mess_libretro.7z|true|Third-party emulator core shipped as a compressed archive.||
core:scummvm_libretro|ScummVM libretro core|RetroArch/.retroarch/cores/scummvm_libretro.7z|true|Third-party emulator core shipped as a compressed archive.||
retroarch|RetroArch frontend, assets and configuration|RetroArch|true|Frontend assets, shaders, overlays and configuration delivered with the image.||
emulators|Per-system emulator payloads|Emus|true|Emulator binaries, launchers and data laid out per system.||
system-runtime|System binaries and runtime libraries|System/bin,System/lib,System/sftpgo,System/share,System/include,System/resources|true|Shared libraries, Python runtime and helper binaries.||
trimui-vendor|TrimUI vendor surface|trimui|true|Stock firmware payload, input daemon and vendor resources.||
bios|Console BIOS/firmware dumps|BIOS|true|Required by emulators; provenance is not recorded in this tree.||
roms|Bundled ROMs|Roms|true|Bundled/sample game data.||
best-packs|"Best" collection metadata|Best|true|Curated lists, launchers and metadata.||
artwork|Themes, icons and artwork|Themes,Icons,Backgrounds,Imgs,Pictures,Data|true|Themes, icon packs, backgrounds and images.||
hotfix-payload|Incremental update payloads|_assets/hotfixes|false|Shell/ZIP hotfixes published through Check Update. Project-authored, covered by the repository LICENSE. |GPL-3.0|LICENSE,README.md
apps|Application launchers and tools|Apps|true|Tools shipped in the SD tree (SystemTools, BootLogo and helpers). Bundled third-party tools keep their own terms.||
root-files|SD-root metadata|autorun.inf,.VolumeIcon.icns|true|Auto-run entry point and volume icon at the SD root.||
release-tooling|Release tooling and packaging inputs|_assets,.github,LICENSE,README.md|false|Removed by the packaging step (host-only): never part of the payload.||
crossmix-se|CrossMix-OS SE project code|System/usr,System/starts,System/updates,System/etc,docs|true|Project-authored scripts, menus and configuration. The LICENSE that grants GPL-3.0 is removed from the payload, so the terms travel only with the repository. |GPL-3.0|LICENSE,README.md
EOF

# Assign every file to the longest matching prefix, then aggregate.
awk -F'\t' -v OFS='\t' -v unfile="$TMP/unassigned.txt" '
	NR == FNR {
		n++
		split($0, a, "|")
		id[n] = a[1]; label[n] = a[2]; paths[n] = a[3]; dist[n] = a[4]
		cnote[n] = a[5]; decl[n] = a[6]; dev[n] = a[7]
		k = split(a[3], arr, ",")
		np[n] = k
		for (i = 1; i <= k; i++) pref[n, i] = arr[i]
		next
	}
	{
		path = $3; best = 0; bestlen = -1
		for (j = 1; j <= n; j++) {
			for (i = 1; i <= np[j]; i++) {
				p = pref[j, i]
				if (p == ".") { m = 1; l = 0 }
				else if (path == p) { m = 1; l = length(p) }
				else if (index(path, p "/") == 1) { m = 1; l = length(p) }
				else m = 0
				if (m && l > bestlen) { bestlen = l; best = j }
			}
		}
		count[best]++
		bytes[best] += $2
	}
	END {
		for (j = 1; j <= n; j++)
			printf "%s\t%s\t%s\t%s\t%d\t%.0f\t%s\t%s\t%s\n", id[j], label[j], paths[j], dist[j],
				count[j] + 0, bytes[j] + 0, cnote[j], decl[j], dev[j]
		unassigned = count[0] + 0
		printf "%d\n", unassigned > unfile
	}' "$TMP/components.table" "$TMP/files.tsv" >"$TMP/components.tsv"

UNASSIGNED=$(cat "$TMP/unassigned.txt" 2>/dev/null || printf '0')
case ${UNASSIGNED:-0} in
'' | *[!0-9]*) UNASSIGNED=0 ;;
esac
if [ "$UNASSIGNED" -gt 0 ]; then
	printf '%s\n' "$UNASSIGNED file(s) matched no component scope: they ship without a license statement" \
		>>"$TMP/warnings.txt"
fi

# License candidates: name looks like a license/notice file and is not a media blob.
awk -F'\t' '{
	n = split($3, parts, "/"); base = tolower(parts[n])
	if (base !~ /(licen|copying|copyright|notice|gpl-license|lgpl-license)/) next
	if (base ~ /\.(ogg|wav|mp3|png|jpg|jpeg|bmp|ico|js|zip|7z|so|bin|dat|ttf|otf|woff2?)$/) next
	print $3
}' "$TMP/files.tsv" | sort -u >"$TMP/license-candidates.txt"

# component_license PREFIXES -> "license<TAB>evidence<TAB>unrecognised"
component_license() {
	prefixes=$1
	printf '%s' "$prefixes" | tr ',' '\n' >"$TMP/pfx.txt"
	awk -F'\t' -v pf="$TMP/pfx.txt" '
		BEGIN { while ((getline line < pf) > 0) { n++; P[n] = line } }
		{
			for (i = 1; i <= n; i++)
				if ($0 == P[i] || index($0, P[i] "/") == 1) { print $0; next }
		}' "$TMP/license-candidates.txt" | sort -u >"$TMP/cand.txt"

	: >"$TMP/ev.tsv"
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		f="$TREE_ROOT/$rel"
		[ -f "$f" ] || continue
		kind=$(classify_license "$f")
		printf '%s\t%s\n' "$rel" "$kind" >>"$TMP/ev.tsv"
	done <"$TMP/cand.txt"

	awk -F'\t' '
		{
			if ($2 != "UNRECOGNISED" && $2 != "UNREADABLE") {
				ev = ev (ev == "" ? "" : "; ") $1 "=" $2
				ids[++k] = $2
			} else {
				other = other (other == "" ? "" : "; ") $1
			}
		}
		END {
			n = 0
			for (i = 1; i <= k; i++) if (!(ids[i] in dup)) { dup[ids[i]] = 1; uniq[++n] = ids[i] }
			if (n == 0) printf "DESCONOCIDA\t\t%s\n", other
			else if (n == 1) printf "%s\t%s\t%s\n", uniq[1], ev, other
			else printf "MIXED\t%s\t%s\n", ev, other
		}' "$TMP/ev.tsv"
}

TAB=$(printf '\t')
: >"$TMP/licenses.tsv"
while IFS="$TAB" read -r cid clabel cpaths cdist ccount cbytes cnote cdecl cdev; do
	lic=$(component_license "$cpaths")
	printf '%s\t%s\n' "$cid" "$lic" >>"$TMP/licenses.tsv"
done <"$TMP/components.tsv"

# ---------------------------------------------------------------- transformations

has_path() {
	if [ -e "$TREE_ROOT/$1" ]; then printf 'yes'; else printf 'no'; fi
}

GITKEEP_COUNT=$(awk -F'\t' '$3 ~ /(^|\/)\.gitkeep$/ {n++} END {print n + 0}' "$TMP/files.tsv")
VERSION_FILE="System/usr/trimui/crossmix-version.txt"
VERSION_STATE=absent
if [ -f "$TREE_ROOT/$VERSION_FILE" ]; then
	_stamp=$(tr -d '\r\n' <"$TREE_ROOT/$VERSION_FILE")
	if [ "$_stamp" = "$VERSION" ]; then
		VERSION_STATE=match
	else
		VERSION_STATE=mismatch
		printf '%s\n' "version stamp ${VERSION_FILE} says '${_stamp}', manifest version is '${VERSION}'" \
			>>"$TMP/warnings.txt"
	fi
fi

CORE_ARCHIVES_PRESENT=$(awk -F'\t' '$3 ~ /^RetroArch\/\.retroarch\/cores\/.*\.7z$/ {n++} END {print n + 0}' "$TMP/files.tsv")
DEFAULT_CFG_PRESENT=$(has_path "RetroArch/default_config.7z")
CORE_INPUTS=$(awk -F'\t' '$1 == "core-archive" {n++} END {print n + 0}' "$TMP/inputs.tsv" 2>/dev/null || printf '0')

# id<TAB>step<TAB>action<TAB>target<TAB>reason<TAB>observed<TAB>detail
: >"$TMP/transforms.tsv"
add_transform() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >>"$TMP/transforms.tsv"
}

if [ "$GITKEEP_COUNT" -eq 0 ]; then
	_gk=applied
	_gkd="no .gitkeep remains in this tree"
else
	_gk=pending
	_gkd="${GITKEEP_COUNT} .gitkeep file(s) still present: this tree is pre-package"
fi
add_transform "delete-gitkeep" "Cleaning image..." "delete" "**/.gitkeep" \
	"Placeholder files keep empty directories in git and are not shipped." "$_gk" "$_gkd"

if [ "$(has_path _assets)" = no ]; then
	add_transform "remove-assets-dir" "Cleaning image..." "delete" "_assets" \
		"Repository screenshots and hotfix sources are not part of the payload." applied \
		"_assets absent"
else
	add_transform "remove-assets-dir" "Cleaning image..." "delete" "_assets" \
		"Repository screenshots and hotfix sources are not part of the payload." pending \
		"_assets present: this tree is pre-package"
fi

if [ "$(has_path LICENSE)" = no ]; then
	add_transform "remove-license-file" "Cleaning image..." "delete" "LICENSE" \
		"Upstream GPL-3.0 text is kept in the repository, not in the SD payload." applied \
		"LICENSE absent"
else
	add_transform "remove-license-file" "Cleaning image..." "delete" "LICENSE" \
		"Upstream GPL-3.0 text is kept in the repository, not in the SD payload." pending \
		"LICENSE present: this tree is pre-package"
fi

if [ "$(has_path README.md)" = no ]; then
	add_transform "remove-readme" "Cleaning image..." "delete" "README.md" \
		"README is repository documentation, not device content." applied "README.md absent"
else
	add_transform "remove-readme" "Cleaning image..." "delete" "README.md" \
		"README is repository documentation, not device content." pending \
		"README.md present: this tree is pre-package"
fi

if [ "$(has_path .git)" = no ] && [ "$(has_path .github)" = no ]; then
	add_transform "remove-vcs-and-workflow" "Cleaning image..." "delete" ".git, .github" \
		"VCS metadata and CI definitions never ship." applied ".git and .github absent"
else
	add_transform "remove-vcs-and-workflow" "Cleaning image..." "delete" ".git, .github" \
		"VCS metadata and CI definitions never ship." pending \
		".git and/or .github still present"
fi

add_transform "stamp-version" "Cleaning image..." "write" "$VERSION_FILE" \
	"The payload must carry the version it was built from." "$VERSION_STATE" \
	"stamp state: $VERSION_STATE (file compared against manifest version)"

if [ "$CORE_ARCHIVES_PRESENT" -eq 0 ] && [ "$CORE_INPUTS" -eq 0 ]; then
	_ca=not-observed
	_cad="no core archive in this tree and no --inputs recording: extraction cannot be asserted"
elif [ "$CORE_ARCHIVES_PRESENT" -eq 0 ]; then
	_ca=applied
	_cad="no core .7z remains; ${CORE_INPUTS} archive(s) recorded as inputs"
else
	_ca=pending
	_cad="${CORE_ARCHIVES_PRESENT} core archive(s) still compressed; extraction happens in the workflow"
fi
add_transform "extract-core-archives" "Extract RetroArch cores" "extract" "RetroArch/.retroarch/cores/*.7z" \
	"Cores ship as compressed archives and are unpacked before packaging so the device does not need 7z." \
	"$_ca" "$_cad"

if [ "$DEFAULT_CFG_PRESENT" = yes ]; then
	add_transform "create-default-config-archive" "Cleaning image..." "create" "RetroArch/default_config.7z" \
		"Bundles retroarch.cfg plus config/* so defaults can be restored on device." applied \
		"archive present in payload"
else
	add_transform "create-default-config-archive" "Cleaning image..." "create" "RetroArch/default_config.7z" \
		"Bundles retroarch.cfg plus config/* so defaults can be restored on device." pending \
		"archive absent: this tree is pre-package"
fi

add_transform "include-hidden-entries" "Packaging release" "include" "**/.*" \
	"Packaging uses dotglob, so hidden files are part of the published archive." applied \
	"${HIDDEN_COUNT} hidden file(s) inside the manifest scope"

ARTIFACT_COUNT=$(wc -l <"$TMP/artifacts.txt" | tr -d ' ')
if [ "$ARTIFACT_COUNT" -gt 0 ]; then
	if [ "$ARTIFACT_COUNT" -gt 1 ]; then
		add_transform "package-7z" "Packaging release" "create" "CrossMix-OS_v*-image.7z" \
			"7z -mx=7 over the payload root; split into volumes above the 2 GiB asset limit." applied \
			"${ARTIFACT_COUNT} volume(s) hashed"
	else
		add_transform "package-7z" "Packaging release" "create" "CrossMix-OS_v*.7z" \
			"7z -mx=7 over the payload root; split into volumes above the 2 GiB asset limit." applied \
			"1 archive hashed"
	fi
else
	add_transform "package-7z" "Packaging release" "create" "CrossMix-OS_v*.7z" \
		"7z -mx=7 over the payload root; split into volumes above the 2 GiB asset limit." pending \
		"no --artifact given: artifact bytes not measured"
fi

if [ -f "$TREE_ROOT/trimui/firmwares/MinFwVersion.txt" ]; then
	_req_v=$(sed -n '1p' "$TREE_ROOT/trimui/firmwares/MinFwVersion.txt" | tr -d '\r')
	_req_r=$(sed -n '2p' "$TREE_ROOT/trimui/firmwares/MinFwVersion.txt" | tr -d '\r')
	_fw="declares ${_req_v}/${_req_r}"
else
	_fw="MinFwVersion.txt not present in this tree"
fi
if [ -f "$TREE_ROOT/trimui/firmwares/MinFwVersion.txt" ]; then
	_fw_state=applied
else
	_fw_state=not-evaluated
fi
add_transform "validate-firmware-payload" "Validate firmware payload consistency" "validate" \
	"trimui/firmwares/firmware_tsp_v*.7z.00N" \
	"The declared minimum firmware must have its payload present, or flashing fails on device." \
	"$_fw_state" "$_fw"

# ---------------------------------------------------------------- artifacts

: >"$TMP/artifacts.tsv"
while IFS= read -r a; do
	[ -n "$a" ] || continue
	[ -f "$a" ] || die "--artifact not found: $a"
	sz=$(file_size "$a")
	h=$(sha256_of "$a")
	printf '%s\t%s\t%s\n' "$(basename "$a")" "$sz" "$h" >>"$TMP/artifacts.tsv"
done <"$TMP/artifacts.txt"

if [ "$ARTIFACT_COUNT" -gt 0 ]; then
	ARTIFACT_BYTES=$(awk -F'\t' '{s += $2} END {printf "%.0f", s + 0}' "$TMP/artifacts.tsv")
else
	ARTIFACT_BYTES=null
fi

# ---------------------------------------------------------------- tree state

# Tree state is derived from markers that can only exist after packaging: a matching version
# stamp, the generated default_config.7z, and the absence of the compressed core archives.
# Removals alone are ambiguous (a tree may simply never have carried the file), so they only
# inform the per-transform "observed" field.
if [ "$CORE_ARCHIVES_PRESENT" -gt 0 ]; then
	TREE_STATE=pre-transform
elif [ "$VERSION_STATE" = match ] && [ "$DEFAULT_CFG_PRESENT" = yes ]; then
	TREE_STATE=post-transform
else
	TREE_STATE=mixed
fi

GENERATOR_SHA=$(sha256_of "$0")

# ---------------------------------------------------------------- emit JSON

emit() {
	printf '%s\n' "$1"
}

{
	emit '{'
	emit "  \"schema\": \"$SCHEMA\","
	emit "  \"surface\": \"$SURFACE\","
	emit '  "release": {'
	emit "    \"version\": \"$(json_escape "$VERSION")\","
	emit "    \"tag\": \"$(json_escape "$TAG")\","
	emit "    \"commit\": $(if [ -n "$COMMIT" ]; then printf '"%s"' "$(json_escape "$COMMIT")"; else printf 'null'; fi),"
	emit "    \"generated_at\": \"$GENERATED_AT\","
	emit "    \"timestamp_pinned\": $TIMESTAMP_PINNED,"
	emit "    \"generator\": \"scripts/$PROG\","
	emit "    \"generator_sha256\": \"$GENERATOR_SHA\","
	emit '    "selection": ['
	if [ "$INC_COUNT" -gt 0 ]; then
		awk '{printf "%s    \"%s\"", (NR > 1 ? ",\n" : ""), $0} END {print ""}' "$TMP/includes.txt"
		printf '%s\n' '    ]'
	else
		printf '%s\n' '    ]'
	fi
	emit '  },'
	emit '  "pipeline": {'
	emit "    \"repository\": $(if [ -n "$REPOSITORY" ]; then printf '"%s"' "$(json_escape "$REPOSITORY")"; else printf 'null'; fi),"
	emit "    \"workflow\": $(if [ -n "$WF_PATH" ]; then printf '"%s"' "$(json_escape "$WF_PATH")"; else printf 'null'; fi),"
	emit "    \"workflow_sha256\": $(if [ -n "$WF_SHA" ]; then printf '"%s"' "$(json_escape "$WF_SHA")"; else printf 'null'; fi),"
	emit "    \"ref\": $(if [ -n "$WF_REF" ]; then printf '"%s"' "$(json_escape "$WF_REF")"; else printf 'null'; fi),"
	emit "    \"run_id\": $(if [ -n "$RUN_ID" ]; then printf '"%s"' "$(json_escape "$RUN_ID")"; else printf 'null'; fi),"
	emit "    \"run_url\": $(if [ -n "$RUN_URL" ]; then printf '"%s"' "$(json_escape "$RUN_URL")"; else printf 'null'; fi)"
	emit '  },'
	emit '  "tree": {'
	emit "    \"state\": \"$TREE_STATE\","
	emit "    \"hidden_file_count\": $HIDDEN_COUNT,"
	emit "    \"listing_sha256\": \"$LISTING_SHA\""
	emit '  },'
	emit '  "totals": {'
	emit "    \"file_count\": $FILE_COUNT,"
	emit "    \"logical_bytes\": $LOGICAL_BYTES,"
	emit "    \"artifact_bytes\": $ARTIFACT_BYTES,"
	emit "    \"artifact_count\": $ARTIFACT_COUNT,"
	emit "    \"git_object_bytes\": $(if [ -n "$GIT_BYTES" ]; then printf '%s' "$GIT_BYTES"; else printf 'null'; fi),"
	emit "    \"git_object_bytes_status\": \"$GIT_BYTES_STATUS\""
	emit '  },'
	emit '  "files": ['
	awk -F'\t' "$AWK_JSON_LIB"'
		{ printf "%s    {\"path\": \"%s\", \"size\": %s, \"sha256\": \"%s\"}", (NR > 1 ? ",\n" : ""), jesc($3), $2, $1 }
		END { printf "\n" }' "$TMP/files.tsv"
	emit '  ],'
	emit '  "transformations": ['
	awk -F'\t' "$AWK_JSON_LIB"'
		{ printf "%s    {\"id\": \"%s\", \"step\": \"%s\", \"action\": \"%s\", \"target\": \"%s\", \"reason\": \"%s\", \"observed\": \"%s\", \"detail\": \"%s\"}", (NR > 1 ? ",\n" : ""), jesc($1), jesc($2), jesc($3), jesc($4), jesc($5), jesc($6), jesc($7) }
		END { printf "\n" }' "$TMP/transforms.tsv"
	emit '  ],'
	emit '  "inputs": ['
	if [ -s "$TMP/inputs.tsv" ]; then
		awk -F'\t' "$AWK_JSON_LIB"'
			{
				printf "%s    {\"kind\": \"%s\", \"path\": \"%s\", \"size\": %s, \"sha256\": \"%s\", \"members\": ", (NR > 1 ? ",\n" : ""), jesc($1), jesc($2), $3, jesc($4)
				if ($5 == "-" || $5 == "") printf "null"; else printf "%s", $5
				printf ", \"uncompressed_bytes\": "
				if ($6 == "-" || $6 == "") printf "null"; else printf "%s", $6
				printf "}"
			}
			END { printf "\n" }' "$TMP/inputs.tsv"
	else
		emit ''
	fi
	emit '  ],'
	emit '  "components": ['
	awk -F'\t' -v surface="$SURFACE" "$AWK_JSON_LIB"'
		FILENAME == ARGV[1] {
			lic[$1] = $2; evid[$1] = $3
			next
		}
		{
			if ($5 + 0 == 0) next
			id = $1
			declared = $8
			dev = $9
			if (declared != "") {
				final = declared
				evidence = dev
				source = "declared"
				sep = ","
			} else {
				final = (lic[id] == "" ? "DESCONOCIDA" : lic[id])
				evidence = evid[id]
				source = "tree-evidence"
				sep = "; "
			}
			k++
			printf "%s    {\"id\": \"%s\", \"label\": \"%s\", \"scope\": [", (k > 1 ? ",\n" : ""), jesc(id), jesc($2)
			n = split($3, arr, ",")
			for (i = 1; i <= n; i++) printf "%s\"%s\"", (i > 1 ? ", " : ""), jesc(arr[i])
			printf "], \"distributed\": %s, \"in_image_payload\": %s, \"file_count\": %s, \"logical_bytes\": %s, \"license\": \"%s\", \"license_source\": \"%s\", \"license_evidence\": [", (surface == "image" ? $4 : "true"), $4, $5, $6, jesc(final), source
			m = split(evidence, e, sep)
			cnt = 0
			for (i = 1; i <= m; i++) {
				if (e[i] == "") continue
				printf "%s\"%s\"", (cnt++ ? ", " : ""), jesc(e[i])
			}
			printf "], \"license_note\": \"%s\"}", jesc($7)
		}
		END { printf "\n" }' "$TMP/licenses.tsv" "$TMP/components.tsv"
	emit '  ],'
	emit '  "artifacts": ['
	awk -F'\t' "$AWK_JSON_LIB"'
		{ printf "%s    {\"name\": \"%s\", \"bytes\": %s, \"sha256\": \"%s\", \"compression\": \"7z -mx=7\"}", (NR > 1 ? ",\n" : ""), jesc($1), $2, $3 }
		END { printf "\n" }' "$TMP/artifacts.tsv"
	emit '  ],'
	emit '  "warnings": ['
	awk "$AWK_JSON_LIB"' { printf "%s    \"%s\"", (NR > 1 ? ",\n" : ""), jesc($0) } END { printf "\n" }' "$TMP/warnings.txt"
	emit '  ],'
	emit '  "notes": ['
	if [ -s "$TMP/notes.txt" ]; then
		awk "$AWK_JSON_LIB"' { printf "%s    \"%s\"", (NR > 1 ? ",\n" : ""), jesc($0) } END { printf "\n" }' "$TMP/notes.txt"
	else
		emit ''
	fi
	emit '  ]'
	emit '}'
} >"${OUTPUT:-/dev/stdout}"

if [ -n "$OUTPUT" ]; then
	note "wrote $OUTPUT ($FILE_COUNT files, $LOGICAL_BYTES bytes)"
fi

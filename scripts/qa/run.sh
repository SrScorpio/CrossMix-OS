#!/bin/sh
# scripts/qa/run.sh - reproducible smoke harness for CrossMix-OS SE.
#
# Runs on the workstation (Linux/macOS), NOT on the console. Nothing here writes
# to /mnt/SDCARD: every case works on a throw-away tree under $TMPDIR, and the
# device paths are injected through the environment variables the scripts
# already expose (favorites_guard.sh) or read from the repo itself.
#
# Scope is deliberately narrow. This harness is a regression net for the failure
# modes that are cheap to reproduce off-device; it cannot prove that a console
# boots, that a 7zz extraction fits in the 32-bit address space, or that a
# firmware flash works. docs/QA-COVERAGE.md states what each area actually
# relies on, including the parts only hardware can cover.
#
# Usage:
#   sh scripts/qa/run.sh            # run every case
#   sh scripts/qa/run.sh --list     # list case ids
#   sh scripts/qa/run.sh --strict   # documented defects fail the run too
#
# Exit status: 0 every check passed (known defects reported, not fatal),
# 1 a check failed, 2 usage/tool problem.

set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
COMMON="$ROOT/System/usr/trimui/scripts/update_common.sh"
GUARD="$ROOT/System/usr/trimui/scripts/favorites_guard.sh"
ZIP="$ROOT/_assets/hotfixes/CrossMix-OS_v1.4.0-ce.2.zip"
ZIP_BUILDER="$ROOT/_assets/scripts/build-hotfix-zip.sh"
MANIFEST_TEST="$ROOT/.github/scripts/tests/release-manifest-test.sh"

# Defects confirmed in the tree; tracked in docs/QA-COVERAGE.md section 6.
# They stay visible on every run. --strict turns them into hard failures so a
# release gate cannot quietly ship on top of them.
KNOWN_DEFECTS=""

PASS=0
FAIL=0
SKIP=0
KNOWN=0
FAILED_IDS=""
MODE="default"

for arg in "$@"; do
	case "$arg" in
	--list)
		cat <<'EOF'
shell-syntax                    busybox sh -n over every tracked *.sh
sh-lint-if-test-flag            detect the `if -f ...` typo (test builtin used as a command)
version-compare                 cmp_crossmix_versions ordering and rejection table
favorites-guard-healthy         valid NDJSON + existing launcher: file left untouched
favorites-guard-corrupt         unparsable line dropped, backup written, rest kept
favorites-guard-missing-launch  entry pointing at a missing .launch is dropped
favorites-guard-absent          no favourite2.json: no writes, exit 0
favorites-guard-no-jq           jq unusable: file left untouched, exit 0
hotfix-zip-vs-tree              committed hotfix zip members match the working tree
hotfix-zip-coverage             every file listed by build-hotfix-zip.sh is in the zip
release-asset-selection         GitHub release assets: exactly one image candidate
release-manifest-fixture        runs .github/scripts/tests/release-manifest-test.sh
EOF
		exit 0
		;;
	--strict) MODE="strict" ;;
	*)
		printf 'unknown option: %s (try --list)\n' "$arg" >&2
		exit 2
		;;
	esac
done

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t qa-run) || {
	printf 'cannot create a work directory\n' >&2
	exit 2
}
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap 'cleanup; exit 130' INT TERM HUP
trap cleanup EXIT

# Prefer busybox ash: it is what the console runs and it rejects constructs that
# dash/GNU sh accept. Fall back to /bin/sh with a warning.
if command -v busybox >/dev/null 2>&1; then
	SH=$(command -v busybox)
	SH_KIND="busybox ash"
elif [ -x "$ROOT/System/usr/trimui/scripts/busybox" ]; then
	# The repo copy is aarch64; only usable when running on the device itself.
	SH="$ROOT/System/usr/trimui/scripts/busybox"
	SH_KIND="repo busybox"
else
	SH=$(command -v sh || echo /bin/sh)
	SH_KIND="POSIX sh (ash NOT checked)"
	printf 'WARN  busybox not found: parse checks use %s, not ash\n' "$SH" >&2
fi

case "$SH_KIND" in
busybox\ ash|repo\ busybox) sh_parse() { "$SH" sh -n "$1"; } ;;
*) sh_parse() { "$SH" -n "$1"; } ;;
esac

sh_run() { # sh_run <script> [args...]
	_s=$1
	shift
	case "$SH_KIND" in
	busybox\ ash|repo\ busybox) "$SH" sh "$_s" "$@" ;;
	*) "$SH" "$_s" "$@" ;;
	esac
}

pass() { PASS=$((PASS + 1)); printf 'ok    %-30s %s\n' "$1" "${2:-}"; }
fail() {
	FAIL=$((FAIL + 1))
	FAILED_IDS="$FAILED_IDS $1"
	printf 'FAIL  %-30s %s\n' "$1" "${2:-}"
}
skip() { SKIP=$((SKIP + 1)); printf 'skip  %-30s %s\n' "$1" "${2:-}"; }

short() { # keep failure messages one line and bounded
	printf '%s' "$1" | tr '\n' ' ' | cut -c1-160
}

# One file list for the whole run: git knows about scripts a sparse worktree has
# not materialised. core.quotepath=false keeps non-ASCII names (°customization.sh)
# printable instead of C-escaped.
QA_FILES=$(cd "$ROOT" && git -c core.quotepath=false ls-files '*.sh' 2>/dev/null)

# ---------------------------------------------------------------- shell syntax

case_shell_syntax() {
	if [ -z "$QA_FILES" ]; then
		skip shell-syntax "git ls-files returned nothing (not a git checkout?)"
		return
	fi
	total=0
	missing=0
	bad=""
	for f in $QA_FILES; do
		if [ ! -f "$ROOT/$f" ]; then
			missing=$((missing + 1))
			continue
		fi
		total=$((total + 1))
		sh_parse "$ROOT/$f" >"$WORK/syntax.err" 2>&1 || bad="$bad $f"
	done
	if [ -n "$bad" ]; then
		fail shell-syntax "parse errors:$bad"
	elif [ "$missing" -gt 0 ]; then
		# Sparse worktrees legitimately miss paths: say so instead of pretending.
		pass shell-syntax "$total parsed, $missing not materialised (sparse checkout)"
	else
		pass shell-syntax "$total scripts parse under $SH_KIND"
	fi
}

case_sh_lint_if_test_flag() {
	# `if -f path` runs a command named "-f" (exit 127), so the branch is
	# silently skipped at runtime and `sh -n` still passes. Always a bug.
	# grep per file: busybox grep has no --include, and this harness itself runs
	# under busybox ash.
	hits=""
	for f in $QA_FILES; do
		[ -f "$ROOT/$f" ] || continue
		found=$(grep -nE '(^|[;&|]|then|else|do)[[:space:]]*if[[:space:]]+-[a-zA-Z]+[[:space:]]' "$ROOT/$f" 2>/dev/null |
			sed "s#^\([0-9]*\):.*#${f}:\1#")
		[ -n "$found" ] && hits="$hits $found"
	done
	if [ -z "$hits" ]; then
		pass sh-lint-if-test-flag "no test-builtin-as-command"
	else
		fail sh-lint-if-test-flag "test builtin used as a command at:$hits"
	fi
}

# ------------------------------------------------------------ version compare

case_version_compare() {
	cat >"$WORK/vcmp.sh" <<'EOF'
COMMON=$1
shift
# $1 is now a version row, never "-v", so update_common.sh does not take its
# version-print branch; the cat of the device version file is silenced.
. "$COMMON" 2>/dev/null
rc_all=0
rows=0
while [ $# -ge 3 ]; do
	local_v=$1
	remote_v=$2
	want=$3
	shift 3
	rows=$((rows + 1))
	got=$(cmp_crossmix_versions "$local_v" "$remote_v")
	rc=$?
	if [ "$want" = "<invalid>" ]; then
		if [ "$rc" -eq 0 ] || [ -n "$got" ]; then
			printf 'BAD %s vs %s expected invalid, got rc=%s out=%s\n' "$local_v" "$remote_v" "$rc" "$got"
			rc_all=1
		fi
	elif [ "$rc" -ne 0 ] || [ "$got" != "$want" ]; then
		printf 'BAD %s vs %s expected %s, got rc=%s out=%s\n' "$local_v" "$remote_v" "$want" "$rc" "$got"
		rc_all=1
	fi
done
[ "$rows" -gt 0 ] || { echo "BAD no rows"; rc_all=1; }
exit $rc_all
EOF
	out=$(sh_run "$WORK/vcmp.sh" "$COMMON" \
		1.4.0 1.4.0 0 \
		1.4.0 1.4.0-ce.1 -1 \
		1.4.0-ce.1 1.4.0-ce.2.9 -1 \
		1.4.0-ce.2.9 1.4.0-ce.2.10 -1 \
		1.4.0-ce.2 1.4.0-ce.2.16 -1 \
		1.4.0 1.4.1 -1 \
		1.4.0-dev 1.4.0 -1 \
		1.4.0.1 1.4.0 1 \
		1.4.10 1.4.9 1 \
		2.0.0 1.9.99 1 \
		1.4.0 "" "<invalid>" \
		1.4.0 1.4 "<invalid>" \
		1.4.0 1.4.0- "<invalid>" \
		1.4.0 1.4.0-ce "<invalid>" \
		1.4.0 1.4.0-ce.x "<invalid>" \
		1.4.0 1.4.1000 "<invalid>" \
		1.4.0 1.4.0-ce.2.3.4 "<invalid>" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		pass version-compare "17 rows (ordering + rejects)"
	else
		fail version-compare "$(short "$out")"
	fi
}

# ----------------------------------------------------------- favorites guard

guard_sandbox() {
	_sd=$1
	mkdir -p "$_sd/Roms" "$_sd/Apps/SystemTools/Logs" "$_sd/System/backups"
	mkdir -p "$_sd/Emus/NES" "$_sd/Emus/SNES"
	printf '#!/bin/sh\n' >"$_sd/Emus/NES/fceumm.launch"
	printf '#!/bin/sh\n' >"$_sd/Emus/SNES/snes9x.launch"
}

# run_guard <sd> [jq-path] - run the real guard with the device paths redirected.
run_guard() {
	(
		SDCARD="$1"
		FAVORITES_ROMS_DIR="$1/Roms"
		FAVORITES_BACKUP_DIR="$1/System/backups"
		FAVORITES_LOG_FILE="$1/Apps/SystemTools/Logs/favorites_guard.log"
		export SDCARD FAVORITES_ROMS_DIR FAVORITES_BACKUP_DIR FAVORITES_LOG_FILE
		if [ -n "${2:-}" ]; then
			JQ="$2"
			export JQ
		fi
		sh_run "$GUARD"
	)
}

case_favorites_guard_healthy() {
	sd="$WORK/guard-healthy"
	guard_sandbox "$sd"
	cat >"$sd/Roms/favourite2.json" <<EOF
{"label":"Mario","launch":"Emus/NES/fceumm.launch","rompath":"Roms/NES/mario.nes"}
{"label":"Zelda","launch":"$sd/Emus/SNES/snes9x.launch","rompath":"Roms/SNES/zelda.sfc"}
EOF
	sum_before=$(sha256sum "$sd/Roms/favourite2.json" | cut -d' ' -f1)
	out=$(run_guard "$sd" 2>&1)
	rc=$?
	sum_after=$(sha256sum "$sd/Roms/favourite2.json" | cut -d' ' -f1)
	backups=$(ls -1 "$sd/System/backups" 2>/dev/null | wc -l | tr -d ' ')
	if [ "$rc" -eq 0 ] && [ "$sum_before" = "$sum_after" ] && [ "$backups" = "0" ]; then
		pass favorites-guard-healthy "exit 0, bytes unchanged, no backup"
	else
		fail favorites-guard-healthy "rc=$rc changed=$([ "$sum_before" = "$sum_after" ] && echo no || echo yes) backups=$backups"
	fi
}

case_favorites_guard_corrupt() {
	sd="$WORK/guard-corrupt"
	guard_sandbox "$sd"
	{
		printf '{"label":"Good","launch":"Emus/NES/fceumm.launch"}\n'
		printf '{"label":"Broken","launch":\n'
	} >"$sd/Roms/favourite2.json"
	out=$(run_guard "$sd" 2>&1)
	rc=$?
	lines=$(grep -c . "$sd/Roms/favourite2.json")
	kept=$(grep -c '"Good"' "$sd/Roms/favourite2.json")
	backup=$(ls -1 "$sd/System/backups"/favourite2.bad-*.json 2>/dev/null | head -n 1)
	if [ "$rc" -eq 0 ] && [ "$lines" = "1" ] && [ "$kept" = "1" ] && [ -n "$backup" ]; then
		pass favorites-guard-corrupt "1 line kept, original backed up"
	else
		fail favorites-guard-corrupt "rc=$rc lines=$lines kept=$kept backup=${backup:-none}"
	fi
}

case_favorites_guard_missing_launch() {
	sd="$WORK/guard-missing"
	guard_sandbox "$sd"
	{
		printf '{"label":"Alive","launch":"Emus/NES/fceumm.launch"}\n'
		printf '{"label":"Gone","launch":"Emus/GBA/mgba.launch"}\n'
	} >"$sd/Roms/favourite2.json"
	run_guard "$sd" >/dev/null 2>&1
	rc=$?
	alive=$(grep -c '"Alive"' "$sd/Roms/favourite2.json")
	gone=$(grep -c '"Gone"' "$sd/Roms/favourite2.json")
	if [ "$rc" -eq 0 ] && [ "$alive" = "1" ] && [ "$gone" = "0" ]; then
		pass favorites-guard-missing-launch "dead launcher entry dropped"
	else
		fail favorites-guard-missing-launch "rc=$rc alive=$alive gone=$gone"
	fi
}

case_favorites_guard_absent() {
	sd="$WORK/guard-absent"
	guard_sandbox "$sd"
	run_guard "$sd" >/dev/null 2>&1
	rc=$?
	backups=$(ls -1 "$sd/System/backups" 2>/dev/null | wc -l | tr -d ' ')
	favs=$(ls -1 "$sd/Roms"/favourite2.json* 2>/dev/null | wc -l | tr -d ' ')
	if [ "$rc" -eq 0 ] && [ "$backups" = "0" ] && [ "$favs" = "0" ]; then
		pass favorites-guard-absent "no-op on a card without favourites"
	else
		fail favorites-guard-absent "rc=$rc backups=$backups files=$favs"
	fi
}

case_favorites_guard_no_jq() {
	sd="$WORK/guard-nojq"
	guard_sandbox "$sd"
	# Deliberately broken list: with a working jq the guard WOULD repair it, so
	# "file untouched" is only meaningful for the unusable-jq path.
	{
		printf '{"label":"Good","launch":"Emus/NES/fceumm.launch"}\n'
		printf '{"label":"Broken","launch":\n'
	} >"$sd/Roms/favourite2.json"
	sum_before=$(sha256sum "$sd/Roms/favourite2.json" | cut -d' ' -f1)
	run_guard "$sd" /bin/false >/dev/null 2>&1
	rc=$?
	sum_after=$(sha256sum "$sd/Roms/favourite2.json" | cut -d' ' -f1)
	backups=$(ls -1 "$sd/System/backups" 2>/dev/null | wc -l | tr -d ' ')
	logged=$(grep -c 'jq unusable' "$sd/Apps/SystemTools/Logs/favorites_guard.log" 2>/dev/null || echo 0)
	if [ "$rc" -eq 0 ] && [ "$sum_before" = "$sum_after" ] && [ "$backups" = "0" ] && [ "$logged" -ge 1 ]; then
		pass favorites-guard-no-jq "unusable jq: no repair, no backup, logged"
	else
		fail favorites-guard-no-jq "rc=$rc changed=$([ "$sum_before" = "$sum_after" ] && echo no || echo yes) backups=$backups logged=$logged"
	fi
}

# ------------------------------------------------------- release discovery

case_release_asset_selection() {
	REL="$ROOT/System/usr/trimui/scripts/update_ota_release.sh"
	[ -f "$REL" ] || { skip release-asset-selection "script not present"; return; }
	command -v jq >/dev/null 2>&1 || { skip release-asset-selection "jq not available"; return; }
	# Take the selector filter straight from the script so the case follows the
	# code instead of duplicating it. The selector is a multi-line jq program
	# inside `jq -c '...'`, so it is extracted by range, not by line regex.
	filter=$(sed -n "/Release_asset=.*jq -c '/,/^[[:space:]]*| \.\[0\] \/\/ empty')/p" "$REL" \
		| sed "1s/.*jq -c '//" | sed "s/')$//")
	[ -n "$filter" ] || { skip release-asset-selection "cannot read the asset filter"; return; }
	# A release carries the image, the image manifest and the hotfix manifest;
	# all three contain "CrossMix-OS_v" in their names.
	cat >"$WORK/release.json" <<'EOF'
{"tag_name":"v1.4.0-ce.2","assets":[
 {"name":"CrossMix-OS_v1.4.0-ce.2.manifest.json","browser_download_url":"https://example/m.json","size":51234},
 {"name":"CrossMix-OS_v1.4.0-ce.2.hotfix-manifest.json","browser_download_url":"https://example/h.json","size":4096},
 {"name":"CrossMix-OS_v1.4.0-ce.2.7z","browser_download_url":"https://example/i.7z","size":2100000000},
 {"name":"trimui_tg5040_firmware.7z.001","browser_download_url":"https://example/fw.001","size":1024}]}
EOF
	names=$(jq -r "$filter | .name // empty" "$WORK/release.json" 2>/dev/null)
	count=$(printf '%s\n' "$names" | sed '/^$/d' | wc -l | tr -d ' ')
	# Exactly one candidate, and it must be the downloadable image.
	if [ "$count" = "1" ] && printf '%s\n' "$names" | grep -Eq '\.(7z|zip)$'; then
		pass release-asset-selection "1 candidate: $(printf '%s' "$names")"
	else
		fail release-asset-selection "$count candidates match (want 1 image): $(short "$(printf '%s' "$names" | tr '\n' ' ')")"
	fi
}

# -------------------------------------------------------------- hotfix payload

case_hotfix_zip_vs_tree() {
	[ -f "$ZIP" ] || { skip hotfix-zip-vs-tree "no committed hotfix zip"; return; }
	command -v python3 >/dev/null 2>&1 || { skip hotfix-zip-vs-tree "python3 not available"; return; }
	# busybox `unzip` has no -Z, so the archive is read with zipfile: members and
	# digests are compared against the working tree in one pass.
	out=$(python3 - "$ZIP" "$ROOT" <<'PY' 2>&1
import hashlib, os, sys, zipfile
zpath, root = sys.argv[1], sys.argv[2]
bad, n = [], 0
with zipfile.ZipFile(zpath) as z:
    for info in z.infolist():
        if info.is_dir():
            continue
        n += 1
        disk = os.path.join(root, info.filename)
        if not os.path.isfile(disk):
            bad.append("absent:" + info.filename)
            continue
        if hashlib.sha256(z.read(info)).digest() != hashlib.sha256(open(disk, "rb").read()).digest():
            bad.append("stale:" + info.filename)
print("COUNT=%d" % n)
for b in bad:
    print(b)
PY
)
	rc=$?
	count=$(printf '%s\n' "$out" | sed -n 's/^COUNT=//p')
	problems=$(printf '%s\n' "$out" | sed '/^COUNT=/d' | sed '/^$/d')
	if [ "$rc" -eq 0 ] && [ -z "$problems" ] && [ -n "$count" ]; then
		pass hotfix-zip-vs-tree "$count members match the tree byte for byte"
	else
		fail hotfix-zip-vs-tree "$(short "${problems:-$out}")"
	fi
}

case_hotfix_zip_coverage() {
	[ -f "$ZIP" ] || { skip hotfix-zip-coverage "no committed hotfix zip"; return; }
	[ -f "$ZIP_BUILDER" ] || { skip hotfix-zip-coverage "no build-hotfix-zip.sh"; return; }
	command -v python3 >/dev/null 2>&1 || { skip hotfix-zip-coverage "python3 not available"; return; }
	want=$(sed -n '/^FILES="/,/^"$/p' "$ZIP_BUILDER" | sed '1d;$d')
	[ -n "$want" ] || { skip hotfix-zip-coverage "cannot read the FILES list"; return; }
	missing=""
	count=0
	have=$(python3 -c 'import sys,zipfile; print("\n".join(n for n in zipfile.ZipFile(sys.argv[1]).namelist() if not n.endswith("/")))' "$ZIP" 2>/dev/null)
	# Paths contain spaces ("Firmware Update.sh"): read line by line, not with
	# word splitting. The redirect (not a pipe) keeps the counters in this shell.
	printf '%s\n' "$want" >"$WORK/wanted"
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		count=$((count + 1))
		printf '%s\n' "$have" | grep -Fxq "$rel" || missing="$missing \"$rel\""
	done <"$WORK/wanted"
	if [ -z "$missing" ]; then
		pass hotfix-zip-coverage "$count listed files present"
	else
		fail hotfix-zip-coverage "zip lacks:$missing"
	fi
}

# ------------------------------------------------------------ manifest fixture

case_release_manifest_fixture() {
	[ -f "$MANIFEST_TEST" ] || { skip release-manifest-fixture "test not present"; return; }
	for tool in jq sha256sum; do
		command -v "$tool" >/dev/null 2>&1 || {
			skip release-manifest-fixture "$tool not available"
			return
		}
	done
	if out=$(sh_run "$MANIFEST_TEST" 2>&1); then
		checks=$(printf '%s\n' "$out" | grep -c '^ok ')
		pass release-manifest-fixture "$checks assertions"
	else
		fail release-manifest-fixture "$(short "$(printf '%s\n' "$out" | grep '^FAIL')")"
	fi
}

# ----------------------------------------------------------------------- main

printf 'crossmix-qa  root=%s\n            shell=%s (%s)\n\n' "$ROOT" "$SH" "$SH_KIND"

case_shell_syntax
case_sh_lint_if_test_flag
case_version_compare
case_favorites_guard_healthy
case_favorites_guard_corrupt
case_favorites_guard_missing_launch
case_favorites_guard_absent
case_favorites_guard_no_jq
case_release_asset_selection
case_hotfix_zip_vs_tree
case_hotfix_zip_coverage
case_release_manifest_fixture

# Reclassify documented defects: the summary must distinguish "the net caught
# something new" from "known, tracked, still not fixed".
if [ -n "$FAILED_IDS" ] && [ -n "$KNOWN_DEFECTS" ]; then
	for id in $KNOWN_DEFECTS; do
		case " $FAILED_IDS " in
		*" $id "*)
			[ "$MODE" = "strict" ] && continue
			printf 'KNOWN %-30s documented in docs/QA-COVERAGE.md (not coverage)\n' "$id"
			KNOWN=$((KNOWN + 1))
			FAIL=$((FAIL - 1))
			remaining=""
			for f in $FAILED_IDS; do
				[ "$f" = "$id" ] || remaining="$remaining $f"
			done
			FAILED_IDS=$remaining
			;;
		esac
	done
fi

printf '\n%d passed, %d failed, %d skipped, %d known defects\n' "$PASS" "$FAIL" "$SKIP" "$KNOWN"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

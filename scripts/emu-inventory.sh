#!/bin/sh
# emu-inventory.sh - reproducible, read-only inventory of CrossMix-OS SE emulators.
#
# Emits TSV describing, for every entry under Emus/ and every core artifact under
# RetroArch/.retroarch/cores, what binary is actually invoked and which version and
# licence are *declared inside the repository*. Nothing is executed, downloaded or
# modified: only config.json, *.sh, *.info files are read.
#
# A version or licence that is not literally written in an .info / config.json /
# LICENSE file is reported as UNKNOWN. A version-shaped token in a directory or
# binary name is NEVER used as evidence (see docs/emulators-matrix.md).
#
# Usage:
#   scripts/emu-inventory.sh [-r ROOT] [-t emus|cores|summary]
#     -r ROOT   repository root (default: parent of this script's directory)
#     -t WHAT   table to print on stdout (default: emus)
#
# Exit codes: 0 ok, 2 bad usage / root not found.

set -u

PROG=$(basename "$0")
ROOT=""
WHAT="emus"

usage() {
    cat <<EOF
Usage: $PROG [-r ROOT] [-t emus|cores|summary]

  -r ROOT   repository root (default: parent directory of this script)
  -t WHAT   emus (default) | cores | summary
EOF
}

while getopts "r:t:h" opt 2>/dev/null; do
    case "$opt" in
        r) ROOT=$OPTARG ;;
        t) WHAT=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [ -z "$ROOT" ]; then
    ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)
fi
[ -n "$ROOT" ] && [ -d "$ROOT/Emus" ] || { echo "$PROG: no Emus/ under '${ROOT:-?}'" >&2; exit 2; }
ROOT=$(CDPATH= cd -- "$ROOT" && pwd)

EMUS="$ROOT/Emus"
CORES="$ROOT/RetroArch/.retroarch/cores"

# ---------------------------------------------------------------- helpers ----

# Repository-relative form of a path that may be absolute (SD-card layout).
relpath() {
    case "$1" in
        /mnt/SDCARD/*) printf '%s' "${1#/mnt/SDCARD/}" ;;
        /*)            printf '%s' "$1" ;;
        *)             printf '%s' "$1" ;;
    esac
}

# True when PATH is a regular file on disk or a blob in the committed tree.
# Directories in HEAD are excluded so "Apps/Scraper" cannot look like a binary.
is_blob() {
    [ -f "$ROOT/$1" ] && return 0
    [ -d "$ROOT/$1" ] && return 1
    if [ "$GIT_OK" = "yes" ]; then
        [ "$(git -C "$ROOT" cat-file -t "HEAD:$1" 2>/dev/null)" = "blob" ] && return 0
    fi
    return 1
}

# Does PATH exist in the committed tree? Falls back to "unknown" outside git.
in_head() {
    if [ "$GIT_OK" = "yes" ]; then
        if git -C "$ROOT" cat-file -e "HEAD:$1" 2>/dev/null; then printf 'yes'; else printf 'no'; fi
    else
        printf 'n/a'
    fi
}

# Split a JSON-ish line into its first quoted string value.
#   "key": "value",  -> value
json_value() {
    sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/".*$//'
}

# Parse one config.json into records:
#   L<TAB>label     C<TAB>launch     E<TAB>name<TAB>script
parse_config() {
    awk '
        function val(line) {
            sub(/^[^:]*:[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            return line
        }
        {
            line = $0
            if (!in_list && line ~ /"launchlist"[[:space:]]*:/) { in_list = 1; next }
            if (!in_list) {
                if (line ~ /"label"[[:space:]]*:/)  { print "L\t" val(line); next }
                if (line ~ /"launch"[[:space:]]*:/) { print "C\t" val(line); next }
            } else {
                if (line ~ /"name"[[:space:]]*:/)       { name = val(line); next }
                if (line ~ /"launch"[[:space:]]*:/)     { print "E\t" name "\t" val(line); next }
            }
        }
    ' "$1"
}

# Declared fields of a libretro .info file.
info_field() {
    # $1 = info path, $2 = key
    [ -f "$1" ] || return 0
    sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "$1" | head -n 1
}

# Distinct, non-empty values of a file (one per line) joined with "|".
uniq_join() {
    awk 'NF && !seen[$0]++ { out = (out == "" ? $0 : out "|" $0) } END { print out }'
}

# ------------------------------------------------------------ emus table ----

emit_emus() {
    printf '%s\n' "emu	label	config_launch	launcher_count	launcher_scripts	engines	binaries	bin_in_head	bin_on_disk	version_declared	version_source	license_declared	license_source	notes"

    for dir in "$EMUS"/*/; do
        [ -d "$dir" ] || continue
        emu=$(basename "$dir")
        cfg="$dir/config.json"
        [ -f "$cfg" ] || continue

        parsed=$(parse_config "$cfg")
        label=$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="L"{print $2; exit}')
        cfg_launch=$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="C"{print $2; exit}')
        entries=$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="E" && $3!=""{print $2 "->" $3}')

        # Every script that the UI can end up running for this emulator.
        # load_launcher.sh falls back to launch.sh when config.json has no
        # launchlist, so that file is part of the chain too.
        scripts=$( { [ -n "$cfg_launch" ] && printf '%s\n' "$cfg_launch"
                     printf '%s\n' "$entries" | sed -n 's/.*->//p'
                     if [ -z "$entries" ] && [ -f "$dir/launch.sh" ]; then printf '%s\n' "launch.sh"; fi; } \
                   | awk 'NF && !seen[$0]++' )
        n_scripts=$(printf '%s' "$scripts" | awk 'NF' | wc -l | tr -d ' ')

        core_refs=""; ra_refs=""; bin_refs=""; arch_refs=""; unknowns=""; cross=""
        for s in $scripts; do
            # launchers living outside this emulator folder belong to their own row
            case "$s" in
                */*) cross="$cross $s"; continue ;;
            esac
            [ -f "$dir/$s" ] || { unknowns="$unknowns $s"; continue; }

            # libretro cores, RetroArch binary, archives used by this script
            c=$(grep -oE '[A-Za-z0-9_.+-]+_libretro(-[0-9.]+)?\.so' "$dir/$s" 2>/dev/null | sort -u)
            r=$(grep -oE 'ra64\.trimui[A-Za-z0-9_.-]*' "$dir/$s" 2>/dev/null | sort -u)

            core_refs=$(printf '%s\n%s\n' "$core_refs" "$c" | awk 'NF')
            ra_refs=$(printf '%s\n%s\n' "$ra_refs" "$r" | awk 'NF')

            # Standalone payloads. A launcher can cd around before exec'ing, so
            # resolve "./name" against the tracked working directory instead of
            # assuming the emulator folder. Emits:
            #   B<TAB>repo-relative-path      (candidate executable)
            #   A<TAB>archive<TAB>outdir      (7z archive extracted at runtime)
            refs=$(awk -v start="Emus/$emu" '
                function norm(p,   n, i, parts, out) {
                    n = split(p, parts, "/")
                    out = ""
                    for (i = 1; i <= n; i++) {
                        if (parts[i] == "" || parts[i] == ".") continue
                        if (parts[i] == "..") { sub(/\/?[^\/]+$/, "", out); continue }
                        out = (out == "" ? parts[i] : out "/" parts[i])
                    }
                    return out
                }
                BEGIN { cwd = start }
                {
                    line = $0
                    if (line ~ /^[[:space:]]*#/) next
                    # shell includes are not engines
                    if (line ~ /^[[:space:]]*(source|\.)[[:space:]]+/) next
                    # test/conditional/download lines probe paths, they do not launch
                    if (line ~ /^[[:space:]]*(if|elif|while|until|test)[[:space:]]/) next
                    if (line ~ /\[[[:space:]]/ || line ~ /(^|[[:space:]])curl[[:space:]]/) next

                    # literal variable assignment: remember it for cd resolution,
                    # never report it as a launched binary.
                    if (line ~ /^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/) {
                        v = line
                        sub(/^[[:space:]]*(export[[:space:]]+)?/, "", v)
                        name = v; sub(/=.*/, "", name)
                        val = v;  sub(/^[^=]*=/, "", val)
                        gsub(/"/, "", val)
                        if (val !~ /[[:space:]]/) vars[name] = val
                        if (line ~ /=[^[:space:]]*[[:space:]]*$/) next
                    }

                    # drop quoted strings that contain whitespace: those are UI
                    # paths/documents ("Pico8 Wrapper.sh"), never engine binaries
                    q = ""; rest = line
                    while (match(rest, /"[^"]*"/)) {
                        seg = substr(rest, RSTART, RLENGTH)
                        inner = substr(seg, 2, length(seg) - 2)
                        if (inner !~ /[[:space:]]/) q = q substr(rest, 1, RSTART - 1) seg
                        rest = substr(rest, RSTART + RLENGTH)
                    }
                    line = q rest

                    # working-directory tracking for literal cd arguments
                    if (line ~ /(^|[;&|])[[:space:]]*cd[[:space:]]+/) {
                        arg = line
                        sub(/.*cd[[:space:]]+/, "", arg)
                        sub(/[[:space:];&|].*$/, "", arg)
                        gsub(/"/, "", arg)
                        # expand a literal $VAR prefix captured above
                        if (arg ~ /^\$/) {
                            if (match(arg, /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {
                                name = substr(arg, 1, RLENGTH)
                                rest = substr(arg, RLENGTH + 1)
                                gsub(/^\$\{?|\}?$/, "", name)
                                if (name in vars) { arg = vars[name] rest }
                                else { next }
                            } else { next }
                        }
                        if (arg ~ /^\/mnt\/SDCARD\//) { cwd = substr(arg, 13) }
                        else if (arg ~ /^\//)       { cwd = "" }
                        else                        { cwd = norm((cwd == "" ? "" : cwd "/") arg) }
                        next
                    }

                    # 7z archives unpacked at runtime
                    if (line ~ /7zz?[[:space:]]/ && line ~ /\.7z/) {
                        arch = line; sub(/.*[[:space:]"]/, "", arch); sub(/".*$/, "", arch)
                        if (match(line, /[A-Za-z0-9_.\/+-]+\.7z/)) {
                            arch = substr(line, RSTART, RLENGTH)
                            sub(/^\/mnt\/SDCARD\//, "", arch)
                            out = ""
                            if (match(line, /-o"?[^"[:space:]]+/)) {
                                out = substr(line, RSTART + 2, RLENGTH - 2)
                                gsub(/"/, "", out)
                                sub(/^\/mnt\/SDCARD\//, "", out)
                            }
                            print "A\t" arch "\t" out
                        }
                    }

                    # absolute SD-card paths (skip shell globs like Background*)
                    tmp = line
                    while (match(tmp, /\/mnt\/SDCARD\/[A-Za-z0-9_.\/+-]+/)) {
                        nxt = substr(tmp, RSTART + RLENGTH, 1)
                        if (nxt != "*" && nxt != "\\")
                            print "B\t" substr(tmp, RSTART + 12, RLENGTH - 12)
                        tmp = substr(tmp, RSTART + RLENGTH)
                    }

                    # ./name, $PWD/name, $EMU_DIR/name
                    tmp = line
                    while (match(tmp, /(\.\/|\$PWD\/|\$\{EMU_DIR\}\/|\$EMU_DIR\/)[A-Za-z0-9_.+-]+/)) {
                        t = substr(tmp, RSTART, RLENGTH)
                        globbed = (substr(tmp, RSTART + RLENGTH, 1) == "*")
                        tmp = substr(tmp, RSTART + RLENGTH)
                        sub(/^(\.\/|\$PWD\/|\$\{EMU_DIR\}\/|\$EMU_DIR\/)/, "", t)
                        if (t ~ /\$/ || globbed) continue
                        base = cwd
                        print "B\t" norm((base == "" ? "" : base "/") t)
                    }

                    # explicit exec of a literal path (exec bin/openmsx, exec ../x/y)
                    if (line ~ /(^|[;&|])[[:space:]]*exec[[:space:]]+/) {
                        arg = line
                        sub(/.*exec[[:space:]]+/, "", arg)
                        sub(/[[:space:]].*$/, "", arg)
                        gsub(/"/, "", arg)
                        if (arg !~ /\$/ && arg != "") print "B\t" norm((cwd == "" ? "" : cwd "/") arg)
                    }
                }
            ' "$dir/$s" 2>/dev/null)

            # Archive target directories, so a payload that only exists inside a
            # .7z is reported as "archived" rather than "missing".
            archs=$(printf '%s\n' "$refs" | awk -F'\t' '$1=="A"{printf "%s|%s\n", $2, $3}')
            arch_refs=$(printf '%s\n%s\n' "$arch_refs" "$(printf '%s\n' "$archs" | cut -d'|' -f1)" | awk 'NF')

            for t in $(printf '%s\n' "$refs" | awk -F'\t' '$1=="B"{print $2}' | awk 'NF && !seen[$0]++'); do
                t=${t%/}
                case "$t" in
                    # data files, never engine binaries
                    *.png|*.jpg|*.bmp|*.txt|*.md|*.ini|*.cfg|*.conf|*.csv|*.xml|*.dat|*.db|\
                    *.ttf|*.otf|*.json|*.zip|*.7z|*.squashfs|*.gptk|*.so|*.so.*|*.raw|*.sh|*.log|*.wav) continue ;;
                esac
                case "$t" in *'$'*|*'*'*|''|*/.*) continue ;; esac
                # archive/audio helpers are tooling, not the emulated engine
                case "${t##*/}" in 7zz|7za|7z|aplay) continue ;; esac
                if is_blob "$t"; then
                    bin_refs=$(printf '%s\n%s\n' "$bin_refs" "$t" | awk 'NF')
                else
                    # a directory in HEAD is not an engine (lib/, Apps/x, Imgs)
                    if [ "$GIT_OK" = "yes" ] && [ "$(git -C "$ROOT" cat-file -t "HEAD:$t" 2>/dev/null)" = "tree" ]; then
                        continue
                    fi
                    # inside an archive extracted into this directory?
                    a=""
                    for pair in $archs; do
                        adir=$(printf '%s' "$pair" | cut -d'|' -f2)
                        case "$t" in
                            "${adir%/}"/*) a=$(printf '%s' "$pair" | cut -d'|' -f1); break ;;
                        esac
                    done
                    if [ -n "$a" ]; then
                        bin_refs=$(printf '%s\n%s\n' "$bin_refs" "archive:$a" | awk 'NF')
                    else
                        # payload not in git but an archive is unpacked inside this
                        # emulator folder: report it as archived, not missing
                        a=""
                        for pair in $archs; do
                            adir=$(printf '%s' "$pair" | cut -d'|' -f2)
                            case "$adir" in
                                "Emus/$emu"|"Emus/$emu"/*) a=$(printf '%s' "$pair" | cut -d'|' -f1); break ;;
                            esac
                        done
                        if [ -n "$a" ]; then
                            bin_refs=$(printf '%s\n%s\n' "$bin_refs" "archive:$a" | awk 'NF')
                        else
                            bin_refs=$(printf '%s\n%s\n' "$bin_refs" "MISSING:$t" | awk 'NF')
                        fi
                    fi
                fi
            done
        done

        core_refs=$(printf '%s\n' "$core_refs" | awk 'NF && !seen[$0]++' | sort)
        ra_refs=$(printf '%s\n' "$ra_refs" | awk 'NF && !seen[$0]++' | sort)
        bin_refs=$(printf '%s\n' "$bin_refs" | awk 'NF && !seen[$0]++' | sort)
        arch_refs=$(printf '%s\n' "$arch_refs" | awk 'NF && !seen[$0]++' | sort)

        # Engine kind
        engines=""
        [ -n "$ra_refs" ] && engines="retroarch"
        [ -n "$bin_refs" ] && { [ -n "$engines" ] && engines="$engines+standalone" || engines="standalone"; }
        [ -z "$engines" ] && engines="none"

        # Full repository paths of the invoked artifacts.
        bins=""
        for r in $ra_refs; do
            bins=$(printf '%s\nRetroArch/%s' "$bins" "$r" | awk 'NF')
        done
        for c in $core_refs; do
            if git -C "$ROOT" cat-file -e "HEAD:RetroArch/.retroarch/cores/$c" 2>/dev/null; then
                bins=$(printf '%s\nRetroArch/.retroarch/cores/%s' "$bins" "$c" | awk 'NF')
            else
                # shipped compressed: pick the matching .7z when present
                base=${c%.so}
                if git -C "$ROOT" cat-file -e "HEAD:RetroArch/.retroarch/cores/${base}.7z" 2>/dev/null; then
                    bins=$(printf '%s\narchive:RetroArch/.retroarch/cores/%s.7z' "$bins" "$base" | awk 'NF')
                else
                    bins=$(printf '%s\nMISSING:RetroArch/.retroarch/cores/%s' "$bins" "$c" | awk 'NF')
                fi
            fi
        done
        for b in $bin_refs; do
            bins=$(printf '%s\n%s' "$bins" "$b" | awk 'NF')
        done
        bins=$(printf '%s\n' "$bins" | awk 'NF && !seen[$0]++')

        # Presence: HEAD is the distribution, on-disk reflects this checkout.
        n_bins=$(printf '%s\n' "$bins" | awk 'NF' | wc -l | tr -d ' ')
        n_head=0; n_disk=0
        for b in $bins; do
            case "$b" in
                archive:*)
                    [ "$GIT_OK" = "yes" ] && git -C "$ROOT" cat-file -e "HEAD:${b#archive:}" 2>/dev/null && n_head=$((n_head+1))
                    [ -f "$ROOT/${b#archive:}" ] && n_disk=$((n_disk+1)) ;;
                MISSING:*) : ;;
                *)
                    [ "$GIT_OK" = "yes" ] && git -C "$ROOT" cat-file -e "HEAD:$b" 2>/dev/null && n_head=$((n_head+1))
                    [ -f "$ROOT/$b" ] && n_disk=$((n_disk+1)) ;;
            esac
        done
        if [ "$n_bins" -eq 0 ]; then head_state="n/a"; disk_state="n/a"
        else
            [ "$n_head" -eq "$n_bins" ] && head_state="yes" || head_state="partial($n_head/$n_bins)"
            [ "$n_head" -eq 0 ] && head_state="no"
            if [ "$n_disk" -eq "$n_bins" ]; then disk_state="yes"
            elif [ "$n_disk" -eq 0 ]; then disk_state="no"
            else disk_state="partial($n_disk/$n_bins)"; fi
        fi

        # Version + licence declared in the repository.
        versions=""; licenses=""; vsrc=""; lsrc=""
        for c in $core_refs; do
            inf="$CORES/${c%.so}.info"
            if [ -f "$inf" ]; then
                v=$(info_field "$inf" display_version)
                l=$(info_field "$inf" license)
                if [ -n "$v" ]; then
                    versions=$(printf '%s\n%s' "$versions" "$v" | awk 'NF')
                    vsrc="${vsrc}info:$c.info,"
                fi
                if [ -n "$l" ]; then
                    licenses=$(printf '%s\n%s' "$licenses" "$l" | awk 'NF')
                    lsrc="${lsrc}info:$c.info,"
                fi
            fi
        done

        notes=""
        if [ -z "$versions" ]; then
            # Last resort that still counts as a declaration: a version string
            # printed in the menu label itself (config.json), not the folder name.
            v=$(printf '%s' "$label" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)
            if [ -n "$v" ]; then
                versions="$v"; vsrc="config:label"
                notes="version taken from menu label text"
            fi
        fi
        # Standalone licence: only a licence file that ships next to the binary
        # (or at the emulator root) counts. Nothing is inferred from memory.
        if [ -z "$licenses" ]; then
            for b in $bins; do
                case "$b" in archive:*|MISSING:*) continue ;; esac
                bdir=$(dirname "$b")
                for probe in "$bdir" "$bdir/doc" "$bdir/licenses" "Emus/$emu"; do
                    [ -d "$ROOT/$probe" ] || continue
                    hit=$(ls "$ROOT/$probe" 2>/dev/null \
                          | grep -iE '(licen[cs]e|copying|notice)' | head -n 4 | tr '\n' ',')
                    [ -n "$hit" ] && { licenses="$licenses
file:$probe/{$(printf '%s' "${hit%,}")}"; lsrc="${lsrc}file:$probe"; break; }
                done
                [ -n "$lsrc" ] && break
            done
        fi

        version=$(printf '%s\n' "$versions" | uniq_join)
        license=$(printf '%s\n' "$licenses" | uniq_join)
        [ -n "$version" ] || version="UNKNOWN"
        [ -n "$license" ] || license="UNKNOWN"
        vsrc=$(printf '%s' "${vsrc%,}"); [ -n "$vsrc" ] || vsrc="none"
        lsrc=$(printf '%s' "${lsrc%,}"); [ -n "$lsrc" ] || lsrc="none"

        # Binary/archive names that look like versions are recorded as a hint only.
        for hint in $(printf '%s\n' "$ra_refs" "$bin_refs" | grep -oE '[0-9]+(\.[0-9]+)+' | sort -u | head -n 3); do
            notes="${notes:+$notes; }name hint $hint (not evidence)"
        done
        [ -n "$unknowns" ] && notes="${notes:+$notes; }script(s) referenced but absent:$(printf '%s' "$unknowns" | sed 's/^ //; s/ /,/g')"
        [ -n "$cross" ] && notes="${notes:+$notes; }launcher(s) in another folder:$(printf '%s' "$cross" | sed 's/^ //; s/ /,/g')"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$emu" "$label" "$cfg_launch" "$n_scripts" \
            "$(printf '%s' "$scripts" | awk 'NF && !seen[$0]++ { printf "%s%s", (n++?",":""), $0 }')" \
            "$engines" "$(printf '%s' "$bins" | tr '\n' ';' | sed 's/;$//')" \
            "$head_state" "$disk_state" "$version" "$vsrc" "$license" "$lsrc" "$notes"
    done
}

# ----------------------------------------------------------- cores table ----

# Core artifacts: prefer the committed tree (complete even in sparse checkouts),
# fall back to the working directory.
core_list() {
    if [ "$GIT_OK" = "yes" ]; then
        git -C "$ROOT" ls-tree -r --name-only HEAD -- "RetroArch/.retroarch/cores" 2>/dev/null \
            | sed -n 's|^RetroArch/.retroarch/cores/||p' | grep -E '\.(so|7z)$' | sort
    else
        ls "$CORES" 2>/dev/null | grep -E '\.(so|7z)$' | sort
    fi
}

# Which Emus launchers reference a given core basename?
core_consumers() {
    printf '%s' "$CONSUMER_INDEX" | awk -F'\t' -v c="$1" '$2==c { printf "%s%s", (n++?",":""), $1 }'
}

build_consumer_index() {
    for dir in "$EMUS"/*/; do
        emu=$(basename "$dir")
        for s in "$dir"*.sh; do
            [ -f "$s" ] || continue
            grep -oE '[A-Za-z0-9_.+-]+_libretro(-[0-9.]+)?\.so' "$s" 2>/dev/null \
                | while read -r c; do printf '%s\t%s\n' "$emu" "$c"; done
        done
    done | sort -u
}

emit_cores() {
    printf '%s\n' "core_file	display_name	display_version	license	referenced_by_count	referenced_by	info_file	present_in_head	present_on_disk"
    for c in $(core_list); do
        base=${c%.so}
        inf="$CORES/$base.info"
        name=""; ver=""; lic=""
        if [ -f "$inf" ]; then
            name=$(info_field "$inf" display_name)
            ver=$(info_field "$inf" display_version)
            lic=$(info_field "$inf" license)
            info="yes"
        else
            info="no"
        fi
        users=$(core_consumers "$c")
        n_users=$(printf '%s' "$users" | awk -F, 'NF && $0!="" {print NF}' )
        [ -n "$n_users" ] || n_users=0
        head="no"
        [ "$GIT_OK" = "yes" ] && git -C "$ROOT" cat-file -e "HEAD:RetroArch/.retroarch/cores/$c" 2>/dev/null && head="yes"
        disk="no"; [ -f "$CORES/$c" ] && disk="yes"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$c" "${name:-UNKNOWN}" "${ver:-UNKNOWN}" "${lic:-UNKNOWN}" \
            "$n_users" "${users:-none}" "$info" "$head" "$disk"
    done
}

# --------------------------------------------------------------- summary ----

emit_summary() {
    emus_total=$(ls -d "$EMUS"/*/ 2>/dev/null | wc -l | tr -d ' ')
    emus_cfg=$(ls "$EMUS"/*/config.json 2>/dev/null | wc -l | tr -d ' ')
    emus_util=$(ls -d "$EMUS"/_*/ 2>/dev/null | wc -l | tr -d ' ')

    tab=$(emit_emus | tail -n +2)
    with_ver=$(printf '%s\n' "$tab" | awk -F'	' '$10!="UNKNOWN"' | wc -l | tr -d ' ')
    with_ver_info=$(printf '%s\n' "$tab" | awk -F'	' '$10!="UNKNOWN" && $11 ~ /^info:/' | wc -l | tr -d ' ')
    with_ver_label=$(printf '%s\n' "$tab" | awk -F'	' '$11=="config:label"' | wc -l | tr -d ' ')
    with_lic=$(printf '%s\n' "$tab" | awk -F'	' '$12!="UNKNOWN"' | wc -l | tr -d ' ')
    all_head=$(printf '%s\n' "$tab" | awk -F'	' '$8=="yes"' | wc -l | tr -d ' ')
    some_missing=$(printf '%s\n' "$tab" | awk -F'	' '$8 ~ /^partial/ || $8=="no"' | wc -l | tr -d ' ')
    no_engine=$(printf '%s\n' "$tab" | awk -F'	' '$6=="none"' | wc -l | tr -d ' ')
    with_archive=$(printf '%s\n' "$tab" | awk -F'	' '$7 ~ /archive:/' | wc -l | tr -d ' ')
    hard_missing=$(printf '%s\n' "$tab" | awk -F'	' '$7 ~ /MISSING:/' | wc -l | tr -d ' ')
    stand=$(printf '%s\n' "$tab" | awk -F'	' '$6 ~ /standalone/' | wc -l | tr -d ' ')
    retro_only=$(printf '%s\n' "$tab" | awk -F'\t' '$6=="retroarch"' | wc -l | tr -d ' ')
    retro=$(printf '%s\n' "$tab" | awk -F'	' '$6 ~ /^retroarch/' | wc -l | tr -d ' ')

    cores_so=$(core_list | grep -c '\.so$')
    cores_7z=$(core_list | grep -c '\.7z$')
    cores_info=$(ls "$CORES"/*.info 2>/dev/null | wc -l | tr -d ' ')
    cores_noext=$( [ "$GIT_OK" = "yes" ] \
        && git -C "$ROOT" ls-tree -r --name-only HEAD -- RetroArch/.retroarch/cores \
           | sed -n 's|^RetroArch/.retroarch/cores/||p' | grep -vc '[.]' \
        || ls "$CORES" | grep -vc '[.]' )
    cores_ref=$(build_consumer_index | cut -f2 | sort -u | wc -l | tr -d ' ')
    cores_ref_missing=$(build_consumer_index | cut -f2 | sort -u | while read -r c; do
        [ "$GIT_OK" = "yes" ] && git -C "$ROOT" cat-file -e "HEAD:RetroArch/.retroarch/cores/$c" 2>/dev/null || echo "$c"
    done | wc -l | tr -d ' ')

    cat <<EOF
metric	value
emu_dirs_total	$emus_total
emu_dirs_with_config_json	$emus_cfg
emu_dirs_underscore_utility	$emus_util
emu_emulator_entries	$((emus_total - emus_util))
engine_retroarch_only	$retro_only
engine_retroarch_any	$retro
engine_standalone_any	$stand
engine_unresolved	$no_engine
version_declared_any	$with_ver
version_declared_from_info	$with_ver_info
version_declared_from_menu_label	$with_ver_label
version_unknown	$((emus_cfg - with_ver))
license_declared	$with_lic
license_unknown	$((emus_cfg - with_lic))
binaries_all_in_head	$all_head
binaries_partial_or_missing	$some_missing
rows_with_archived_payload	$with_archive
rows_with_absent_path	$hard_missing
cores_so	$cores_so
cores_7z	$cores_7z
cores_info	$cores_info
cores_no_extension	$cores_noext
cores_referenced_by_emus	$cores_ref
cores_referenced_absent_as_so	$cores_ref_missing
EOF
}

# ------------------------------------------------------------------ main ----

GIT_OK=no
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_OK=yes
fi

case "$WHAT" in
    emus)    emit_emus ;;
    cores)   CONSUMER_INDEX=$(build_consumer_index); emit_cores ;;
    summary) emit_summary ;;
    *)       usage >&2; exit 2 ;;
esac

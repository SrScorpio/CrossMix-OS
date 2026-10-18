#!/usr/bin/env python3
"""slim-measure.py - read-only weight audit of the CrossMix-OS SE payload.

Purpose
    Answer "how heavy is the SD payload, and where would a cut cost least?" with
    measured numbers instead of impressions. Every value is either measured here,
    extrapolated from a stratified sample and labelled as such, or emitted as null
    plus a *_status string that says why.

    The script never writes inside the tree it measures, never deletes, never
    rewrites an image and never executes a payload binary. Compressed probes are
    written to a scratch directory outside the tree and removed afterwards.

Sections
    totals        file count, apparent bytes, block bytes, payload vs repo-only
    categories    where the bytes live (longest-prefix match, .so/.7z split for cores)
    kinds         what the bytes are (image, font, audio, script, elf, archive, rom...)
    extensions    top extensions by bytes
    largest       top N files
    duplicates    exact byte-identical groups by sha256, with the wasted bytes
    near          same basename, size within 1%, different sha256 (heuristic)
    png           count/bytes, lossless re-encode potential measured on a size-stratified
                  sample, extrapolated to the population and marked "extrapolated"
    junk          OS metadata, editor/build leftovers, logs, zero-byte files, stale
                  versioned copies, versioned directories, per-resolution asset dirs
    cores         .so vs .7z: packed size of a size-stratified sample of extracted cores
                  measured with the release's own 7z settings, plus extraction cost
    firmware      firmware parts and the minimum-firmware declaration
    opportunities measured savings, each tied to the section that produced it

Robustness
    The report is checkpointed after every phase to FILE.partial, so a failure in a
    late phase still leaves the earlier measurements on disk. Each heavy phase runs in
    an explicitly shut down pool, and a phase that raises degrades to a *_status field
    instead of aborting the run. --limit makes a phase resumable: measured per-file
    results are cached in --cache and reused by the next invocation.

Usage
    scripts/slim-measure.py                          # audit, JSON to stdout
    scripts/slim-measure.py --output slim.json
    scripts/slim-measure.py --format tsv             # category table only
    scripts/slim-measure.py --png-sample 1200        # sample size (default 1200)
    scripts/slim-measure.py --png-all                # re-encode every PNG (slow)
    scripts/slim-measure.py --fast                   # skip PNG and core LZMA phases

Exit codes: 0 ok, 2 usage/IO error.
"""

import argparse
import concurrent.futures as futures
import hashlib
import io
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

SCHEMA = "crossmix-slim-measure/1"
CHUNK = 1 << 20

# --------------------------------------------------------------------- categories
# Longest matching prefix wins; an entry with a suffix set beats a bare prefix of the
# same length, so the libretro cores can be split from the rest of the tree.
# in_payload=False for the four paths the packaging step deletes
# (see .github/scripts/release-manifest.sh -> remove-assets-dir / remove-license-file
#  / remove-readme / remove-vcs-and-workflow).
CATEGORY_RULES = [
    ("cores-extracted", "libretro cores, extracted", ["RetroArch/.retroarch/cores"], {".so"}, True),
    ("cores-archives", "libretro cores, still .7z", ["RetroArch/.retroarch/cores"], {".7z"}, True),
    ("cores-metadata", "libretro core metadata", ["RetroArch/.retroarch/cores"], None, True),
    ("retroarch", "RetroArch frontend, assets, shaders", ["RetroArch"], None, True),
    ("emulators", "per-system emulator payloads", ["Emus"], None, True),
    ("apps", "applications", ["Apps"], None, True),
    ("system-updates", "bundled update payloads", ["System/updates"], None, True),
    ("system-runtime", "runtime libraries and binaries",
     ["System/lib", "System/bin", "System/sftpgo", "System/share",
      "System/include", "System/resources"], None, True),
    ("project-code", "project scripts and configuration",
     ["System/usr", "System/starts", "System/etc", "scripts", "docs"], None, True),
    ("vendor-trimui", "TrimUI vendor surface", ["trimui"], None, True),
    ("bios", "BIOS / firmware dumps", ["BIOS"], None, True),
    ("roms", "bundled ROMs", ["Roms"], None, True),
    ("artwork", "themes, icons, backgrounds, artwork",
     ["Themes", "Icons", "Backgrounds", "Imgs", "Pictures", "Data"], None, True),
    ("best-packs", "Best collection", ["Best"], None, True),
    ("repo-only", "repository-only (removed by packaging)",
     ["_assets", ".github", "LICENSE", "README.md"], None, False),
    ("root-files", "SD root metadata", ["autorun.inf", ".VolumeIcon.icns"], None, True),
]

# --------------------------------------------------------------------- kinds
KIND_BY_EXT = {}


def _kind(kind, exts):
    for e in exts.split():
        KIND_BY_EXT[e] = kind


_kind("image", "png jpg jpeg bmp gif webp ico svg icns tga pcx")
_kind("font", "ttf otf woff woff2 pgf fnt bdf")
_kind("audio", "wav ogg mp3 flac opus mod xm it s3m")
_kind("video", "mp4 avi mkv webm m4v")
_kind("archive", "7z zip gz xz tar tgz bz2 rar")
_kind("script", "sh bash py lua js tcl")
_kind("shader", "glsl glslp fsh filt slang")
_kind("config", "cfg ini json xml conf opt properties desktop menu html md txt list")
_kind("data", "dat db sqlite rdb pat info mo po cue m3u cht state srm sav")
_kind("rom", "rom wad iso chd gba gbc nes smc sfc z64 n64 pbp cso nds gb gen vpk xex")

JUNK_EXACT = {
    ".ds_store": "os-metadata",
    "thumbs.db": "os-metadata",
    "desktop.ini": "os-metadata",
    ".directory": "os-metadata",
}
JUNK_PREFIX = {"._": "os-metadata", ".spotlight": "os-metadata"}
JUNK_SUFFIX = {
    ".pyc": "editor-build", ".pyo": "editor-build", ".orig": "editor-build",
    ".rej": "editor-build", ".swp": "editor-build", ".swo": "editor-build",
    ".bak": "backup", ".old": "backup",
    ".tmp": "temporary", ".part": "temporary", ".crdownload": "temporary",
    ".log": "log",
}
STALE_VERSION_RE = re.compile(r"^(?P<base>.+?)[-_]v?(?P<ver>\d+(?:\.\d+)+)(?P<ext>\.[A-Za-z0-9]+)?$")

TEXT_EXTS = {".sh", ".bash", ".py", ".lua", ".js", ".cfg", ".ini", ".json", ".xml",
             ".conf", ".opt", ".txt", ".md", ".html", ".list", ".desktop", ".properties"}


# --------------------------------------------------------------------- helpers
def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def human(n):
    if n is None:
        return "-"
    v = float(n)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if abs(v) < 1024.0 or u == "TB":
            return ("%.0f %s" % (v, u)) if u == "B" else ("%.2f %s" % (v, u))
        v /= 1024.0


def classify_category(rel):
    best = None
    best_key = (-1, -1)
    for cid, _label, prefixes, exts, _in_payload in CATEGORY_RULES:
        for p in prefixes:
            if rel == p:
                plen = len(p)
            elif rel.startswith(p + "/"):
                plen = len(p)
            else:
                continue
            if exts and os.path.splitext(rel)[1].lower() not in exts:
                continue
            key = (plen, 1 if exts else 0)
            if key > best_key:
                best_key = key
                best = cid
    return best or "unclassified"


def kind_of(rel, path, category):
    ext = os.path.splitext(rel)[1].lower()
    base = os.path.basename(rel)
    if category == "cores-extracted":
        return "core"
    # Versioned shared objects (libSDL2-2.0.so.0) carry a numeric suffix, so the
    # extension alone would file them under "other".
    if ".so." in base or base.endswith(".so"):
        return "shared-library"
    if rel.startswith("trimui/firmwares/"):
        return "firmware"
    k = KIND_BY_EXT.get(ext.lstrip("."))
    if k:
        return k
    if not ext:
        try:
            with open(path, "rb") as f:
                if f.read(4) == b"\x7fELF":
                    return "elf-binary"
        except OSError:
            pass
    return "other"


def walk(root):
    """Yield (relpath, abspath, size, mtime_ns) for regular files, skipping .git."""
    stack = [(root, "")]
    while stack:
        d, prefix = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            rel = (prefix + "/" + e.name) if prefix else e.name
            if e.is_symlink():
                continue
            if e.is_dir(follow_symlinks=False):
                if rel == ".git" or e.name == ".git":
                    continue
                stack.append((e.path, rel))
            elif e.is_file(follow_symlinks=False):
                # A linked worktree has .git as a file, not a directory: skip it either way.
                if rel == ".git" or e.name == ".git":
                    continue
                try:
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                yield rel, e.path, st.st_size, st.st_mtime_ns


def load_cache(path):
    cache = {}
    if not os.path.isfile(path):
        return cache
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    cache[rec["k"]] = rec["v"]
                except (ValueError, KeyError):
                    continue
    except OSError:
        pass
    return cache


def append_cache(path, records):
    if not records:
        return
    try:
        with open(path, "a") as f:
            for k, v in records:
                f.write(json.dumps({"k": k, "v": v}) + "\n")
    except OSError:
        pass


def prompt_7z():
    """Locate a 7z CLI, preferring a normal system path over ad-hoc prefixes."""
    found = []
    for c in ("7z", "7zz", "7za"):
        p = shutil.which(c)
        if p:
            found.append(p)
    for p in found:
        if not p.startswith(("/tmp/", "/var/tmp/")):
            return p
    return found[0] if found else None


def run_pool(func, tasks, workers, chunksize=8):
    """Map over a pool and always join it, so no semaphore is left behind."""
    if not tasks:
        return []
    ex = futures.ProcessPoolExecutor(max_workers=max(1, workers))
    try:
        return list(ex.map(func, tasks, chunksize=chunksize))
    finally:
        ex.shutdown(wait=True, cancel_futures=True)


def stratified(items, key_bytes, bands, budget, seed=20261018):
    """Pick a size-stratified sample: quota per band proportional to file count,
    at least a floor, capped at what the band holds. Deterministic for a seed."""
    rnd = random.Random(seed)
    picked = []
    total = len(items)
    if total == 0:
        return picked
    for lo, hi, label in bands:
        band = [r for r in items if lo <= key_bytes(r) < hi]
        if not band:
            continue
        quota = int(budget * len(band) / float(total))
        quota = max(40, quota)
        quota = min(len(band), quota)
        if quota < len(band):
            picked.extend(rnd.sample(band, quota))
        else:
            picked.extend(band)
    return picked


def evenly_spaced(items, n):
    """Pick n items spread evenly across a size-sorted list, always including both
    ends, so a sample of cores covers the whole size range instead of the bulk."""
    ordered = sorted(items, key=lambda r: r["bytes"])
    if n >= len(ordered):
        return list(ordered)
    if n <= 1:
        return [ordered[-1]]
    idx = [int(round(i * (len(ordered) - 1) / float(n - 1))) for i in range(n)]
    return [ordered[i] for i in sorted(set(idx))]


# --------------------------------------------------------------------- PNG worker
def png_worker(args):
    """Measure one PNG. Returns measured, pixel-verified numbers or an error."""
    rel, path, size, max_pixels = args
    out = {"path": rel, "bytes": size, "decodable": False, "same_mode": None,
           "palette": None, "error": None, "skipped": None}
    try:
        from PIL import Image
    except ImportError:
        out["error"] = "PIL unavailable"
        return out
    try:
        with Image.open(path) as im:
            im.load()
            mode, dims = im.mode, im.size
            out["mode"] = mode
            out["width"], out["height"] = dims
            # A handful of 19-megapixel overlay scans cost minutes of deflate each and
            # hold 0.5% of the PNG bytes. They are reported as skipped, not guessed.
            if max_pixels and dims[0] * dims[1] > max_pixels:
                out["skipped"] = "above pixel cap (%dx%d)" % dims
                return out
            raw = im.tobytes()
            out["decodable"] = True

            # (a) same-mode re-encode at maximum deflate: lossless by construction.
            #     The output is decoded and compared only when it actually shrank, so
            #     the verification cost is paid exactly where a claim is made.
            buf = io.BytesIO()
            im.save(buf, format="PNG", optimize=True, compress_level=9)
            data = buf.getvalue()
            if len(data) < size:
                with Image.open(io.BytesIO(data)) as chk:
                    chk.load()
                    if chk.mode == mode and chk.size == dims and chk.tobytes() == raw:
                        out["same_mode"] = len(data)

            # (b) truecolor image that genuinely holds <=256 distinct colours: a
            #     palette rewrite is legitimate. getcolors() answers "how many colours"
            #     in one pass, so photographic images are skipped instead of being
            #     quantised pointlessly.
            if mode in ("RGB", "RGBA") and dims[0] * dims[1] > 0 and size > 1024:
                if im.getcolors(maxcolors=257) is not None:
                    res = im.convert("P", palette=Image.ADAPTIVE, colors=256)
                    back = res.convert("RGBA" if mode == "RGBA" else "RGB")
                    if back.tobytes() == raw:
                        buf2 = io.BytesIO()
                        res.save(buf2, format="PNG", optimize=True, compress_level=9)
                        d2 = buf2.getvalue()
                        if len(d2) < size:
                            with Image.open(io.BytesIO(d2)) as chk2:
                                chk2.load()
                                if chk2.tobytes() == res.tobytes():
                                    out["palette"] = len(d2)
    except Exception as exc:  # noqa: BLE001 - a broken PNG must not abort the audit
        out["error"] = "%s: %s" % (type(exc).__name__, exc)
    return out


# --------------------------------------------------------------------- core probe
def lzma_worker(args):
    """Compress one core with the release 7z settings, report the packed size."""
    seven, path, rel, size, outdir = args
    dst = os.path.join(outdir, hashlib.sha1(rel.encode()).hexdigest() + ".7z")
    t0 = time.time()
    try:
        subprocess.run([seven, "a", "-t7z", "-mx=7", "-mmt=2", "-bso0", "-bsp0", dst, path],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=1800)
        packed = os.path.getsize(dst)
        try:
            os.remove(dst)
        except OSError:
            pass
        return {"path": rel, "bytes": size, "packed": packed,
                "seconds": round(time.time() - t0, 2)}
    except Exception as exc:  # noqa: BLE001
        return {"path": rel, "bytes": size, "packed": None, "error": str(exc)}


PNG_BANDS = [(0, 65536, "<64 KB"), (65536, 262144, "64-256 KB"),
             (262144, 1048576, "256 KB-1 MB"), (1048576, 1 << 62, ">=1 MB")]


# --------------------------------------------------------------------- main
def main(argv):
    ap = argparse.ArgumentParser(prog="slim-measure.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    help="tree to measure (default: repository root of this script)")
    ap.add_argument("--output", help="write the JSON report here (default: stdout)")
    ap.add_argument("--format", choices=("json", "tsv"), default="json")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--png-sample", type=int, default=400,
                    help="PNG files to re-encode (size-stratified sample)")
    ap.add_argument("--png-all", action="store_true", help="re-encode every PNG")
    ap.add_argument("--png-max-pixels", type=int, default=8_000_000,
                    help="skip PNGs above this pixel count (0 = no cap)")
    ap.add_argument("--no-png", action="store_true", help="skip the PNG phase")
    ap.add_argument("--cores-sample", type=int, default=16,
                    help="extracted cores to compress (size-stratified sample)")
    ap.add_argument("--cores-all", action="store_true", help="compress every extracted core")
    ap.add_argument("--no-cores", action="store_true", help="skip the core LZMA phase")
    ap.add_argument("--fast", action="store_true", help="skip both heavy phases")
    ap.add_argument("--limit", type=int, default=0,
                    help="process at most N new sampled files this run (resumable)")
    ap.add_argument("--cache", help="cache dir for per-file results (default: under TMPDIR)")
    ap.add_argument("--hash-cache", action="store_true",
                    help="reuse sha256 digests across runs (keyed by path+size+mtime)")
    ap.add_argument("--no-hash", action="store_true",
                    help="skip sha256 (duplicate sections come out empty; for quick phases)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        sys.stderr.write("slim-measure: not a directory: %s\n" % root)
        return 2

    def log(msg):
        if not args.quiet:
            sys.stderr.write("slim-measure: %s\n" % msg)
            sys.stderr.flush()

    cache_dir = args.cache or os.path.join(tempfile.gettempdir(), "slim-measure-cache")
    try:
        os.makedirs(cache_dir, exist_ok=True)
    except OSError:
        cache_dir = tempfile.mkdtemp(prefix="slim-measure-cache-")
    png_cache_path = os.path.join(cache_dir, "png.jsonl")
    core_cache_path = os.path.join(cache_dir, "cores.jsonl")
    hash_cache_path = os.path.join(cache_dir, "sha256.jsonl")

    t_start = time.time()
    timings = {}
    phases = set()
    report = {
        "schema": SCHEMA, "generated_at": now_iso(), "root": root,
        "complete": False, "phases_done": [], "phases_failed": [],
        "git": {}, "tooling": {}, "totals": {}, "categories": [], "kinds": [],
        "extensions": [], "largest": [], "duplicates": {}, "near_duplicates": {},
        "png": {}, "junk": {}, "cores": {}, "firmware": {}, "opportunities": [],
        "warnings": [], "timings_seconds": {},
    }

    def checkpoint(final=False):
        report["phases_done"] = sorted(phases)
        report["timings_seconds"] = dict(timings, total=round(time.time() - t_start, 2))
        report["complete"] = bool(final)
        text = json.dumps(report, indent=2)
        if args.format == "tsv" and final:
            lines = ["category\tin_payload\tfiles\tbytes\tshare"]
            for c in report["categories"]:
                lines.append("%s\t%s\t%d\t%d\t%.2f%%" % (c["id"], c["in_payload"], c["files"],
                                                       c["bytes"], c["share"] * 100))
            text = "\n".join(lines) + "\n"
        if args.output:
            target = args.output if final else args.output + ".partial"
            try:
                with open(target, "w") as f:
                    f.write(text)
            except OSError as exc:
                log("checkpoint failed: %s" % exc)
        elif final:
            sys.stdout.write(text)

    try:
        # ------------------------------------------------------------ inventory
        log("inventory: walking %s" % root)
        t0 = time.time()
        files = list(walk(root))
        timings["inventory"] = round(time.time() - t0, 2)
        total_bytes = sum(f[2] for f in files)

        rows = []
        for rel, path, size, mtime in files:
            cat = classify_category(rel)
            rows.append({"path": rel, "abs": path, "bytes": size, "mtime": mtime,
                         "category": cat, "kind": kind_of(rel, path, cat),
                         "ext": os.path.splitext(rel)[1].lower().lstrip(".") or "(none)"})
        by_path = {r["path"]: r for r in rows}

        cat_meta = {c[0]: {"label": c[1], "in_payload": c[4]} for c in CATEGORY_RULES}
        cat_meta["unclassified"] = {"label": "unclassified", "in_payload": True}

        categories, kinds, exts = {}, {}, {}
        for r in rows:
            c = categories.setdefault(r["category"], {"files": 0, "bytes": 0, "kinds": {}})
            c["files"] += 1
            c["bytes"] += r["bytes"]
            k = c["kinds"].setdefault(r["kind"], {"files": 0, "bytes": 0})
            k["files"] += 1
            k["bytes"] += r["bytes"]
            kk = kinds.setdefault(r["kind"], {"files": 0, "bytes": 0})
            kk["files"] += 1
            kk["bytes"] += r["bytes"]
            e = exts.setdefault(r["ext"], {"files": 0, "bytes": 0})
            e["files"] += 1
            e["bytes"] += r["bytes"]

        payload_bytes = sum(c["bytes"] for cid, c in categories.items()
                            if cat_meta.get(cid, {}).get("in_payload", True))
        repo_only_bytes = total_bytes - payload_bytes

        warnings = []
        unc = categories.get("unclassified")
        if unc and unc["bytes"] > 0.25 * (total_bytes or 1):
            warnings.append("%.0f%% of the bytes matched no category: --root was probably "
                            "not the repository root"
                            % (100.0 * unc["bytes"] / (total_bytes or 1)))

        disk_bytes = None
        du = shutil.which("du")
        if du:
            try:
                res = subprocess.run([du, "-sk", "--exclude=.git", root],
                                     capture_output=True, text=True, timeout=600)
                if res.returncode == 0:
                    disk_bytes = int(res.stdout.split()[0]) * 1024
            except (OSError, ValueError, IndexError, subprocess.SubprocessError):
                disk_bytes = None

        report["totals"] = {
            "files": len(rows), "total_bytes": total_bytes,
            "payload_bytes": payload_bytes, "repo_only_bytes": repo_only_bytes,
            "disk_bytes": disk_bytes,
            "disk_bytes_status": "measured with du -sk" if disk_bytes else "unavailable",
        }
        report["categories"] = [
            dict(id=cid, label=cat_meta.get(cid, {}).get("label", cid),
                 in_payload=cat_meta.get(cid, {}).get("in_payload", True),
                 files=c["files"], bytes=c["bytes"],
                 share=round(c["bytes"] / float(total_bytes or 1), 4),
                 kinds=sorted(({"kind": k, "files": v["files"], "bytes": v["bytes"]}
                               for k, v in c["kinds"].items()),
                              key=lambda x: x["bytes"], reverse=True))
            for cid, c in sorted(categories.items(), key=lambda kv: kv[1]["bytes"], reverse=True)]
        report["kinds"] = sorted(({"kind": k, "files": v["files"], "bytes": v["bytes"]}
                                  for k, v in kinds.items()), key=lambda x: x["bytes"], reverse=True)
        report["extensions"] = sorted(({"ext": k, "files": v["files"], "bytes": v["bytes"]}
                                       for k, v in exts.items()),
                                      key=lambda x: x["bytes"], reverse=True)[:args.top]
        report["largest"] = sorted(({"path": r["path"], "bytes": r["bytes"],
                                     "category": r["category"]} for r in rows),
                                   key=lambda x: x["bytes"], reverse=True)[:args.top]
        phases.add("inventory")
        checkpoint()
        log("inventory: %d files, %s (%s on disk)"
            % (len(rows), human(total_bytes), human(disk_bytes)))

        # ------------------------------------------------------------ hashes
        log("hashing %d files (%s)" % (len(rows), human(total_bytes)))
        t0 = time.time()
        hcache = load_cache(hash_cache_path) if args.hash_cache else {}
        if args.no_hash:
            for r in rows:
                r["_hkey"] = "%s\t%d\t%d" % (r["path"], r["bytes"], r["mtime"])
            pending = []
            log("hash: skipped (--no-hash)")
        else:
            for r in rows:
                key = "%s\t%d\t%d" % (r["path"], r["bytes"], r["mtime"])
                r["_hkey"] = key
                if key in hcache:
                    r["sha256"] = hcache[key]

        def hash_row(r):
            try:
                return r["_hkey"], sha256_file(r["abs"])
            except OSError:
                return r["_hkey"], None

        pending = [r for r in rows if not r.get("sha256")]
        if not args.no_hash:
            log("hash: %d cached, %d to read" % (len(rows) - len(pending), len(pending)))
            tp = futures.ThreadPoolExecutor(max_workers=max(4, args.jobs))
            try:
                for key, digest in tp.map(hash_row, pending, chunksize=64):
                    if digest:
                        hcache[key] = digest
            finally:
                tp.shutdown(wait=True)
            for r in rows:
                if not r.get("sha256") and r["_hkey"] in hcache:
                    r["sha256"] = hcache[r["_hkey"]]
            if args.hash_cache:
                append_cache(hash_cache_path, list(hcache.items()))
        timings["hash"] = round(time.time() - t0, 2)

        groups = {}
        for r in rows:
            d = r.get("sha256")
            if d:
                groups.setdefault(d, []).append(r)
        dups = []
        for d, g in groups.items():
            if len(g) < 2:
                continue
            payload_copies = sum(1 for x in g
                                 if cat_meta.get(x["category"], {}).get("in_payload", True))
            dups.append({"sha256": d, "bytes": g[0]["bytes"], "copies": len(g),
                         "wasted": g[0]["bytes"] * (len(g) - 1),
                         "payload_copies": payload_copies,
                         "categories": sorted({x["category"] for x in g}),
                         "paths": sorted(x["path"] for x in g)})
        dups.sort(key=lambda d: d["wasted"], reverse=True)
        dup_wasted_total = sum(d["wasted"] for d in dups)
        dup_wasted_payload = sum(d["bytes"] * max(0, d["payload_copies"] - 1) for d in dups)

        by_base = {}
        for r in rows:
            by_base.setdefault(os.path.basename(r["path"]), []).append(r)
        near = []
        for base, g in by_base.items():
            if len(g) < 2:
                continue
            for i in range(len(g)):
                for j in range(i + 1, len(g)):
                    a, b = g[i], g[j]
                    sa, sb = a.get("sha256"), b.get("sha256")
                    if sa and sb and sa == sb:
                        continue
                    hi = max(a["bytes"], b["bytes"])
                    if hi and abs(a["bytes"] - b["bytes"]) / hi <= 0.01:
                        near.append({"name": base, "bytes": [a["bytes"], b["bytes"]],
                                     "paths": [a["path"], b["path"]],
                                     "reclaimable": min(a["bytes"], b["bytes"])})
        near.sort(key=lambda d: d["reclaimable"], reverse=True)

        report["duplicates"] = {
            "groups": len(dups), "redundant_files": sum(d["copies"] - 1 for d in dups),
            "wasted_bytes": dup_wasted_total, "wasted_payload_bytes": dup_wasted_payload,
            "top": dups[:args.top],
        }
        report["near_duplicates"] = {
            "note": "heuristic: same basename, size within 1%, different sha256",
            "groups": len(near), "reclaimable_bytes": sum(d["reclaimable"] for d in near),
            "top": near[:args.top],
        }
        phases.add("hash")
        checkpoint()
        log("hash: %d duplicate groups, %s wasted (%s inside the payload)"
            % (len(dups), human(dup_wasted_total), human(dup_wasted_payload)))

        # ------------------------------------------------------------ png
        pngs = [r for r in rows if r["ext"] == "png"]
        png_bytes = sum(r["bytes"] for r in pngs)
        png_section = {
            "count": len(pngs), "bytes": png_bytes, "status": "skipped",
            "method": "PIL re-encode at compress_level=9 + optimize, every claim "
                      "verified by decoding the result and comparing pixel bytes",
            "measured": None, "bands": [], "extrapolated": None, "top": [],
        }
        if not args.fast and not args.no_png and pngs:
            budget = len(pngs) if args.png_all else min(args.png_sample, len(pngs))
            sample = stratified(pngs, lambda r: r["bytes"], PNG_BANDS, budget)
            cache = load_cache(png_cache_path)
            todo, reused = [], 0
            for r in sample:
                key = "%s\t%d\t%d" % (r["path"], r["bytes"], r["mtime"])
                r["_cache_key"] = key
                if key in cache:
                    reused += 1
                else:
                    todo.append(r)
            if args.limit:
                todo = todo[:args.limit]
            log("png: %d sampled of %d (%s), %d cached, %d to process"
                % (len(sample), len(pngs), human(sum(r["bytes"] for r in sample)),
                   reused, len(todo)))
            t0 = time.time()
            fresh = run_pool(png_worker,
                             [(r["path"], r["abs"], r["bytes"], args.png_max_pixels)
                              for r in todo], args.jobs, chunksize=8)
            append_cache(png_cache_path, [
                (r["_cache_key"], {"path": x["path"], "bytes": x["bytes"],
                                   "decodable": x["decodable"], "same_mode": x["same_mode"],
                                   "palette": x["palette"], "skipped": x.get("skipped"),
                                   "mode": x.get("mode"), "error": x["error"]})
                for r, x in zip(todo, fresh)])
            timings["png"] = round(time.time() - t0, 2)

            results = []
            for r in sample:
                v = cache.get(r["_cache_key"])
                if v is None:
                    for x in fresh:
                        if x["path"] == r["path"]:
                            v = x
                            break
                if v:
                    results.append(v)

            measured_bytes = sum(v["bytes"] for v in results if not v.get("skipped"))
            skipped = [v for v in results if v.get("skipped")]
            saving_items = []
            for v in results:
                if v.get("skipped"):
                    continue
                best = min([b for b in (v.get("same_mode"), v.get("palette")) if b],
                           default=None)
                if best is not None and v["bytes"] > best:
                    saving_items.append({"path": v["path"], "bytes": v["bytes"],
                                         "new": best, "saving": v["bytes"] - best,
                                         "via": "palette" if v.get("palette") == best else "reencode"})
            measured_saving = sum(s["saving"] for s in saving_items)

            bands = []
            for lo, hi, label in PNG_BANDS:
                band = [r for r in pngs if lo <= r["bytes"] < hi]
                sband = [v for v in results if lo <= v["bytes"] < hi and not v.get("skipped")]
                if not band or not sband:
                    continue
                sbytes = sum(v["bytes"] for v in sband)
                ssave = sum(s["saving"] for s in saving_items
                            if lo <= s["bytes"] < hi)
                ratio = ssave / float(sbytes) if sbytes else 0.0
                bands.append({
                    "band": label, "files": len(band), "bytes": sum(r["bytes"] for r in band),
                    "sampled_files": len(sband), "sampled_bytes": sbytes,
                    "sampled_saving": ssave, "ratio": round(ratio, 4),
                    "projected_saving": int(round(ratio * sum(r["bytes"] for r in band))),
                })
            projected = sum(b["projected_saving"] for b in bands)

            png_section.update({
                "status": "measured+extrapolated",
                "sampled_files": len(results),
                "sampled_bytes": measured_bytes,
                "sampled_saving_bytes": measured_saving,
                "sampled_ratio": round(measured_saving / float(measured_bytes), 4)
                if measured_bytes else None,
                "measured": {
                    "files": len(saving_items),
                    "bytes": sum(s["bytes"] for s in saving_items),
                    "saving_bytes": measured_saving,
                    "recompressible_share": round(len(saving_items) / float(len(results)), 4)
                    if results else None,
                    "via_reencode": sum(1 for s in saving_items if s["via"] == "reencode"),
                    "via_palette": sum(1 for s in saving_items if s["via"] == "palette"),
                    "undecodable": sum(1 for v in results if not v.get("decodable")),
                    "skipped_large_files": len(skipped),
                    "skipped_large_bytes": sum(v["bytes"] for v in skipped),
                    "skipped_large_ratio": round(
                        sum(v["bytes"] for v in skipped) / float(png_bytes), 4) if png_bytes else None,
                },
                "extrapolated": {
                    "saving_bytes": projected,
                    "recompressible_files": int(round(
                        (len(saving_items) / float(len(results))) * len(pngs))) if results else None,
                    "basis": "%d size-stratified PNGs of %d" % (len(results), len(pngs)),
                    "note": "per-band saving ratio applied to each band's total bytes; "
                            "not a per-file measurement of the population",
                },
                "bands": bands,
                "top": saving_items[:args.top],
                "modes": {m: sum(1 for v in results if v.get("mode") == m)
                          for m in sorted({v.get("mode") for v in results if v.get("mode")})},
            })
            phases.add("png")
            checkpoint()
            log("png: sample %s -> %s saved (%.1f%%), projected %s"
                % (human(measured_bytes), human(measured_saving),
                   100.0 * (measured_saving / measured_bytes if measured_bytes else 0),
                   human(projected)))
        else:
            phases.add("png")
        report["png"] = png_section

        # ------------------------------------------------------------ junk
        log("junk: scanning names")
        code_exts = {e.lstrip(".") for e in TEXT_EXTS}
        doc_exts = {"md", "txt", "html"}
        ref_code_files = [r for r in rows if r["ext"] in code_exts and r["ext"] not in doc_exts]
        ref_doc_files = [r for r in rows if r["ext"] in doc_exts]

        def slurp(rs):
            buf = []
            for r in rs:
                if r["bytes"] > 4 << 20:
                    continue
                try:
                    with open(r["abs"], "rb") as f:
                        buf.append(f.read().decode("utf-8", "replace"))
                except OSError:
                    continue
            return "\n".join(buf)

        refs_code = slurp(ref_code_files)
        refs_doc = slurp(ref_doc_files)

        junk, zero = [], [r for r in rows if r["bytes"] == 0]
        for r in rows:
            base = os.path.basename(r["path"]).lower()
            reason = None
            if base in JUNK_EXACT:
                reason = JUNK_EXACT[base]
            elif any(base.startswith(p) for p in JUNK_PREFIX):
                reason = "os-metadata"
            else:
                for suf, why in JUNK_SUFFIX.items():
                    if base.endswith(suf):
                        reason = why
                        break
            if base == ".gitkeep":
                reason = "placeholder"
            if reason:
                junk.append({"path": r["path"], "bytes": r["bytes"], "reason": reason})

        # Stale versioned siblings: "name-1.2.3.ext" next to "name.ext" and absent from
        # every script/config. Documentation mentions are recorded separately: they mean
        # the file is kept as evidence, not that anything loads it.
        stale = []
        for r in rows:
            m = STALE_VERSION_RE.match(os.path.basename(r["path"]))
            if not m:
                continue
            base_name = m.group("base") + (m.group("ext") or "")
            d = os.path.dirname(r["path"])
            sib = os.path.join(d, base_name) if d else base_name
            if sib not in by_path:
                continue
            name = os.path.basename(r["path"])
            if name not in refs_code and r["bytes"] >= 65536:
                stale.append({"path": r["path"], "bytes": r["bytes"], "replaced_by": sib,
                              "documented_only": name in refs_doc})

        # Versioned directory pairs: both variants named in a launcher config means a
        # user-selectable choice, not clutter.
        vdirs = {}
        for r in rows:
            parts = r["path"].split("/")
            for i, part in enumerate(parts[:-1]):
                m = STALE_VERSION_RE.match(part)
                if m:
                    vdirs.setdefault(os.path.join(*parts[:i], m.group("base")), set()).add(
                        "/".join(parts[:i + 1]))
        vdir_pairs = []
        for key, dirs in vdirs.items():
            if len(dirs) > 1:
                exposed = sorted(d for d in dirs if os.path.basename(d) in refs_code)
                vdir_pairs.append({
                    "base": key, "variants": sorted(dirs),
                    "exposed_in_launcher_config": exposed,
                    "verdict": "user-selectable" if len(exposed) > 1 else "unreferenced",
                    "bytes": sum(r["bytes"] for r in rows
                                 if any(r["path"].startswith(d + "/") for d in dirs)),
                })

        # Per-resolution asset dirs (Images_1280x720 / Images_1024x768). One tree ships
        # for both the tsp (1280x720) and the brick (1024x768), so a resolution folder is
        # only removable when no script selects it.
        device_variants = []
        seen_dirs = set()
        for r in rows:
            parts = r["path"].split("/")
            for i, part in enumerate(parts[:-1]):
                m = re.match(r"^Images_(\d+x\d+)$", part)
                if not m:
                    continue
                d = "/".join(parts[:i + 1])
                if d in seen_dirs:
                    continue
                seen_dirs.add(d)
                device_variants.append({
                    "dir": d, "resolution": m.group(1),
                    "referenced_in_code": part in refs_code,
                    "bytes": sum(r2["bytes"] for r2 in rows if r2["path"].startswith(d + "/")),
                })
        for dv in device_variants:
            dv["verdict"] = "required" if dv["referenced_in_code"] else "unreferenced"

        report["junk"] = {
            "files": len(junk), "bytes": sum(j["bytes"] for j in junk),
            "by_reason": _sum_by(junk, "reason"), "items": junk[:args.top],
            "zero_byte_files": len(zero),
            "zero_byte_excluding_gitkeep": sum(1 for z in zero if not z["path"].endswith(".gitkeep")),
            "stale_versioned": {"count": len(stale),
                                "bytes": sum(s["bytes"] for s in stale),
                                "items": stale[:args.top],
                                "reference_scan_code_files": len(ref_code_files),
                                "reference_scan_doc_files": len(ref_doc_files)},
            "versioned_dirs": vdir_pairs,
            "device_variants": device_variants,
        }
        phases.add("junk")
        checkpoint()

        # ------------------------------------------------------------ cores
        log("cores: collecting archive metadata")
        seven = prompt_7z()
        cores = {
            "extracted_count": sum(1 for r in rows if r["category"] == "cores-extracted"),
            "extracted_bytes": sum(r["bytes"] for r in rows if r["category"] == "cores-extracted"),
            "archives": [], "archive_bytes": 0, "archive_uncompressed_bytes": 0,
            "seven": seven, "seven_status": "found" if seven else "not found",
            "lzma": {"status": "skipped"},
        }
        for r in rows:
            if r["category"] != "cores-archives":
                continue
            entry = {"path": r["path"], "packed": r["bytes"], "members": None,
                     "member_names": [], "uncompressed": None, "ratio": None}
            if seven:
                try:
                    out = subprocess.run([seven, "l", "-slt", r["abs"]], capture_output=True,
                                         text=True, timeout=300).stdout
                    names, total = [], 0
                    for line in out.splitlines():
                        if line.startswith("Path = "):
                            name = line[7:]
                            if name != r["path"] and not name.endswith("/"):
                                names.append(name)
                        elif line.startswith("Size = ") and line[7:].isdigit():
                            total += int(line[7:])
                    entry["members"] = len(names)
                    entry["member_names"] = names[:10]
                    entry["uncompressed"] = total
                    if total:
                        entry["ratio"] = round(1 - r["bytes"] / float(total), 4)
                except (subprocess.SubprocessError, OSError):
                    pass
            cores["archive_bytes"] += r["bytes"]
            if entry["uncompressed"]:
                cores["archive_uncompressed_bytes"] += entry["uncompressed"]
            cores["archives"].append(entry)

        if not args.fast and not args.no_cores and seven and cores["extracted_count"]:
            extracted = [r for r in rows if r["category"] == "cores-extracted"]
            budget = len(extracted) if args.cores_all else min(args.cores_sample, len(extracted))
            sample = evenly_spaced(extracted, budget)
            cache = load_cache(core_cache_path)
            todo, reused = [], 0
            for r in sample:
                r["_cache_key"] = "%s\t%d\t%d" % (r["path"], r["bytes"], r["mtime"])
                if r["_cache_key"] in cache:
                    reused += 1
                else:
                    todo.append(r)
            if args.limit:
                todo = todo[:args.limit]
            log("cores: %d sampled of %d (%s), %d cached, %d to process"
                % (len(sample), len(extracted), human(sum(r["bytes"] for r in sample)),
                   reused, len(todo)))
            t0 = time.time()
            scratch = tempfile.mkdtemp(prefix="slim-measure-")
            try:
                fresh = run_pool(lzma_worker,
                                 [(seven, r["abs"], r["path"], r["bytes"], scratch)
                                  for r in todo], max(1, min(4, args.jobs)), chunksize=1)
            finally:
                shutil.rmtree(scratch, ignore_errors=True)
            append_cache(core_cache_path, [
                (r["_cache_key"], {"path": x["path"], "bytes": x["bytes"],
                                   "packed": x["packed"], "error": x.get("error")})
                for r, x in zip(todo, fresh)])
            timings["cores_lzma"] = round(time.time() - t0, 2)

            items = []
            for r in sample:
                v = cache.get(r["_cache_key"])
                if v is None:
                    for x in fresh:
                        if x["path"] == r["path"]:
                            v = x
                            break
                if v and v.get("packed"):
                    items.append(v)
            raw = sum(i["bytes"] for i in items)
            packed = sum(i["packed"] for i in items)
            ratio = (1 - packed / float(raw)) if raw else None
            cores["lzma"] = {
                "status": "measured+extrapolated",
                "sampled_files": len(items), "sampled_bytes": raw,
                "sampled_packed_bytes": packed, "ratio": round(ratio, 4) if ratio else None,
                "sampled_saving_bytes": raw - packed,
                "projected_saving_bytes": int(round((ratio or 0) * cores["extracted_bytes"])),
                "basis": "%d size-stratified cores of %d"
                         % (len(items), cores["extracted_count"]),
                "items": sorted(items, key=lambda i: i["bytes"] - i["packed"],
                                reverse=True)[:args.top],
            }
            log("cores: sample %s -> %s packed (%.1f%% smaller), projected saving %s"
                % (human(raw), human(packed), 100 * (ratio or 0),
                   human(cores["lzma"]["projected_saving_bytes"])))

        # extraction cost on this host, for the .so-vs-.7z trade-off
        extract_probe = {"status": "not run"}
        if seven and not args.fast:
            cand = max((r for r in rows if r["category"] == "cores-extracted"),
                       key=lambda r: r["bytes"], default=None)
            if cand:
                scratch = tempfile.mkdtemp(prefix="slim-measure-x-")
                try:
                    arc = os.path.join(scratch, "probe.7z")
                    subprocess.run([seven, "a", "-t7z", "-mx=7", "-mmt=2", "-bso0", "-bsp0",
                                    arc, cand["abs"]], check=True, timeout=1800,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    t0 = time.time()
                    subprocess.run([seven, "x", "-y", "-bso0", "-bsp0", "-o" + scratch, arc],
                                   check=True, timeout=1800,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    secs = time.time() - t0
                    extract_probe = {"status": "measured on host", "path": cand["path"],
                                     "bytes": cand["bytes"], "seconds": round(secs, 2),
                                     "mb_per_s": round(cand["bytes"] / secs / 1048576.0, 1)}
                except (subprocess.SubprocessError, OSError) as exc:
                    extract_probe = {"status": "failed: %s" % exc}
                finally:
                    shutil.rmtree(scratch, ignore_errors=True)
        cores["extract_probe"] = extract_probe
        report["cores"] = cores
        phases.add("cores")
        checkpoint()

        # ------------------------------------------------------------ firmware
        fw = {"parts": [], "bytes": 0, "min_version": None}
        for r in rows:
            if r["path"].startswith("trimui/firmwares/") and ".7z." in r["path"]:
                fw["parts"].append({"path": r["path"], "bytes": r["bytes"]})
                fw["bytes"] += r["bytes"]
        minf = os.path.join(root, "trimui/firmwares/MinFwVersion.txt")
        if os.path.isfile(minf):
            try:
                with open(minf, "r", errors="replace") as f:
                    fw["min_version"] = [l.strip() for l in f.readlines()[:2]]
            except OSError:
                pass
        report["firmware"] = fw

        # ------------------------------------------------------------ git
        git = {"commit": None, "branch": None, "sparse": None, "tracked_files": None}
        git_dir = os.path.join(root, ".git")
        if shutil.which("git") and (os.path.isdir(git_dir) or os.path.isfile(git_dir)):
            def git_out(*a):
                try:
                    return subprocess.run(["git", "-C", root] + list(a), capture_output=True,
                                          text=True, timeout=120).stdout.strip()
                except (subprocess.SubprocessError, OSError):
                    return ""
            commit = git_out("rev-parse", "HEAD")
            if commit:
                git["commit"] = commit
            branch = git_out("rev-parse", "--abbrev-ref", "HEAD")
            if branch:
                git["branch"] = branch
            git["sparse"] = bool(git_out("sparse-checkout", "list"))
            tracked = git_out("ls-tree", "-r", "--name-only", "HEAD").splitlines()
            git["tracked_files"] = len(tracked) or None
        report["git"] = git
        report["tooling"] = {"seven": seven, "python": sys.version.split()[0],
                             "jobs": args.jobs, "pillow": _pillow_version(),
                             "cache_dir": cache_dir}

        # ------------------------------------------------------------ opportunities
        opps = []

        def add_opp(oid, label, saving, risk, evidence, applies_to, extrapolated=False):
            if saving and saving > 0:
                opps.append({"id": oid, "label": label, "saving_bytes": int(saving),
                             "risk": risk, "applies_to": applies_to,
                             "extrapolated": extrapolated, "evidence": evidence})

        lz = report["cores"].get("lzma", {})
        if lz.get("projected_saving_bytes"):
            add_opp("cores-7z", "Ship extracted libretro cores as .7z and unpack on device",
                    lz["projected_saving_bytes"], "medium",
                    "7z -mx=7 on %d of %d extracted cores (%.1f%% smaller)"
                    % (lz["sampled_files"], report["cores"]["extracted_count"],
                       100 * (lz["ratio"] or 0)), "payload", True)
        pj = report["png"].get("extrapolated")
        if pj and pj.get("saving_bytes"):
            add_opp("png-lossless", "Lossless PNG re-encode (pixel-verified)",
                    pj["saving_bytes"], "low",
                    "%s sampled, %.1f%% smaller" % (pj["basis"],
                                                   100 * (report["png"].get("sampled_ratio") or 0)),
                    "payload", True)
        if dup_wasted_payload:
            add_opp("exact-dups", "Drop byte-identical duplicate files inside the payload",
                    dup_wasted_payload, "low",
                    "%d exact duplicate groups, payload copies only" % len(dups), "payload")
        if stale:
            add_opp("stale-binaries", "Drop stale versioned copies of shipped binaries",
                    sum(s["bytes"] for s in stale), "low",
                    "%d versioned siblings of a shipped file, absent from every script and "
                    "config" % len(stale), "payload")
        dv_bytes = sum(d["bytes"] for d in device_variants if d["verdict"] == "unreferenced")
        if dv_bytes:
            add_opp("device-variant-assets", "Drop per-resolution assets no script selects",
                    dv_bytes, "medium",
                    "Images_WxH folders with no selection branch in launch.sh", "payload")
        repo_dups = sum(d["wasted"] for d in dups if d["payload_copies"] == 0)
        if repo_dups:
            add_opp("repo-only-dups", "Drop duplicates that exist only in repository-only paths",
                    repo_dups, "none",
                    "duplicate groups whose copies all live in repo-only paths", "repository")

        opps.sort(key=lambda o: o["saving_bytes"], reverse=True)
        report["opportunities"] = opps
        report["warnings"] = warnings
        phases.add("opportunities")
        checkpoint(final=True)
        log("done in %.1fs" % (time.time() - t_start))
        return 0

    except Exception as exc:  # noqa: BLE001 - a partial report beats no report
        report["warnings"].append("run aborted: %s: %s" % (type(exc).__name__, exc))
        checkpoint(final=False)
        sys.stderr.write("slim-measure: aborted: %s\n" % exc)
        return 1


def _sum_by(items, key):
    acc = {}
    for i in items:
        a = acc.setdefault(i[key], {"files": 0, "bytes": 0})
        a["files"] += 1
        a["bytes"] += i["bytes"]
    return sorted(({"reason": k, "files": v["files"], "bytes": v["bytes"]}
                   for k, v in acc.items()), key=lambda x: x["bytes"], reverse=True)


def _pillow_version():
    try:
        import PIL
        return PIL.__version__
    except ImportError:
        return None


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

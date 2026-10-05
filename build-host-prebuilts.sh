#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
#  build-host-prebuilts.sh — host (x86_64 focal) artifacts for Seren
#
#  Companion to build-jetson-prebuilts.sh (which handles the aarch64 Jetson
#  side). This one builds the artifacts the NON-Jetson host box needs -
#  currently just the NUC, which is pinned to Ubuntu 20.04 because NVIDIA SDK
#  Manager's host OS must match the LOWEST edge-device OS it flashes, and a
#  Xavier AGX is 20.04.
#
#  THE PROBLEM THIS SOLVES:
#    Ubuntu 20.04 ships:
#      - Python 3.8 (system) - too old; Seren needs 3.10+ for PEP 604/585
#      - libsqlite3 3.31     - too old; ChromaDB (SerenMemory) needs >= 3.35
#    deadsnakes no longer carries 3.10 for focal (focal aged out of their
#    support), so we build Python 3.10 from source. And that from-source
#    Python links the system libsqlite3 (3.31), so we ALSO build a modern
#    libsqlite3 that SerenMemory's service loads ahead of the system one
#    via LD_LIBRARY_PATH.
#
#  WHY NOT JUST DOCKER:
#    Considered, deferred deliberately. Going Docker for one service while
#    the rest of the stack is native means two deployment models to reason
#    about. That's a whole-stack decision for a future session, not a
#    thing to back into while solving a sqlite version floor. For now:
#    continuity with the prebuilt-artifact pattern already used for Jetson.
#
#  ARTIFACTS PRODUCED (staged into --output-dir):
#    python-3.10.14-focal-x86_64.tar.gz     (extracts to /usr/local)
#    libsqlite3-3.45.1-focal-x86_64.tar.gz  (extracts to /usr/local)
#    PROVENANCE-host-focal-x86_64.txt       the machine, the sources, the hashes
#    SHA256SUMS                             sha256sum -c SHA256SUMS
#    BUILD_INFO_host_focal.txt
#
#  Upstream tarballs are verified against lib/sources.sha256 before anything
#  compiles - same table, same rule as the Jetson script.
#
#  RELEASE TAG: YYYYMMDD_host-focal-x86_64  (the build date; see README)
#
#  Usage:
#    bash build-host-prebuilts.sh --all
#    bash build-host-prebuilts.sh --sqlite          # just sqlite
#    bash build-host-prebuilts.sh --python          # just python
#    bash build-host-prebuilts.sh --all --output-dir ./out --build-dir /tmp/b
# ══════════════════════════════════════════════════════════════════════
set -euo pipefail

# The verified fetch is shared with the Jetson script; it lives in lib/ beside
# this file. Said here rather than as "fetch_verified: command not found".
_HOST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$_HOST_ROOT/lib/fetch.sh" ] || { echo "this script needs lib/ beside it (lib/fetch.sh, lib/sources.sha256)" >&2; exit 1; }
# shellcheck source=lib/fetch.sh
source "$_HOST_ROOT/lib/fetch.sh"

# ── Versions (bump here, single source of truth) ──
PYTHON_VERSION="${PYTHON_VERSION:-3.10.14}"
SQLITE_VERSION="${SQLITE_VERSION:-3.45.1}"
# SQLite's download URL encodes the version as a zero-padded 7-digit number:
#   3.45.1 -> 3450100   (3, 45, 01, 00)
# Year in the path is the release year of that version. 3.45.x = 2024.
SQLITE_URL_VERSION="${SQLITE_URL_VERSION:-3450100}"
SQLITE_URL_YEAR="${SQLITE_URL_YEAR:-2024}"

# ── Defaults ──
OUTPUT_DIR="$(pwd)/host-prebuilts-out"
BUILD_DIR="$(pwd)/host-prebuilts-build"
MAX_JOBS="$(nproc)"
DO_PYTHON=false
DO_SQLITE=false

PLATFORM="focal-x86_64"  # this script is host-only; not auto-detected

log()  { echo -e "\033[0;36m[host-prebuilts]\033[0m $*"; }
warn() { echo -e "\033[0;33m[host-prebuilts] WARN:\033[0m $*" >&2; }
fail() { echo -e "\033[0;31m[host-prebuilts] FAIL:\033[0m $*" >&2; exit 1; }

# ── Arg parsing (while/case, matches the Jetson script's style) ──
while [ $# -gt 0 ]; do
    case "$1" in
        --all)        DO_PYTHON=true; DO_SQLITE=true ;;
        --python)     DO_PYTHON=true ;;
        --sqlite)     DO_SQLITE=true ;;
        --output-dir) OUTPUT_DIR="$2"; shift ;;
        --build-dir)  BUILD_DIR="$2"; shift ;;
        --max-jobs)   MAX_JOBS="$2"; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -50
            exit 0 ;;
        *) fail "unknown arg: $1 (try --help)" ;;
    esac
    shift
done

if ! $DO_PYTHON && ! $DO_SQLITE; then
    fail "nothing to do. pass --all, --python, and/or --sqlite (see --help)"
fi

# ── Sanity: this is meant for x86_64 focal ──
ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || warn "arch is $ARCH, not x86_64 - artifact names will still say x86_64; fix if that's wrong"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${VERSION_CODENAME:-}" = "focal" ] || warn "OS codename is '${VERSION_CODENAME:-unknown}', not focal - build will target the running system's libc regardless"
fi
if [ -f /etc/nv_tegra_release ]; then
    fail "this is a Jetson (found /etc/nv_tegra_release). Use build-jetson-prebuilts.sh, not the host script."
fi

mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
log "output:   $OUTPUT_DIR"
log "build:    $BUILD_DIR"
log "jobs:     $MAX_JOBS"
log "python:   $PYTHON_VERSION (build=$DO_PYTHON)"
log "sqlite:   $SQLITE_VERSION (build=$DO_SQLITE)"

INFO_FILE="$OUTPUT_DIR/BUILD_INFO_host_focal.txt"
{
    [ -s "$INFO_FILE" ] && echo ""
    echo "== run: $(basename "$0") $*"
    echo "Seren host prebuilts — build info"
    echo "built_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host_kernel: $(uname -r)"
    echo "host_arch: $ARCH"
    echo "host_os: ${PRETTY_NAME:-unknown}"
    echo "gcc: $(gcc --version 2>/dev/null | head -1 || echo 'n/a')"
} >> "$INFO_FILE"

# ── the records - same three the Jetson folders carry ──
# The host artifacts had no checksum file and no provenance at all: two
# tarballs and a build-info note, uploaded on trust. Same shape as the Jetson
# side now, appended per run, never truncated.
PROVENANCE="$OUTPUT_DIR/PROVENANCE-host-$PLATFORM.txt"
SUMS="$OUTPUT_DIR/SHA256SUMS"
if [ ! -s "$PROVENANCE" ]; then
    {
        echo "# SerenSystemPrebuilts provenance (host)"
        echo "# Everything below was read from the machine that did the build."
    } > "$PROVENANCE"
fi
{
    echo ""
    echo "# ══ run $(date -Iseconds) ══  $(basename "$0") $*"
    echo "built            $(date -Iseconds)"
    echo "host             $(uname -n)"
    echo "platform         $PLATFORM"
    echo "kernel           $(uname -r)"
    echo "os               ${PRETTY_NAME:-unknown}"
    echo "gcc              $(gcc --version 2>/dev/null | head -1 || echo absent)"
    echo "baseline python  $PYTHON_VERSION"
    echo "baseline sqlite  $SQLITE_VERSION"
} >> "$PROVENANCE"
touch "$SUMS"

# record_artifact - name, size, sha256; one SHA256SUMS line per path.
record_artifact() {
    local f="$1" sum rel tmp
    [ -f "$f" ] || return 0
    sum="$(sha256sum "$f" | awk '{print $1}')"
    rel="${f#"$OUTPUT_DIR"/}"
    printf 'artifact %-42s %s  %s\n' "$rel" "$(stat -c%s "$f")" "$sum" >> "$PROVENANCE"
    if grep -qF -- "  $rel" "$SUMS"; then
        tmp="$(mktemp)"
        awk -v p="$rel" 'index($0, "  " p) != length($0) - length(p) - 1 { print }' "$SUMS" > "$tmp"
        mv "$tmp" "$SUMS"
    fi
    printf '%s  %s\n' "$sum" "$rel" >> "$SUMS"
}

# ══════════════════════════════════════════════════════════════════════
#  SQLite — build FIRST if doing both, because we want Python to link
#  against the freshly-built libsqlite3 (not the system 3.31).
# ══════════════════════════════════════════════════════════════════════
build_sqlite() {
    log "── building libsqlite3 $SQLITE_VERSION ──"
    local src="$BUILD_DIR/sqlite-autoconf-$SQLITE_URL_VERSION"
    local tarball="$BUILD_DIR/sqlite.tar.gz"
    local url="https://www.sqlite.org/$SQLITE_URL_YEAR/sqlite-autoconf-$SQLITE_URL_VERSION.tar.gz"

    if [ ! -d "$src" ]; then
        local sha
        sha="$(fetch_verified "$url" "$tarball")"
        printf 'source %-14s %s\n' "sqlite" "$url" >> "$PROVENANCE"
        printf '       %-14s sha256 %s\n' "" "$sha" >> "$PROVENANCE"
        tar xzf "$tarball" -C "$BUILD_DIR"
    fi

    # Stage into a fakeroot so the tarball extracts cleanly to /usr/local.
    # We install to a staging prefix, then re-root the tar at usr/local.
    local stage="$BUILD_DIR/sqlite-stage"
    rm -rf "$stage"
    mkdir -p "$stage"

    pushd "$src" >/dev/null
    # Enable the column metadata + FTS that chroma-adjacent tooling may want;
    # these are cheap and broadly expected. Build a shared lib (default).
    ./configure --prefix=/usr/local \
        CFLAGS="-O2 -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_FTS5=1 -DSQLITE_ENABLE_JSON1=1"
    make -j"$MAX_JOBS"
    make install DESTDIR="$stage"
    popd >/dev/null

    # Verify the staged lib reports the version we expect.
    local staged_lib
    staged_lib="$(find "$stage" -name 'libsqlite3.so.0.*' | head -1)"
    [ -n "$staged_lib" ] || fail "staged libsqlite3.so.0.* not found after install"
    log "staged: $staged_lib"

    # Tar it rooted at usr/local so `tar xzf ... -C /` lands correctly.
    local out="$OUTPUT_DIR/libsqlite3-$SQLITE_VERSION-$PLATFORM.tar.gz"
    tar czf "$out" -C "$stage" usr/local
    record_artifact "$out"
    log "wrote $out"

    {
        echo ""
        echo "sqlite_version: $SQLITE_VERSION"
        echo "sqlite_lib: $(basename "$staged_lib")"
        echo "sqlite_configure: --prefix=/usr/local FTS5+JSON1+column_metadata"
    } >> "$INFO_FILE"
}

# ══════════════════════════════════════════════════════════════════════
#  Python — build from source, linking the freshly-built sqlite if present.
# ══════════════════════════════════════════════════════════════════════
build_python() {
    log "── building Python $PYTHON_VERSION ──"
    local src="$BUILD_DIR/Python-$PYTHON_VERSION"
    local tarball="$BUILD_DIR/python.tgz"
    local url="https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz"

    if [ ! -d "$src" ]; then
        local sha
        sha="$(fetch_verified "$url" "$tarball")"
        printf 'source %-14s %s\n' "python" "$url" >> "$PROVENANCE"
        printf '       %-14s sha256 %s\n' "" "$sha" >> "$PROVENANCE"
        tar xzf "$tarball" -C "$BUILD_DIR"
    fi

    # If we built sqlite this run, point the Python build at it so the
    # bundled _sqlite3 links the modern lib at BUILD time. This bakes the
    # newer sqlite into the tarball directly - then the host doesn't even
    # need LD_LIBRARY_PATH for sqlite. (We still ship the standalone
    # libsqlite3 artifact for belt-and-suspenders / other consumers.)
    local stage="$BUILD_DIR/python-stage"
    rm -rf "$stage"
    mkdir -p "$stage"

    local extra_cflags="" extra_ldflags="" run_path=""
    local sqlite_stage="$BUILD_DIR/sqlite-stage/usr/local"
    if [ -d "$sqlite_stage/lib" ]; then
        log "linking Python against freshly-built sqlite at $sqlite_stage"
        extra_cflags="-I$sqlite_stage/include"
        extra_ldflags="-L$sqlite_stage/lib"
        run_path="$sqlite_stage/lib"
    fi

    pushd "$src" >/dev/null
    # --enable-optimizations (PGO) makes a faster interpreter but a slower
    # build. Worth it for a prebuilt that's used for years. --enable-shared
    # NOT used: we want a self-contained /usr/local/bin/python3.10 that
    # doesn't depend on a libpython in a nonstandard place.
    LD_RUN_PATH="$run_path" \
    ./configure \
        --prefix=/usr/local \
        --enable-optimizations \
        --enable-loadable-sqlite-extensions \
        CFLAGS="${extra_cflags}" \
        LDFLAGS="${extra_ldflags}"
    LD_RUN_PATH="$run_path" make -j"$MAX_JOBS"
    # altinstall = installs python3.10 / pip3.10 WITHOUT clobbering the
    # system's `python3` / `python` symlinks. Critical - never want to
    # shadow the OS python.
    make altinstall DESTDIR="$stage"
    popd >/dev/null

    local out="$OUTPUT_DIR/python-$PYTHON_VERSION-$PLATFORM.tar.gz"
    tar czf "$out" -C "$stage" usr/local
    record_artifact "$out"
    log "wrote $out"

    # Report what sqlite the built python sees (only meaningful if we can
    # run it on this box - it's x86_64 so we can).
    local built_py="$stage/usr/local/bin/python3.10"
    if [ -x "$built_py" ]; then
        local sqlite_seen
        sqlite_seen="$(LD_LIBRARY_PATH="$run_path" "$built_py" -c 'import sqlite3; print(sqlite3.sqlite_version)' 2>/dev/null || echo 'unknown')"
        log "built python3.10 reports sqlite: $sqlite_seen"
        echo "" >> "$INFO_FILE"
        echo "python_version: $PYTHON_VERSION" >> "$INFO_FILE"
        echo "python_sqlite_at_build: $sqlite_seen" >> "$INFO_FILE"
    fi
}

# ── Order matters: sqlite before python so python can link it ──
$DO_SQLITE && build_sqlite
$DO_PYTHON && build_python

record_artifact "$INFO_FILE"
log "── done ──"
log "artifacts in $OUTPUT_DIR:"
ls -la "$OUTPUT_DIR"
log "records: $(basename "$PROVENANCE"), SHA256SUMS  (verify: cd $OUTPUT_DIR && sha256sum -c SHA256SUMS)"
log ""
log "next: upload this folder to a '$(date +%Y%m%d)_host-focal-x86_64' release tag on"
log "  github.com/ChadRoesler/SerenSystemPrebuilts and upload these."

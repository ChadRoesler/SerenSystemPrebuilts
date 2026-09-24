#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  The archive records, exercised without a GPU, a Jetson, or a network.
#
#  Sources lib/common.sh, lib/archive.sh and lib/fetch.sh into a throwaway
#  platform folder and proves:
#    - record_artifact keeps ONE SHA256SUMS line per path across re-records
#    - verify_checksums FAILS on a file that is present but unlisted
#      (the shipped archives passed sha256sum -c with 64 files unlisted)
#    - --reindex lists every file, appends provenance lines only for the
#      files it never recorded, keeps the old list, and then verifies clean
#    - fetch_verified refuses a pinned mismatch and warns on an unpinned URL
#
#  Run:  bash tests/test-archive-records.sh     (Git Bash on Windows is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAILS=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

GREEN=''; RED=''; YELLOW=''; BLUE=''; NC=''
log()  { :; }
warn() { echo "[warn] $1" >&2; }
info() { :; }
fail() { echo "[fail] $1" >&2; return 1; }
# The driver globals the library functions read.
KEEP_SOURCES=false
SEREN_SKIPPED=(); SEREN_BUILT=(); SEREN_FAILED=()
SEREN_ORIGINAL_ARGS=(--reindex)
PLATFORM_TAG=test; JP_FAMILY=jp0; CUDA_ARCH=0; PYTHON_VERSION=3.10.14
source "$HERE/lib/common.sh"
source "$HERE/lib/archive.sh"
source "$HERE/lib/fetch.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PREBUILT_DIR="$T"
PLATFORM_DIR="$T/test-jp0"; mkdir -p "$PLATFORM_DIR/wheelhouse" "$PLATFORM_DIR/apt-toolchain"
PROVENANCE="$PLATFORM_DIR/PROVENANCE-test-jp0.txt"
SOURCES_DIR="$PLATFORM_DIR/sources"
echo "# provenance" > "$PROVENANCE"

echo "── record_artifact merges per path ──"
echo "one" > "$PLATFORM_DIR/torch-1.whl"
record_artifact "$PLATFORM_DIR/torch-1.whl"
echo "one-rebuilt" > "$PLATFORM_DIR/torch-1.whl"
record_artifact "$PLATFORM_DIR/torch-1.whl"
check "one SHA256SUMS line for a re-recorded path" '[ "$(grep -c "  torch-1.whl$" "$PLATFORM_DIR/SHA256SUMS")" = 1 ]'
check "and it is the NEW hash" '( cd "$PLATFORM_DIR" && sha256sum -c --quiet SHA256SUMS )'
check "two provenance artifact lines (a log keeps history)" '[ "$(grep -c "^artifact torch-1.whl" "$PROVENANCE")" = 2 ]'
# a deb with apt's %3a in the name, in a subdirectory
echo "deb" > "$PLATFORM_DIR/apt-toolchain/git_1%3a2.34.1_arm64.deb"
record_artifact "$PLATFORM_DIR/apt-toolchain/git_1%3a2.34.1_arm64.deb"
check "subdirectory path is relative to the archive root" 'grep -q "  apt-toolchain/git_1%3a2.34.1_arm64.deb$" "$PLATFORM_DIR/SHA256SUMS"'

echo "── verify_checksums asks the second question ──"
check "an unsealed provenance is itself an unlisted file" '! verify_checksums "$PLATFORM_DIR" >/dev/null 2>&1'
seal_provenance
check "a fully listed, sealed folder verifies" 'verify_checksums "$PLATFORM_DIR" >/dev/null 2>&1'
echo "unlisted" > "$PLATFORM_DIR/wheelhouse/numpy-2.whl"
echo "unlisted too" > "$PLATFORM_DIR/llama-server-test"
check "an unlisted file FAILS verification" '! verify_checksums "$PLATFORM_DIR" >/dev/null 2>&1'
check "and both are named" '[ "$(archive_unlisted_files "$PLATFORM_DIR" | wc -l)" = 2 ]'
check "the provenance is exempt from nothing: it is a file too" 'archive_files "$PLATFORM_DIR" | grep -q "^PROVENANCE-test-jp0.txt$"'

echo "── reindex ──"
# simulate the truncation bug: a later run wiped the list down to one line
printf '%s  %s\n' "$(sha256sum "$PLATFORM_DIR/apt-toolchain/git_1%3a2.34.1_arm64.deb" | cut -d" " -f1)" "apt-toolchain/git_1%3a2.34.1_arm64.deb" > "$PLATFORM_DIR/SHA256SUMS"
printf '%s  %s\n' "deadbeef" "apt-toolchain/gone.deb" >> "$PLATFORM_DIR/SHA256SUMS"
reindex_archive >/dev/null 2>&1; rc=$?
check "reindex exits 0" '[ "$rc" = 0 ]'
check "every file is listed afterwards" '[ -z "$(archive_unlisted_files "$PLATFORM_DIR")" ]'
check "the stale listed-but-absent line is gone" '! grep -q "gone.deb" "$PLATFORM_DIR/SHA256SUMS"'
check "sha256sum -c passes on the rebuilt list" '( cd "$PLATFORM_DIR" && sha256sum -c --quiet SHA256SUMS )'
check "the old list was kept" 'ls "$PLATFORM_DIR"/SHA256SUMS.before-reindex-* >/dev/null 2>&1'
check "INSTALL.sh and NOTICES were generated and listed" 'grep -q "  INSTALL.sh$" "$PLATFORM_DIR/SHA256SUMS" && grep -q "  NOTICES$" "$PLATFORM_DIR/SHA256SUMS"'
check "NOTICES names the llama binary's license" 'grep -q "llama.cpp" "$PLATFORM_DIR/NOTICES"'
check "provenance gained a reindex stanza that says nothing was built" 'grep -q "^# ══ reindex" "$PROVENANCE" && grep -q "nothing was built" "$PROVENANCE"'
check "provenance gained artifact lines for the never-recorded files only" 'grep -q "^artifact wheelhouse/numpy-2.whl" "$PROVENANCE" && [ "$(grep -c "^artifact torch-1.whl" "$PROVENANCE")" = 2 ]'
check "the provenance's own line is last and current" '( cd "$PLATFORM_DIR" && sha256sum -c --quiet SHA256SUMS ) && tail -1 "$PLATFORM_DIR/SHA256SUMS" | grep -q "PROVENANCE-test-jp0.txt"'
check "reindex is idempotent" 'reindex_archive >/dev/null 2>&1 && ( cd "$PLATFORM_DIR" && sha256sum -c --quiet SHA256SUMS )'

echo "── fetch_verified ──"
SRC="$T/src"; mkdir -p "$SRC"
# curl on Windows (Git Bash) wants a native path in a file:// URL.
SRCURL="file://$(cygpath -m "$SRC" 2>/dev/null || echo "$SRC")"
echo "the real tarball" > "$SRC/good.tgz"
GOOD="$(sha256sum "$SRC/good.tgz" | cut -d" " -f1)"
export SEREN_SOURCES_TABLE="$T/sources.sha256"
printf '# test table\n%s  %s/good.tgz\n%s  %s/tampered.tgz\n' "$GOOD" "$SRCURL" "$GOOD" "$SRCURL" > "$SEREN_SOURCES_TABLE"
echo "not the real tarball" > "$SRC/tampered.tgz"
got="$(fetch_verified "$SRCURL/good.tgz" "$T/dl-good.tgz" 2>/dev/null)"
check "a pinned match downloads and returns the hash" '[ "$got" = "$GOOD" ] && [ -f "$T/dl-good.tgz" ]'
check "a pinned match already on disk is not refetched" 'fetch_verified "$SRCURL/good.tgz" "$T/dl-good.tgz" 2>&1 | grep -q "already present"'
if ( fetch_verified "$SRCURL/tampered.tgz" "$T/dl-bad.tgz" >/dev/null 2>&1 ); then bad "a pinned MISMATCH is refused"; else ok "a pinned MISMATCH is refused"; fi
check "and the bad file is not left behind" '[ ! -f "$T/dl-bad.tgz" ]'
echo "unpinned" > "$SRC/unpinned.tgz"
out="$(fetch_verified "$SRCURL/unpinned.tgz" "$T/dl-unpinned.tgz" 2>&1)"
check "an unpinned URL warns and still fetches" 'echo "$out" | grep -q "NO pin" && [ -f "$T/dl-unpinned.tgz" ]'
check "and writes the observed hash into the provenance" 'grep -q "NOT in lib/sources.sha256" "$PROVENANCE"'
check "the shipped table pins the three baselines" '[ "$(grep -cv "^#" "$HERE/lib/sources.sha256")" -ge 3 ] && grep -q "Python-3.10.14.tgz" "$HERE/lib/sources.sha256" && grep -q "Python-3.12.8.tgz" "$HERE/lib/sources.sha256" && grep -q "sqlite-autoconf-3450100" "$HERE/lib/sources.sha256"'

echo ""
echo "$PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]

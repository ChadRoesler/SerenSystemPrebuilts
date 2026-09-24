# ------------------------------------------------------------
# lib/fetch.sh - shared by build-jetson-prebuilts.sh AND build-host-prebuilts.sh
# Sourced; defines functions only, runs nothing.
# ------------------------------------------------------------
#
# ═════════════════════════════════════════════════════════════
# fetch_verified - an upstream tarball is checked, not trusted
# ═════════════════════════════════════════════════════════════
#
# Every source this repo compiles from python.org and sqlite.org arrived as a
# bare `wget` (Jetson) or `curl -fSL` (host): whatever bytes the server sent
# were what got built, and nothing wrote down what those bytes were. That is
# fine on a good day. On the day a mirror is stale, a CDN serves a truncated
# file, or an upstream quietly re-rolls a tarball under the same name, it is a
# twenty-hour build of something that is not the baseline - and there is no
# record to say so.
#
# So: download, hash, and look the URL up in lib/sources.sha256.
#   listed + match     -> "verified", carry on
#   listed + mismatch  -> REFUSE. The file is deleted so a re-run cannot pick
#                         it up by accident.
#   not listed         -> WARN, and write the observed hash into the
#                         provenance (when there is one) so it can be pinned
#                         deliberately next time. Refusing here would make
#                         bumping a baseline a two-run affair on a box where
#                         a run is a day; warning keeps the door open and the
#                         record honest.
#
# The table is content-addressed by URL, so the same line serves both scripts.

# Where the table lives, relative to whichever script sourced us. Overridable
# for tests.
SEREN_SOURCES_TABLE="${SEREN_SOURCES_TABLE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sources.sha256}"

_seren_have() { command -v "$1" >/dev/null 2>&1; }

# The tools log/warn/fail come from whichever script sourced this; provide
# quiet fallbacks so the file is usable on its own (tests, the host script).
# EVERYTHING GOES TO STDERR. fetch_verified's one stdout line is the hash, and
# callers capture it with $(...) - the driver's `log` prints to stdout, so
# routed there the caption would have landed inside the hash variable and the
# provenance would have recorded "[BUILD] fetching ..." as a checksum.
_seren_log()  { if declare -F log  >/dev/null; then log  "$@" >&2; else echo "[fetch] $*" >&2; fi; }
_seren_warn() { if declare -F warn >/dev/null; then warn "$@" >&2; else echo "[fetch] WARN: $*" >&2; fi; }
_seren_fail() { if declare -F fail >/dev/null; then fail "$@"; else echo "[fetch] FAIL: $*" >&2; exit 1; fi; }

# pinned_sha256_for URL -> prints the pinned hash, or nothing
pinned_sha256_for() {
    local url="$1"
    [ -f "$SEREN_SOURCES_TABLE" ] || return 0
    awk -v u="$url" '$0 !~ /^[[:space:]]*#/ && NF >= 2 && $2 == u { print $1; exit }' "$SEREN_SOURCES_TABLE"
}

# fetch_verified URL DEST
#   Downloads URL to DEST (a file path), verifies against the table, and
#   prints the sha256 it observed. Exit 1 on a listed mismatch.
fetch_verified() {
    local url="$1" dest="$2"
    local want got
    want="$(pinned_sha256_for "$url")"

    # A re-run that already has the right bytes need not fetch again. Only
    # when it is pinned, though: an unpinned leftover is exactly the thing
    # that should be re-fetched.
    if [ -n "$want" ] && [ -f "$dest" ]; then
        got="$(sha256sum "$dest" | awk '{print $1}')"
        if [ "$got" = "$want" ]; then
            _seren_log "source already present and verified: $(basename "$dest")"
            echo "$got"
            return 0
        fi
        _seren_warn "$(basename "$dest") is present but does not match its pin - refetching"
        rm -f "$dest"
    fi

    _seren_log "fetching $url"
    if _seren_have curl; then
        curl -fSL --retry 3 -o "$dest" "$url" || _seren_fail "could not fetch $url"
    elif _seren_have wget; then
        wget -q --show-progress -O "$dest" "$url" || _seren_fail "could not fetch $url"
    else
        _seren_fail "neither curl nor wget is installed; cannot fetch $url"
    fi
    [ -s "$dest" ] || _seren_fail "fetched an empty file from $url"

    got="$(sha256sum "$dest" | awk '{print $1}')"
    if [ -n "$want" ]; then
        if [ "$got" != "$want" ]; then
            rm -f "$dest"
            _seren_fail "CHECKSUM MISMATCH for $(basename "$dest")
  url:      $url
  expected: $want   (lib/sources.sha256)
  got:      $got
  The bytes the server sent are not the bytes this baseline was built from.
  Nothing has been built. If the upstream genuinely re-issued the file, update
  the pin on purpose; do not build on a tarball you cannot account for."
        fi
        _seren_log "verified $(basename "$dest") against lib/sources.sha256 ✓"
    else
        _seren_warn "$(basename "$dest") has NO pin in lib/sources.sha256 - fetched unverified."
        _seren_warn "  observed sha256 $got"
        _seren_warn "  Add this line to pin it:   $got  $url"
        # Into the provenance when a build is running, so the record carries the
        # hash even if nobody acts on the warning.
        if [ -n "${PROVENANCE:-}" ] && [ -f "$PROVENANCE" ]; then
            printf 'source   %-14s %s\n' "unpinned" "$url" >> "$PROVENANCE"
            printf '         %-14s sha256 %s (NOT in lib/sources.sha256 - pin it)\n' "" "$got" >> "$PROVENANCE"
        fi
    fi
    echo "$got"
}

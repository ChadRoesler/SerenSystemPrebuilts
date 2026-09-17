# ------------------------------------------------------------
# lib/common.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

log()  { echo -e "${GREEN}[BUILD]${NC} $1"; }

warn() { echo -e "${YELLOW}[BUILD]${NC} $1"; }

fail() { echo -e "${RED}[BUILD]${NC} $1"; exit 1; }

info() { echo -e "${BLUE}[BUILD]${NC} $1"; }

# record_source - the single most important line in this file.
#
# `git clone` with no ref gives you whatever HEAD was that minute, and nothing
# anywhere says which minute. llama.cpp and gasket-driver were both cloned that
# way, so neither artifact was reproducible even in principle. Resolving HEAD to
# a SHA and writing it down costs nothing and is the difference between "we
# shipped a binary" and "we can ship that binary again".
record_source() {
    local name="$1" dir="$2"
    local url sha date
    url="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || echo unknown)"
    sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)"
    date="$(git -C "$dir" log -1 --format=%cI 2>/dev/null || echo unknown)"
    printf 'source %-14s %s\n' "$name" "$url" >> "$PROVENANCE"
    printf '       %-14s commit %s (%s)\n' "" "$sha" "$date" >> "$PROVENANCE"
    log "$name source: ${sha:0:12} ($date)"

    # --keep-sources: the tree itself, at that commit, with .git stripped.
    # If the upstream repo disappears or rewrites history, this is the only
    # remaining way to rebuild. It is opt-in because it is not small.
    if $KEEP_SOURCES; then
        mkdir -p "$SOURCES_DIR"
        local out="$SOURCES_DIR/${name}-${sha:0:12}.tar.gz"
        if [ -f "$out" ]; then
            log "  source snapshot already present: $(basename "$out")"
        else
            tar --exclude-vcs -czf "$out" -C "$(dirname "$dir")" "$(basename "$dir")" \
                && log "  source snapshot: $(basename "$out") ($(du -h "$out" | cut -f1))" \
                || warn "  could not snapshot $name sources"
        fi
    fi
}

note_skip() {
    SEREN_SKIPPED+=("$1|$2")
    printf 'skipped  %-14s %s\n' "$1" "$2" >> "$PROVENANCE"
}

note_built() { SEREN_BUILT+=("$1"); }

# note_fail - A FAILURE IS NOT A SKIP, and the archive has to say which it was.
#
# note_skip means "this was not attempted, and here is the reason" - a Volta box
# that vLLM has no kernels for, a dependency that is not installed. It is a
# deliberate hole. note_fail means "this was attempted and it broke", which is
# the thing you actually have to go and look at. Both end with the artifact
# absent, and collapsing them into one list is how you end up scrolling past a
# genuine build failure because it was sitting in a column of expected ones.
note_fail() {
    SEREN_FAILED+=("$1|$2")
    printf 'FAILED   %-14s %s\n' "$1" "$2" >> "$PROVENANCE"
}

# record_artifact - name, size and sha256, written as each artifact lands
# rather than swept up at the end, so a run that dies halfway still leaves an
# honest record of what it did produce.
record_artifact() {
    local f="$1"
    [ -f "$f" ] || return 0
    local sum; sum="$(sha256sum "$f" | awk '{print $1}')"
    # PATH RELATIVE TO THE ARCHIVE ROOT, NOT THE BASENAME. This wrote basenames
    # and it made SHA256SUMS a lie: vendor wheels live in vendor/, so
    # `sha256sum -c SHA256SUMS` reported "No such file or directory" for every
    # one of them. A checksum file that does not check is worse than no
    # checksum file, because it looks like diligence.
    local rel="${f#"$PLATFORM_DIR"/}"
    printf 'artifact %-52s %s  %s\n' "$rel" "$(stat -c%s "$f")" "$sum" >> "$PROVENANCE"
    printf '%s  %s\n' "$sum" "$rel" >> "$PLATFORM_DIR/SHA256SUMS"
}

# ═════════════════════════════════════════════════════════════
# clone_or_reuse - a failed build should cost the failure, not the build
# ═════════════════════════════════════════════════════════════
#
# EVERY LONG PHASE OPENED WITH `rm -rf <tree>`, which means any failure at
# object 2250 of 3435 - a bad flag, an OOM, a Ctrl-C, a compiler that chokes on
# one translation unit - threw away every object that had already compiled and
# started again from the clone. Three hours, deleted, to fix a one-line flag.
#
# That is exactly backwards for this script. The state file already treats
# whole phases as resumable; ninja already knows how to continue an interrupted
# build from its own object timestamps. The only thing standing between those
# two facts was an `rm -rf` at the top.
#
# So: if the tree is already checked out at the ref we want, keep it and let
# ninja resume. If it is at a DIFFERENT ref, it is not the tree we want and it
# goes - a stale tree silently reused is how you ship a wheel built from the
# wrong source. Deleting the directory by hand is still the way to force a
# genuinely clean build, and the log says so.
clone_or_reuse() {
    local dir="$1" ref="$2" url="$3"; shift 3
    local have=""
    if [ -d "$dir/.git" ]; then
        have="$(git -C "$dir" describe --tags --exact-match 2>/dev/null || true)"
    fi
    if [ -n "$have" ] && [ "$have" = "$ref" ]; then
        log "reusing $dir already at $ref - an interrupted build resumes here"
        log "  (rm -rf $BUILD_DIR/$dir to force a clean rebuild)"
        return 0
    fi
    [ -n "$have" ] && warn "$dir is at $have but $ref is wanted - recloning"
    rm -rf "$dir"
    git clone "$@" --branch "$ref" --depth 1 "$url" "$dir"
}

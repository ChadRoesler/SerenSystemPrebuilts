# ------------------------------------------------------------
# phases/wheelhouse.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# wheelhouse - the dependency closure, built HERE, for this box
# ═════════════════════════════════════════════════════════════
#
# WHAT WAS MISSING FROM THIS ARCHIVE, and it is the part the premise depends on.
# A torch wheel is not installable on its own: pip goes to the index for
# filelock, sympy, networkx, jinja2, fsspec, typing-extensions, mpmath. Every
# one of those is a live repository serving a file somebody else has to keep
# serving - the exact dependency this repo exists to remove. An archive holding
# the four-hour build and none of the five-second downloads is an archive that
# fails on the day it is needed.
#
# pip wheel, NOT pip download, and the difference is the whole point on aarch64:
# plenty of these have no published wheel for this arch/interpreter and pip
# would archive an sdist you must compile later, on a box that may no longer
# have a compiler or the headers. `pip wheel` compiles them now, here, into
# something that installs with --no-index in four years.
build_wheelhouse() {
    use_venv wheelhouse "$CMAKE_MIN_TORCH"
    local WH="$PLATFORM_DIR/wheelhouse"
    mkdir -p "$WH"

    # ── seed with what this archive already built ──
    # So resolution finds the local sm_${CUDA_ARCH} torch instead of fetching a
    # generic one from an index that has never heard of this GPU.
    local w seeded=0
    for w in "$PLATFORM_DIR"/torch-*.whl "$PLATFORM_DIR"/torchvision-*.whl \
             "$PLATFORM_DIR"/bitsandbytes-*.whl; do
        [ -f "$w" ] || continue
        cp -n "$w" "$WH/" 2>/dev/null || true
        seeded=$((seeded + 1))
    done
    log "seeded the wheelhouse with $seeded locally built wheel(s)"

    # ── constraints: THE ARCHIVE'S PINS WIN ──
    # Without this, any requirement of the form torch>=2.x lets pip resolve to
    # whatever the index offers today, and the closure gets built against a
    # torch this box does not have. The pins are the baseline, so they are the
    # constraint.
    local CONS="$TMPDIR/seren-wheelhouse-constraints.txt"
    : > "$CONS"
    [ -n "$PYTORCH_VERSION" ]     && echo "torch==${PYTORCH_VERSION}" >> "$CONS"
    [ -n "$TORCHVISION_VERSION" ] && echo "torchvision==${TORCHVISION_VERSION}" >> "$CONS"
    echo "numpy==${NUMPY_RUNTIME_VERSION}" >> "$CONS"

    # ── what to close over ──
    #
    # THE DEFAULT LIST IS SHORT ON PURPOSE. It closes over what THIS ARCHIVE
    # BUILT, plus the trio a fresh interpreter needs before it can install
    # anything at all. That is the set this script can honestly claim to know.
    # Your application's pins live in your application's repo - pass them with
    # --wheelhouse-reqs. A made-up list of twenty packages in here would drift
    # out of date and quietly misrepresent what the archive contains.
    local REQS=() p
    for p in $WHEELHOUSE_PKGS; do REQS+=("$p"); done
    if [ -n "$WHEELHOUSE_REQS" ]; then
        [ -f "$WHEELHOUSE_REQS" ] || fail "--wheelhouse-reqs: no such file: $WHEELHOUSE_REQS"
        REQS+=(-r "$WHEELHOUSE_REQS")
        log "including requirements from $WHEELHOUSE_REQS"
    else
        warn "no --wheelhouse-reqs given - closing over this archive's own artifacts only."
        warn "  Point it at the requirements/pyproject of whatever actually runs on"
        warn "  this box to archive that dependency closure too. That is the part"
        warn "  which disappears from PyPI, not torch."
    fi
    for w in "$WH"/torch-*.whl "$WH"/torchvision-*.whl "$WH"/bitsandbytes-*.whl; do
        [ -f "$w" ] && REQS+=("$w")
    done

    log "Building the dependency closure (compiles anything without an aarch64 wheel)..."
    "$PYBIN" -m pip wheel --wheel-dir "$WH" --find-links "$WH" -c "$CONS" "${REQS[@]}" \
        || { warn "pip wheel did not complete - the wheelhouse may be partial"
             note_skip wheelhouse "pip wheel failed; see the log above"; }

    # ── the lock file, produced by an ACTUAL OFFLINE INSTALL ──
    # Not `pip freeze` of the build venv, which would describe the machine that
    # built it. This installs from the wheelhouse with the index switched off -
    # so producing the lock file IS the proof that the wheelhouse can restore
    # itself, and a failure here is a finding rather than a formality.
    local LOCK="$PLATFORM_DIR/requirements-${PLATFORM_TAG}-${JP_FAMILY}.lock"
    local LOCKVENV="$VENV_ROOT/wheelhouse-lock"
    rm -rf "$LOCKVENV"
    local targets=()
    for w in "$WH"/torch-*.whl "$WH"/torchvision-*.whl "$WH"/bitsandbytes-*.whl; do
        [ -f "$w" ] && targets+=("$w")
    done
    if [ ${#targets[@]} -gt 0 ] && "$HOST_PYBIN" -m venv "$LOCKVENV" 2>/dev/null; then
        if "$LOCKVENV/bin/python" -m pip install -q --no-index --find-links "$WH" "${targets[@]}"; then
            "$LOCKVENV/bin/python" -m pip freeze > "$LOCK"
            record_artifact "$LOCK"
            log "offline restore rehearsed OK -> $(basename "$LOCK")"
        else
            warn "the wheelhouse could NOT install itself offline - it is incomplete."
            warn "  That is the one thing this phase exists to guarantee. Re-run with"
            warn "  --wheelhouse-reqs listing everything you actually need."
            note_skip wheelhouse "offline install rehearsal failed"
        fi
        rm -rf "$LOCKVENV"
    fi

    # ── a note that travels with the wheels ──
    {
        echo "# How to restore this, with no network and no index."
        echo "#"
        echo "#   python${PYTHON_VERSION%.*} -m venv ~/venv && . ~/venv/bin/activate"
        echo "#   pip install --no-index --find-links . -r ../$(basename "$LOCK")"
        echo "#"
        echo "# Built $(date -Iseconds) on $(uname -n) for ${PLATFORM_TAG}/${JP_FAMILY}, ${PYTAG}."
        echo "# These are compiled for sm_${CUDA_ARCH}. They are not interchangeable with"
        echo "# wheels of the same name from any other box in this fleet."
    } > "$WH/README.txt"

    local count size
    count=$(ls -1 "$WH"/*.whl 2>/dev/null | wc -l)
    size=$(du -sh "$WH" 2>/dev/null | cut -f1)
    log "wheelhouse: $count wheels, $size"
    echo "wheelhouse       $count wheels, $size" >> "$PROVENANCE"
    echo "wheelhouse: $count wheels ($size)" >> "$BUILD_INFO"

    # Every wheel gets a checksum. That is a long SHA256SUMS and it is the point:
    # a file separated from this folder can still be identified.
    for w in "$WH"/*.whl "$WH/README.txt"; do
        [ -f "$w" ] && record_artifact "$w"
    done
    [ "$count" -gt 0 ] && note_built wheelhouse
    cd ~
}

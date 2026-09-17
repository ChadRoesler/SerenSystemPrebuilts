# ------------------------------------------------------------
# phases/vendor.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# Vendor binaries - mirrored, not built
# ═════════════════════════════════════════════════════════════
#
# WHY THIS EXISTS, AND WHY REFUSING TO BUILD TORCH ON THE SPARK WAS ONLY HALF
# AN ANSWER. "NVIDIA ships JP7 wheels, so we do not build them" is correct
# engineering advice and the wrong policy for an archive, because the premise
# of this repo is that live repositories drop things. NVIDIA's redist IS a live
# repository. A Spark archive with no torch in it is a Spark archive that does
# not work the day that index reorganises.
#
# Building torch from source on a Spark to fix that would be hours of compute
# producing something subtly different from what the box actually runs. So it
# is MIRRORED instead: the exact wheel this machine is using, copied into the
# archive with its checksum and the index it came from.
#
# THE URL IS NOT HARDCODED, deliberately. This script does not know NVIDIA's
# layout and has no business guessing at it - the box already has an index
# configured (that is how these got installed), so pip is asked to fetch what
# is installed and the resolved index is written into the provenance.

build_vendor() {
    local VENDOR_DIR="$PLATFORM_DIR/vendor"
    mkdir -p "$VENDOR_DIR"
    log "Mirroring vendor wheels this box depends on but does not build..."
    use_venv vendor

    # ── explicit wheels first: the path that cannot fail to find anything ──
    # A file or URL the operator names outright. No discovery, no index, no
    # assumption about where torch lives. If everything else here is wrong,
    # this still puts the right bits in the archive.
    local w
    for w in $VENDOR_WHEELS; do
        if [ -f "$w" ]; then
            cp "$w" "$VENDOR_DIR/" && log "  copied $(basename "$w")"
            echo "vendor   file://$w" >> "$PROVENANCE"
        elif curl -fsSL --retry 2 -o "$VENDOR_DIR/$(basename "${w%%\?*}")" "$w"; then
            log "  downloaded $(basename "${w%%\?*}")"
            echo "vendor   $w" >> "$PROVENANCE"
        else
            warn "  could not obtain $w"
            note_skip "vendor:$(basename "$w")" "not a readable file and not downloadable"
        fi
    done

    # ── find the interpreter that ACTUALLY has these packages ──
    #
    # THE BUG THIS REPLACES: it looked only in $PYBIN, the system interpreter,
    # and reported "torch not installed for python3.12" on a Spark that runs
    # torch every day - because Seren gives every node component its OWN venv
    # (~/seren-venvs/msmoe), which is where the NVIDIA wheel actually lives.
    # Asking one interpreter and declaring the package absent is the same
    # mistake as asserting a gap without checking for it.
    local cands=("$PYBIN")
    [ -n "$VENDOR_PYTHON" ] && cands=("$VENDOR_PYTHON" "${cands[@]}")
    local v
    # THIS SCRIPT'S OWN PHASE VENVS COUNT TOO. The pytorch phase installs the
    # wheel it just built into $VENV_ROOT/pytorch, so on a --all run that is
    # the interpreter which actually has the version this archive holds.
    for v in "$VENV_ROOT"/*/bin/python \
             "$HOME"/seren-venvs/*/bin/python /mnt/nvme/seren-venvs/*/bin/python \
             /home/*/seren-venvs/*/bin/python; do
        [ -x "$v" ] && cands+=("$v")
    done

    local pkg ver base found idx_args=()
    [ -n "$VENDOR_INDEX" ] && idx_args=(--extra-index-url "$VENDOR_INDEX")

    for pkg in $VENDOR_PKGS; do
        ver=""; found=""
        for v in "${cands[@]}"; do
            [ -x "$v" ] || continue
            ver="$("$v" -c "import $pkg; print($pkg.__version__)" 2>/dev/null || true)"
            [ -n "$ver" ] && { found="$v"; break; }
        done

        # A PINNED VERSION BEATS DISCOVERY, because the point is a HELD copy.
        # --vendor-<pkg>-version (or the platform default) says which one the
        # archive should contain regardless of what happens to be installed.
        local pinned=""
        case "$pkg" in
            torch)       pinned="$VENDOR_TORCH_VERSION" ;;
            torchvision) pinned="$VENDOR_TVISION_VERSION" ;;
        esac
        [ -n "$pinned" ] && ver="$pinned"

        if [ -z "$ver" ]; then
            warn "  $pkg: not installed under any interpreter I can see, and not pinned"
            warn "    looked in: ${cands[*]}"
            warn "    fix with:  --vendor-${pkg}-version X.Y.Z  (with --vendor-index if"
            warn "               it lives somewhere other than PyPI), or --vendor-wheel PATH"
            note_skip "vendor:$pkg" "not installed anywhere visible and no version pinned"
            continue
        fi
        [ -n "$found" ] && log "  $pkg $ver (found via $found)" || log "  $pkg $ver (pinned)"

        base="${ver%%+*}"
        if "$PYBIN" -m pip download --no-deps -q "${idx_args[@]}" "$pkg==$ver" -d "$VENDOR_DIR" 2>/dev/null; then
            echo "vendor   $pkg==$ver (exact)" >> "$PROVENANCE"
        elif "$PYBIN" -m pip download --no-deps -q "${idx_args[@]}" "$pkg==$base" -d "$VENDOR_DIR" 2>/dev/null; then
            warn "  the index would not serve $ver; mirrored $base instead"
            echo "vendor   $pkg==$base (wanted $ver - LOCAL SEGMENT NOT MIRRORED)" >> "$PROVENANCE"
        else
            # LAST RESORT, AND IT IS A GOOD ONE: if the index will not serve it
            # but the package is installed, the files are right there. A wheel
            # rebuilt from an install is not byte-identical to the vendor's, and
            # it IS the code this machine runs - which is what an archive is for.
            if [ -n "$found" ] && "$PYBIN" -m pip wheel --no-deps -q "$pkg==$ver" -w "$VENDOR_DIR" 2>/dev/null; then
                warn "  index would not serve $pkg; rebuilt a wheel from the install"
                echo "vendor   $pkg==$ver (REBUILT from installed files, not vendor bytes)" >> "$PROVENANCE"
            else
                warn "  could not obtain $pkg==$ver from any index"
                [ -n "$VENDOR_INDEX" ] || warn "    try --vendor-index https://developer.download.nvidia.com/compute/redist/jp/"
                note_skip "vendor:$pkg" "no index served $pkg==$ver"
                continue
            fi
        fi
    done

    local idx; idx="$("$PYBIN" -m pip config list 2>/dev/null | grep -i "index-url" | head -1 || true)"
    echo "vendor   index: ${VENDOR_INDEX:-${idx:-<pip default / PyPI>}}" >> "$PROVENANCE"

    local f any=false
    for f in "$VENDOR_DIR"/*.whl "$VENDOR_DIR"/*.tar.gz; do
        [ -e "$f" ] || continue
        record_artifact "$f"; any=true
    done
    $any && note_built vendor || warn "Nothing mirrored."
    cd ~
}

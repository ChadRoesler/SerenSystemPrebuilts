# ------------------------------------------------------------
# phases/torchvision.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# torchvision (version pinned per platform - see detect_platform)
# ═════════════════════════════════════════════════════════════
build_torchvision() {
    [ -n "$TORCHVISION_VERSION" ] || fail "TORCHVISION_VERSION is unset for $PLATFORM_TAG/$JP_FAMILY"
    log "Building torchvision ${TORCHVISION_VERSION} ${PYTAG} (${PLATFORM_TAG}, arch $TORCH_ARCH_LIST)..."
    use_venv torchvision "$CMAKE_MIN_TORCH"

    # torchvision compiles against torch's headers and links its libs, so the
    # torch in THIS venv is the one the wheel is permanently bound to.
    # ensure_torch prefers the wheel this archive just built over anything an
    # index would serve - on these GPUs that distinction is the whole game.
    ensure_torch "$PYTORCH_VERSION" || \
        fail "torchvision needs torch ${PYTORCH_VERSION} and none could be installed.
  Run --pytorch first (the same run is fine - the phase table orders it), or
  drop a matching wheel into $PLATFORM_DIR."
    "$PYBIN" -c "import torch; print('torch:', torch.__version__)"

    # ── THE SAME NUMPY THAT BUILT TORCH, FOR THE SAME REASON ──
    # build_pytorch treats this pin as load-bearing and re-asserts it after
    # requirements.txt; torchvision compiles against that same torch and was
    # getting no numpy at all, which torch announced on the way past:
    #   UserWarning: Failed to initialize NumPy: No module named 'numpy'
    # A vision wheel built against a torch whose array interop was disabled at
    # compile time is not the wheel this archive is supposed to hold.
    "$PYBIN" -m pip install -q "numpy==${NUMPY_BUILD_VERSION}" \
        || warn "  numpy ${NUMPY_BUILD_VERSION} would not install - continuing, but torch will warn"
    log "numpy in this venv: $("$PYBIN" -c 'import numpy; print(numpy.__version__)' 2>/dev/null || echo absent)"

    export TORCH_CUDA_ARCH_LIST="$TORCH_ARCH_LIST"
    export CMAKE_POLICY_VERSION_MINIMUM=3.5
    export MAX_JOBS="$RESOLVED_MAX_JOBS"

    cd "$BUILD_DIR"
    clone_or_reuse torchvision "v${TORCHVISION_VERSION}" https://github.com/pytorch/vision
    record_source torchvision "$PWD/torchvision"
    cd torchvision
    "$PYBIN" setup.py bdist_wheel

    local WHEEL; WHEEL=$(ls dist/torchvision-*.whl 2>/dev/null | head -1)
    [ -z "$WHEEL" ] && fail "torchvision build failed - no wheel produced"

    cp "$WHEEL" "$PLATFORM_DIR/"
    record_artifact "$PLATFORM_DIR/$(basename "$WHEEL")"
    echo "torchvision: $(basename "$WHEEL")" >> "$BUILD_INFO"
    log "torchvision wheel saved → $PLATFORM_DIR/$(basename "$WHEEL") ✓"

    # The "restore numpy to runtime version" line that used to sit here is gone
    # with the shared venv it existed for: nothing else reads this interpreter,
    # so there is nothing to restore it for. NUMPY_RUNTIME_VERSION is advice for
    # the INSTALL side, and it is written into the provenance for exactly that.
    cd ~
}

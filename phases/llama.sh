# ------------------------------------------------------------
# phases/llama.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# llama.cpp
# ═════════════════════════════════════════════════════════════
build_llama() {
    log "Building llama-server (${PLATFORM_TAG}, arch $CUDA_ARCH)..."
    # A VENV FOR A C++ BUILD, which reads as overkill until you remember where
    # cmake comes from on Ubuntu 20.04: 3.16.3, which llama.cpp's CUDA
    # subdirectory rejects. ensure_cmake pip-installs a modern one INTO this
    # venv, so the cmake on PATH here is this phase's and nobody else's.
    use_venv llama 3.18
    # $BUILD_DIR, NOT $HOME. Every other phase was moved off the eMMC for space
    # and this one was still cloning 430MB plus objects into ~ on a Xavier
    # whose entire root filesystem is 32GB.
    cd "$BUILD_DIR"
    rm -rf llama.cpp
    # PINNABLE, AND RECORDED EITHER WAY. This was a bare `git clone` with no
    # ref and no depth - so the binary came from whatever master happened to be
    # that minute, and nothing recorded which minute. --llama-ref pins it;
    # record_source writes the resolved SHA down regardless, which is what makes
    # the artifact reproducible instead of merely reproduced-once.
    if [ -n "$USER_LLAMA_REF" ]; then
        git clone https://github.com/ggml-org/llama.cpp
        git -C llama.cpp checkout --quiet "$USER_LLAMA_REF" \
            || fail "llama.cpp: no such ref '$USER_LLAMA_REF'"
        log "llama.cpp pinned to $USER_LLAMA_REF"
    else
        git clone https://github.com/ggml-org/llama.cpp
        warn "llama.cpp is UNPINNED (master HEAD). The exact commit is recorded"
        warn "  in the provenance file; pass --llama-ref to reproduce this build."
    fi
    record_source llama.cpp "$PWD/llama.cpp"
    cd llama.cpp

    # Build ONLY the server target. llama.cpp builds its full test suite +
    # every example by default - none of which we ship. Those test binaries
    # are what actually filled /tmp and died (llama-server itself had
    # already linked by then). Skipping them makes the build faster, smaller,
    # and removes the disk-pressure failure entirely.
    cmake -B build \
        -DGGML_CUDA=ON \
        -DGGML_CUDA_F16=on \
        -DGGML_CUDA_FA_ALL_QUANTS=ON \
        -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
        -DBUILD_SHARED_LIBS=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_SERVER=ON
    # Build just the server target - not the "all" target. This is the only
    # artifact we package, and it pulls in exactly the libs it needs.
    cmake --build build --config Release -j"$(nproc)" --target llama-server

    [ -f build/bin/llama-server ] || fail "llama.cpp build failed"

    # Guard: refuse to ship a binary that still has shared llama/ggml deps.
    # BUILD_SHARED_LIBS=OFF should make this impossible, but a future
    # llama.cpp change could reintroduce a shared sub-target. Fail at BUILD
    # time, not at the buddy's launch time.
    if ldd build/bin/llama-server 2>/dev/null | grep -qiE "libllama|libggml|libmtmd"; then
        ldd build/bin/llama-server | grep -iE "libllama|libggml|libmtmd" >&2
        fail "llama-server still has shared llama/ggml deps - static link didn't take. Refusing to ship incomplete binary."
    fi

    local OUT="$PLATFORM_DIR/llama-server-${JP_FAMILY}-${PLATFORM_TAG}-aarch64"
    cp build/bin/llama-server "$OUT"
    chmod +x "$OUT"

    record_artifact "$OUT"

    local LLAMA_VER; LLAMA_VER=$(./build/bin/llama-server --version 2>&1 | head -1 || echo "unknown")
    echo "llama.cpp: $LLAMA_VER → $(basename "$OUT")" >> "$BUILD_INFO"
    echo "note   llama-server --version says: $LLAMA_VER" >> "$PROVENANCE"
    log "llama.cpp built → $OUT ✓"
    cd ~
}

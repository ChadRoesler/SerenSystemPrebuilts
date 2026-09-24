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
    # PINNED BY DEFAULT, AND RECORDED EITHER WAY. This was a bare `git clone`
    # with no ref - the binary came from whatever master happened to be that
    # minute. It gained --llama-ref, and then the default stayed "that minute",
    # so every build that did not think to pass the flag was still
    # unreproducible by construction. The default is now the commit in
    # lib/pins.sh; `--llama-ref latest` is the explicit way to chase HEAD.
    # record_source writes the resolved SHA down regardless.
    git clone https://github.com/ggml-org/llama.cpp
    if [ -n "$LLAMA_REF" ]; then
        git -C llama.cpp checkout --quiet "$LLAMA_REF" \
            || fail "llama.cpp: no such ref '$LLAMA_REF'"
        log "llama.cpp pinned to $LLAMA_REF"
    else
        warn "llama.cpp is UNPINNED (--llama-ref latest): master HEAD as of now."
        warn "  The exact commit is recorded in the provenance; pin it there next time."
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

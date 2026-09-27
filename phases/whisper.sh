# ------------------------------------------------------------
# phases/whisper.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# whisper.cpp - speech to text on the node
# ═════════════════════════════════════════════════════════════
#
# WHY A BUILD, when Kokoro is only a pip install. Kokoro rides the torch wheel
# this archive already builds; a PyTorch whisper would too, but it would drag
# a gigabyte of CUDA libraries into memory next to llama-server on an 8GB
# Orin Nano. whisper.cpp is llama.cpp's sibling - the same ggml, the same
# CMake switches, the same CUDA arch - so this phase is llama.sh with the
# names changed, and it ships one static binary the node only has to copy
# (Design note: "if we dont have to build whisper we wont... but if
# they are similar enough we are kosher").
#
# whisper-server answers multipart POSTs on --inference-path; the node
# installer points that at /v1/audio/transcriptions, so an OpenAI-style
# client can talk to it.
build_whisper() {
    log "Building whisper-server (${PLATFORM_TAG}, arch $CUDA_ARCH)..."
    # The same modern-cmake venv reason as llama.sh: 20.04 ships 3.16.
    use_venv whisper 3.18
    cd "$BUILD_DIR"
    rm -rf whisper.cpp
    # Pinned by default, recorded either way - the llama.cpp story, in
    # lib/pins.sh. `--whisper-ref latest` follows master HEAD.
    git clone https://github.com/ggml-org/whisper.cpp
    if [ -n "$WHISPER_REF" ]; then
        git -C whisper.cpp checkout --quiet "$WHISPER_REF" \
            || fail "whisper.cpp: no such ref '$WHISPER_REF'"
        log "whisper.cpp pinned to $WHISPER_REF"
    else
        warn "whisper.cpp is UNPINNED (--whisper-ref latest): master HEAD as of now."
        warn "  The exact commit is recorded in the provenance; pin it there next time."
    fi
    record_source whisper.cpp "$PWD/whisper.cpp"
    cd whisper.cpp

    # The server lives under examples/, so examples stay ON; tests stay off.
    # Only the whisper-server target is built - the "all" target would compile
    # every example and fill /tmp the way llama.cpp's test suite once did.
    cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
        -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=ON \
        -DWHISPER_BUILD_SERVER=ON
    cmake --build build --config Release -j"$(nproc)" --target whisper-server

    [ -f build/bin/whisper-server ] || fail "whisper.cpp build failed"

    # The llama.cpp guard: a shared whisper/ggml dep means a binary that works
    # here and not on the node it is copied to. Fail at build time.
    if ldd build/bin/whisper-server 2>/dev/null | grep -qiE "libwhisper|libggml"; then
        ldd build/bin/whisper-server | grep -iE "libwhisper|libggml" >&2
        fail "whisper-server still has shared whisper/ggml deps - static link didn't take. Refusing to ship incomplete binary."
    fi

    local OUT="$PLATFORM_DIR/whisper-server-${JP_FAMILY}-${PLATFORM_TAG}-aarch64"
    cp build/bin/whisper-server "$OUT"
    chmod +x "$OUT"

    record_artifact "$OUT"

    echo "whisper.cpp: $(describe_ref "$WHISPER_REF") → $(basename "$OUT")" >> "$BUILD_INFO"
    log "whisper.cpp built → $OUT ✓"
    cd ~
}

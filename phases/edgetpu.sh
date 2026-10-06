# ------------------------------------------------------------
# phases/edgetpu.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# Coral userspace - libedgetpu and the tflite_runtime it is built for
# ═════════════════════════════════════════════════════════════
#
# The kernel modules (phases/coral.sh) make /dev/apex_0 appear. To USE the TPU
# from Python takes two more things, and they are a PAIR:
#
#   tflite_runtime   the interpreter (a wheel)
#   libedgetpu       the delegate that hands a model to the TPU (a .so)
#
# Both must be built from the same TensorFlow, or the delegate does not load.
#
# WHY THIS IS A PREBUILT (Design note:). Everything upstream of it went
# away or stopped moving:
#   - Google's Coral apt repo answers 403 for every file under
#     packages.cloud.google.com/apt/dists/coral-edgetpu-stable (seen that day;
#     the signing key still downloads, the repository does not).
#   - Google's own last libedgetpu release is from 2021.
#   - PyPI's tflite-runtime stops at 2.14.0, a TensorFlow no libedgetpu was
#     ever built for.
# One maintainer's community builds were the only matched pair left. They
# work - and "a stranger's binary, installed as root" is the dependency this
# archive exists to remove. So: built here, from source, on the box.
#
# THE RECIPE, as proven on the Orin Nano (JetPack 6), delegate loaded and
# MobileNet V2 at 3.2 ms per inference on the TPU:
#
#   1. tflite_runtime wheel: TensorFlow's own
#      tensorflow/lite/tools/pip_package/build_pip_package_with_cmake.sh
#      (about ten minutes on a Nano). Its cmake tree fetches and builds
#      abseil and flatbuffers at the versions that TensorFlow pins.
#   2. flatc (the schema compiler) from THAT flatbuffers source - the wheel
#      build does not make one, and a distro flatc of another version writes
#      headers that do not compile against these.
#   3. libedgetpu's objects with its own makefile_build/Makefile, pointed at
#      the abseil and flatbuffers headers from step 1.
#   4. THE LINK IS OURS, not the Makefile's. The Makefile puts the libraries
#      BEFORE the objects on its link line: fine for shared abseil, and with
#      static archives it drops every symbol - the .so links, and fails at
#      load time with an undefined absl symbol (which is exactly what the
#      first attempt did). Here: objects first, the static abseil and
#      flatbuffers from step 1 after them, and `-z defs` so a missing symbol
#      is an error NOW, at build time, not on somebody's node.
#
# The result needs nothing at runtime but libusb and the C++ runtime - no
# libabsl, no libflatbuffers - so it cannot be broken by the distro moving
# either of those.
#
# libedgetpu's SOURCE is the community fork (github.com/feranick/libedgetpu):
# it is Google's code carried forward to build against current TensorFlow,
# which Google's repo no longer does. It is source, pinned to a tag, with the
# commit recorded - a different thing from installing its binaries.
#
#   -march=native: TensorFlow's script compiles the wheel for the CPU it is
#   built on. That is what a per-platform archive is; do not carry a Nano's
#   wheel to a Xavier.
build_edgetpu() {
    log "Building libedgetpu + tflite_runtime (TensorFlow ${TFLITE_REF}, libedgetpu ${LIBEDGETPU_REF})..."
    apt_require build-essential git xxd libusb-1.0-0-dev

    # numpy<2: this TensorFlow's Python wrapper is built against numpy 1.x
    # headers, and the runtime venv on the node holds numpy below 2 with it.
    use_venv edgetpu 3.18
    "$PYBIN" -m pip install -q "numpy<2" pybind11 wheel \
        || fail "edgetpu: could not install the wheel build's Python dependencies"

    local W="$BUILD_DIR/edgetpu-build"
    rm -rf "$W"
    mkdir -p "$W"
    cd "$W"

    # A tag clones shallow; anything else (a SHA) needs the history to check out.
    if ! git clone --quiet --depth 1 -b "$TFLITE_REF" https://github.com/tensorflow/tensorflow 2>/dev/null; then
        git clone --quiet https://github.com/tensorflow/tensorflow \
            && git -C tensorflow checkout --quiet "$TFLITE_REF" \
            || fail "tensorflow: no such ref '$TFLITE_REF'"
    fi
    record_source tensorflow "$W/tensorflow"
    git clone --quiet https://github.com/feranick/libedgetpu
    git -C libedgetpu checkout --quiet "$LIBEDGETPU_REF" \
        || fail "libedgetpu: no such ref '$LIBEDGETPU_REF'"
    record_source libedgetpu "$W/libedgetpu"

    # ── 1. the wheel ──
    log "edgetpu: building the tflite_runtime wheel (about ten minutes on a Nano)..."
    ( cd tensorflow && PYTHON="$PYBIN" BUILD_NUM_JOBS="$RESOLVED_MAX_JOBS" \
        bash tensorflow/lite/tools/pip_package/build_pip_package_with_cmake.sh native ) > "$W/wheel.log" 2>&1 \
        || { tail -20 "$W/wheel.log" >&2; fail "edgetpu: the tflite_runtime wheel did not build (log: $W/wheel.log)"; }
    local PIP_DIR="$W/tensorflow/tensorflow/lite/tools/pip_package/gen/tflite_pip/python3"
    local CM="$PIP_DIR/cmake_build"
    local WHL; WHL="$(ls "$PIP_DIR"/dist/tflite_runtime-*.whl 2>/dev/null | head -1)"
    [ -n "$WHL" ] && [ -f "$WHL" ] || fail "edgetpu: the wheel build finished and left no tflite_runtime wheel"

    local FB_LIB ABSL_LIBS
    FB_LIB="$(find "$CM/_deps/flatbuffers-build" -name 'libflatbuffers.a' 2>/dev/null | head -1)"
    ABSL_LIBS="$(find "$CM/_deps/abseil-cpp-build" -name 'libabsl_*.a' 2>/dev/null | sort | tr '\n' ' ')"
    [ -f "$FB_LIB" ] && [ -n "$ABSL_LIBS" ] && [ -d "$CM/abseil-cpp" ] && [ -d "$CM/flatbuffers/include" ] \
        || fail "edgetpu: the wheel's cmake tree does not hold abseil and flatbuffers where this phase expects them
  ($CM). TensorFlow has moved its build layout; this phase has to follow it."

    # ── 2. flatc, from the same flatbuffers ──
    cmake -S "$CM/flatbuffers" -B "$W/flatc-build" -DCMAKE_BUILD_TYPE=Release \
          -DFLATBUFFERS_BUILD_TESTS=OFF -DFLATBUFFERS_BUILD_FLATLIB=OFF -DFLATBUFFERS_BUILD_FLATHASH=OFF > "$W/flatc.log" 2>&1 \
        && cmake --build "$W/flatc-build" -j"$RESOLVED_MAX_JOBS" --target flatc >> "$W/flatc.log" 2>&1 \
        || { tail -20 "$W/flatc.log" >&2; fail "edgetpu: flatc did not build (log: $W/flatc.log)"; }
    local FLATC="$W/flatc-build/flatc"
    log "edgetpu: $("$FLATC" --version 2>&1) (from the wheel's own flatbuffers)"

    # ── 3. libedgetpu's objects ──
    # CXX/CC carry the include paths because the Makefile has no hook for
    # extra ones. Its own link runs and its output is not used (see 4).
    local OUT="$W/libedgetpu/out"
    local INC="-I$CM/abseil-cpp -I$CM/flatbuffers/include"
    ( cd libedgetpu && TFROOT="$W/tensorflow" make -f makefile_build/Makefile -j"$RESOLVED_MAX_JOBS" all \
        FLATC="$FLATC" CXX="g++ $INC" CC="gcc $INC" ) > "$W/edgetpu.log" 2>&1 \
        || { grep -E "error" "$W/edgetpu.log" | head -20 >&2; fail "edgetpu: libedgetpu did not compile (log: $W/edgetpu.log)"; }

    # ── 4. the link ──
    local COMMON STD_OBJS MAX_OBJS
    COMMON="$(find "$OUT" -name '*.o' ! -name '*-throttled.o' ! -name 'edgetpu_context_direct.o' ! -name 'edgetpu_manager_direct.o' | sort | tr '\n' ' ')"
    STD_OBJS="$(find "$OUT" -name '*-throttled.o' | sort | tr '\n' ' ')"
    MAX_OBJS="$(find "$OUT" \( -name 'edgetpu_context_direct.o' -o -name 'edgetpu_manager_direct.o' \) | sort | tr '\n' ' ')"
    [ -n "$COMMON" ] && [ -n "$STD_OBJS" ] && [ -n "$MAX_OBJS" ] \
        || fail "edgetpu: libedgetpu's objects are not where this phase expects them ($OUT)"

    local variant objs lib
    for variant in std max; do
        [ "$variant" = std ] && objs="$STD_OBJS" || objs="$MAX_OBJS"
        lib="$PLATFORM_DIR/libedgetpu-${variant}-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.so"
        # shellcheck disable=SC2086 - the object and archive lists are word lists on purpose
        g++ -shared -fPIC -Wl,--soname,libedgetpu.so.1 \
            -Wl,--version-script="$W/libedgetpu/tflite/public/libedgetpu.lds" \
            -Wl,-z,defs -Wl,--gc-sections -o "$lib" \
            $COMMON $objs "$FB_LIB" -Wl,--start-group $ABSL_LIBS -Wl,--end-group \
            -l:libusb-1.0.so.0 -lpthread -ldl -lrt 2> "$W/link-$variant.log" \
            || { head -20 "$W/link-$variant.log" >&2; fail "edgetpu: libedgetpu ($variant) did not link"; }
        strip --strip-unneeded "$lib"

        # The two ways this has gone wrong, asked of the file itself.
        if ldd "$lib" 2>/dev/null | grep -qiE "libabsl|libflatbuffers|not found"; then
            ldd "$lib" | grep -iE "libabsl|libflatbuffers|not found" >&2
            fail "edgetpu: $(basename "$lib") still needs a shared abseil or flatbuffers - the static link did not take."
        fi
        nm -D --defined-only "$lib" | grep -q "edgetpu_version" \
            || fail "edgetpu: $(basename "$lib") does not export edgetpu_version - the version script was not applied."
    done

    cp "$WHL" "$PLATFORM_DIR/"
    local WHL_OUT="$PLATFORM_DIR/$(basename "$WHL")"
    local STD_OUT="$PLATFORM_DIR/libedgetpu-std-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.so"

    # ── does the pair actually load, with the wheel that was just built ──
    # In a throwaway venv, never the build venv. With a TPU on this box the
    # delegate is loaded for real; without one, the library is opened and asked
    # its version - a delegate cannot be created with no device, and that is
    # not a build failure.
    rm -rf "$W/check-venv"
    "$HOST_PYBIN" -m venv "$W/check-venv" \
        && "$W/check-venv/bin/python" -m pip install -q "numpy<2" "$WHL_OUT" \
        || fail "edgetpu: the wheel that was just built does not install into a clean venv"
    local how
    how="$("$W/check-venv/bin/python" - "$STD_OUT" <<'PYCHECK'
import ctypes, os, sys
import tflite_runtime
import tflite_runtime.interpreter as tflite
lib = sys.argv[1]
c = ctypes.CDLL(lib)
c.edgetpu_version.restype = ctypes.c_char_p
ver = c.edgetpu_version().decode()
if os.path.exists("/dev/apex_0") or os.path.exists("/sys/bus/usb/devices"):
    try:
        tflite.load_delegate(lib)
        print("delegate loaded on this box's TPU; tflite_runtime %s; %s" % (tflite_runtime.__version__, ver))
        raise SystemExit(0)
    except ValueError as e:
        if os.path.exists("/dev/apex_0"):
            raise SystemExit("the delegate did not load although /dev/apex_0 is here: %s" % e)
print("library opens (no TPU on this box to load the delegate on); tflite_runtime %s; %s" % (tflite_runtime.__version__, ver))
PYCHECK
)" || fail "edgetpu: the built pair does not work together: $how"
    log "edgetpu: $how"

    # What is in the pair, for the node installer and for whoever reads the
    # folder in four years. Same idea as coral-*.manifest.
    local MAN="$PLATFORM_DIR/edgetpu-${JP_FAMILY}-${PLATFORM_TAG}.manifest"
    {
        echo "jp_family=${JP_FAMILY}"
        echo "platform=${PLATFORM_TAG}"
        echo "tensorflow=$(describe_ref "$TFLITE_REF")"
        echo "libedgetpu=$(describe_ref "$LIBEDGETPU_REF")"
        echo "tflite_runtime=$(basename "$WHL_OUT")"
        echo "libedgetpu_std=$(basename "$STD_OUT")"
        echo "libedgetpu_max=libedgetpu-max-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.so"
        echo "numpy=<2"
        echo "checked=$how"
        echo "built=$(date -Iseconds)"
    } > "$MAN"

    record_artifact "$WHL_OUT"
    record_artifact "$STD_OUT"
    record_artifact "$PLATFORM_DIR/libedgetpu-max-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.so"
    record_artifact "$MAN"

    echo "edgetpu: tensorflow $(describe_ref "$TFLITE_REF"), libedgetpu $(describe_ref "$LIBEDGETPU_REF") → $(basename "$WHL_OUT"), $(basename "$STD_OUT")" >> "$BUILD_INFO"
    log "libedgetpu + tflite_runtime built → $PLATFORM_DIR ✓"
    cd ~
}

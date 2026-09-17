# ------------------------------------------------------------
# phases/bitsandbytes.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# bitsandbytes (Xavier only - sm_72 exists nowhere else)
# ═════════════════════════════════════════════════════════════
#
# WHY THIS PHASE EXISTS, and why it is Xavier-only. Checked against the real
# wheel, not the release notes: the PyPI aarch64 wheel ships one .so per CUDA
# version, and every CUDA 11/12 one carries cubins for exactly sm_75, sm_80
# and sm_90 (the 13.x ones carry sm_100/110/120/121).
#
#   Orin   = sm_87. COVERED, and no prebuilt is wanted. CUDA cubins are
#            binary-compatible UPWARD within a major generation, so the sm_80
#            cubin runs on 8.7. The stock wheel is the right answer there.
#   Spark  = sm_121. Covered by the CUDA 13.x .so. Not a Jetson; not built here.
#   Xavier = sm_72. NOT COVERED, at any version. Same major as sm_75 but a
#            LOWER minor, and the compatibility rule needs device_minor >=
#            cubin_minor - 7.2 < 7.5, so the cubin will not load. There is no
#            JIT escape either: the only PTX embedded is `.target sm_90`, which
#            cannot compile down to a 7.2 device.
#
# THE FAILURE MODE THIS PREVENTS IS SILENT. `pip install bitsandbytes` succeeds
# on a Xavier, `import bitsandbytes` succeeds, and the thing only dies when a
# kernel actually launches - which is hours into a fine-tune. That is why the
# phase verifies the built artifact instead of trusting a clean compile.
#
# WHAT YOU GET AND DO NOT GET at sm_72, stated plainly so nobody is surprised:
# 4-bit (NF4/FP4) and the 8-bit optimizers work. LLM.int8() does NOT - bnb
# gates `supports_igemmlt` on compute capability >= 7.5, and that is a hardware
# fact about Volta, not something a rebuild fixes.
build_bitsandbytes() {
    # BUILDABLE ON ANY PLATFORM, REQUIRED ON EXACTLY ONE. This used to hard-skip
    # anything but Xavier, which is right about need and wrong about capability:
    # a spare wheel you built yourself is worth having on a box whose upstream
    # wheel could change under you. So it builds anywhere and tells you, once,
    # which case you are in.
    [ -n "${USER_BNB_VERSION:-}" ] && BITSANDBYTES_VERSION="$USER_BNB_VERSION"
    [ -n "$BITSANDBYTES_VERSION" ] || \
        fail "no bitsandbytes version known for $PLATFORM_TAG/$JP_FAMILY - pass --bitsandbytes-version"

    case "$JP_FAMILY" in
        jp5) log "sm_${CUDA_ARCH} (Volta) is covered by NO published wheel - this build is REQUIRED." ;;
        *)   warn "sm_${CUDA_ARCH} is already covered by the published aarch64 wheel."
             warn "  Orin (8.7) is served by its sm_80 cubin; Spark (12.1) by the CUDA 13 libs."
             warn "  Building anyway as a spare - this is insurance, not a fix." ;;
    esac

    log "Building bitsandbytes ${BITSANDBYTES_VERSION} for sm_${CUDA_ARCH} (${PLATFORM_TAG}, ${PYTAG})..."
    use_venv bitsandbytes 3.22.1

    # torch has to be importable: bnb links against it and reads its CUDA
    # version to decide what to name the library it builds.
    #
    # SKIP, NOT FAIL. A phase whose dependency is absent has not broken; it is
    # unavailable, and the honest answer is to record that and let the rest of
    # the archive finish. It still FAILS if it gets past here and cannot build.
    #
    # (The Spark branch that used to live here said torch comes from NVIDIA on
    # that box and this script does not build it. Both halves stopped being
    # true the day jp7 got a PYTORCH_VERSION of its own - see build_pytorch -
    # and stale advice in an error path is worse than none.)
    if ! ensure_torch "$PYTORCH_VERSION"; then
        warn "bitsandbytes needs torch ${PYTORCH_VERSION} and none could be installed."
        warn "  Run --pytorch first (the same run is fine), or drop a matching"
        warn "  wheel into $PLATFORM_DIR and re-run."
        note_skip bitsandbytes "torch ${PYTORCH_VERSION} unavailable"
        cd ~
        return 0
    fi
    "$PYBIN" -c "import torch; print('torch:', torch.__version__, '| cuda:', torch.version.cuda)"

    # CMAKE >= 3.22.1, WHICH JETPACK 5 DOES NOT HAVE. Ubuntu 20.04 ships
    # 3.16.3 and bitsandbytes' CMakeLists opens with
    # cmake_minimum_required(VERSION 3.22.1) - so a stock Xavier fails on the
    # very first configure line with an error that says nothing about apt. The
    # pip wheel is the least invasive fix: it installs a modern cmake for this
    # user only and leaves the system one (which other Jetson tooling expects)
    # exactly where it is.
    # cmake is guaranteed >= 3.22.1 by the use_venv call at the top of this
    # phase, which installs it into THIS venv - see the long note at
    # ensure_cmake. This phase used to resolve its own halfway through, which
    # meant the check that mattered ran fifteen minutes into a run.

    cd "$BUILD_DIR"
    rm -rf bitsandbytes
    git clone --branch "${BITSANDBYTES_VERSION}" --depth 1 \
        https://github.com/bitsandbytes-foundation/bitsandbytes bitsandbytes
    record_source bitsandbytes "$PWD/bitsandbytes"
    cd bitsandbytes

    # ── ITS OWN BUILD REQUIRES, WHICH ARE WHERE THE PACKAGE NAME COMES FROM ──
    # 0.50.2 asks for scikit-build-core, setuptools>=77.0.3 and
    # trove-classifiers. Without them setuptools cannot apply the [project]
    # table in pyproject.toml - and that table is the only place the name
    # "bitsandbytes" appears. The build then succeeds at building the wrong
    # thing: correct cubins, correct stamped version, filename
    # UNKNOWN-0.50.2+sm87. torch is excluded for the usual reason - ensure_torch
    # above put the archive's own sm_${CUDA_ARCH} wheel in this venv and pip
    # must not replace it with an index build.
    install_build_requires bitsandbytes torch \
        || warn "  no [build-system] requires in this checkout - continuing (older bitsandbytes did not have one)"

    # STAMP THE ARCH INTO THE VERSION, so the installed package says which
    # build it is. `pip show bitsandbytes` reporting 0.45.5+sm72 is the whole
    # point: a wheel named exactly like the PyPI one is a trap, because
    # installing the wrong one fails silently at kernel launch. A PEP 440 local
    # version segment is legal, pip-installable, and survives into the metadata.
    #
    # BOTH FILES. setup.py passes an explicit version that wins over pyproject's
    # dynamic lookup, so patching only __init__.py would produce a wheel whose
    # filename says one thing and whose module says another.
    #
    # THE LITERAL MOVED, AND THIS COST A WHOLE RUN. Up to ~0.45 setup.py read:
    #
    #     setup(version="0.45.5", ...)
    #
    # and by 0.50.2 it is a dict assembled first:
    #
    #     setup_kwargs = {
    #         "version": "0.50.2",
    #         ...
    #     }
    #     setup(**setup_kwargs)
    #
    # Same literal, same meaning, different punctuation - `"version":` instead
    # of `version=`. The old fixed-string sed matched __init__.py and silently
    # did nothing to setup.py, and the grep below did exactly what it was
    # written to do: refuse to build a wheel whose filename and module would
    # disagree. Correct, and it exited the whole script - taking vllm,
    # wheelhouse, vendor and selftest with it, none of which care about
    # bitsandbytes at all. That second-order cost is the argument for matching
    # both spellings rather than for softening the check.
    #
    # Done in python because the version is a regex-hostile string (0.50.2 has
    # dots that an unescaped ERE would treat as wildcards, so `0.50.2` would
    # happily match `0x50y2`), and because "which form did it find" is worth
    # printing rather than inferring from a later grep.
    local STAMPED="${BITSANDBYTES_VERSION}+sm${CUDA_ARCH}"
    python3 - "$BITSANDBYTES_VERSION" "$STAMPED" <<'BNB_STAMP' || fail "bitsandbytes: version stamp failed - see the STAMP_MISS line above"
import io, re, sys
ver, stamped = sys.argv[1], sys.argv[2]
v = re.escape(ver)
targets = [
    ("bitsandbytes/__init__.py", [r'(__version__\s*=\s*")(' + v + r')(")']),
    # dict form first - it is what current upstream uses; kwarg form second so
    # an older tag still stamps.
    ("setup.py", [r'("version"\s*:\s*")(' + v + r')(")',
                  r'(\bversion\s*=\s*")(' + v + r')(")']),
]
for path, pats in targets:
    s = io.open(path, encoding="utf-8").read()
    n = 0
    for p in pats:
        s, k = re.subn(p, lambda m: m.group(1) + stamped + m.group(3), s)
        n += k
    if n == 0:
        sys.exit("STAMP_MISS: no %r version literal in %s - upstream moved it again" % (ver, path))
    io.open(path, "w", encoding="utf-8").write(s)
    print("[seren] %s: stamped %d version literal(s) -> %s" % (path, n, stamped))
BNB_STAMP
    grep -qF "+sm${CUDA_ARCH}" bitsandbytes/__init__.py || fail "version stamp did not apply to bitsandbytes/__init__.py - upstream changed the literal"
    grep -qF "+sm${CUDA_ARCH}" setup.py                 || fail "version stamp did not apply to setup.py - upstream changed the literal"

    # A bare capability (not "72-real") makes CMake emit BOTH the sm_72 cubin
    # and compute_72 PTX, so the wheel still has a JIT path if it ever meets a
    # 7.x device this exact cubin does not match.
    cmake -DCOMPUTE_BACKEND=cuda -DCOMPUTE_CAPABILITY="${CUDA_ARCH}" -S . \
        || fail "cmake configure failed - see above"
    cmake --build . --config Release -j "$RESOLVED_MAX_JOBS" \
        || fail "bitsandbytes native build failed"

    # ── VERIFY THE ARTIFACT, not the exit code ──
    # A clean compile proves nothing here: the whole reason this phase exists
    # is that a wheel can build, install and import perfectly while containing
    # no code your GPU can run. cuobjdump ships with the CUDA toolkit and reads
    # the arch straight out of the fatbin, so ask it.
    local SO; SO="$(ls bitsandbytes/libbitsandbytes_cuda*.so 2>/dev/null | head -1)"
    [ -n "$SO" ] || fail "build produced no libbitsandbytes_cuda*.so"
    log "built $(basename "$SO")"
    if command -v cuobjdump &>/dev/null; then
        local ARCHES; ARCHES="$(cuobjdump --list-elf "$SO" 2>/dev/null | grep -oE 'sm_[0-9]+' | sort -u | tr '\n' ' ')"
        log "cubin architectures present: ${ARCHES:-none}"
        echo "$ARCHES" | grep -q "sm_${CUDA_ARCH}\b" || \
            fail "REFUSING TO SHIP: sm_${CUDA_ARCH} is not in the built library (found: ${ARCHES:-none}).
  This wheel would install, import, and then fail at the first kernel launch -
  which is exactly the silent failure this phase exists to prevent."
    else
        warn "cuobjdump not on PATH - cannot verify sm_${CUDA_ARCH} is in the binary."
        warn "It is part of the CUDA toolkit; without it this wheel is unverified."
    fi

    "$PYBIN" setup.py bdist_wheel || fail "bitsandbytes wheel build failed"

    # A WHEEL WITH THE WRONG NAME IS NOT A MISSING WHEEL, and saying so cost an
    # evening. This glob missing printed "no wheel produced" while dist/ held
    # UNKNOWN-0.50.2+sm87-cp310-cp310-linux_aarch64.whl - so the hunt started at
    # the compiler, which had done nothing wrong, instead of at the metadata.
    local WHEEL; WHEEL=$(ls dist/bitsandbytes-*.whl 2>/dev/null | head -1)
    if [ -z "$WHEEL" ]; then
        local stray; stray="$(ls dist/*.whl 2>/dev/null | head -1)"
        [ -n "$stray" ] && fail "bitsandbytes: the build produced $(basename "$stray").
  The name is WRONG, not missing - the compile and the version stamp both
  worked. UNKNOWN- means setuptools never read [project] from pyproject.toml,
  which is the only place the package name is written. That happens when the
  [build-system] requires are not installed; see install_build_requires in
  lib/venv.sh, which this phase calls before building for exactly this reason."
        fail "bitsandbytes build failed - no wheel produced (dist/ is empty)"
    fi

    cp "$WHEEL" "$PLATFORM_DIR/"
    record_artifact "$PLATFORM_DIR/$(basename "$WHEEL")"
    echo "bitsandbytes: $(basename "$WHEEL")" >> "$BUILD_INFO"
    log "bitsandbytes wheel saved → $PLATFORM_DIR/$(basename "$WHEEL") ✓"
    log "  install with:  pip install $(basename "$WHEEL")"
    log "  verify after:  python -c \"import bitsandbytes as b; print(b.__version__)\"  → ${STAMPED}"
    cd ~
}

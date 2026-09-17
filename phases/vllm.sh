# ------------------------------------------------------------
# phases/vllm.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ═════════════════════════════════════════════════════════════
# vLLM - the other synth-data backend, in its own venv
# ═════════════════════════════════════════════════════════════
#
# ms-moe-maker can drive either llama.cpp or vLLM to generate synth data. They
# are EXTERNAL services it talks to, not python dependencies (there is no vllm
# in its pyproject), which is what makes the venv-per-backend shape natural
# rather than a workaround: vLLM pins torch to an exact version, and in its own
# venv that pin constrains nothing else on the box.
#
# So this archives a TRIPLE, not a package: vllm plus the exact torch it pins
# plus the matching torchvision. Half of that set is useless - a vllm wheel
# whose torch is gone cannot be installed - and "pinned per JP family" is only
# true if the things it is pinned WITH travel with it.
#
# THESE ARE UPSTREAM aarch64 WHEELS, mirrored rather than compiled, and that is
# a deliberate exception to build-it-yourself. vLLM publishes real
# manylinux_2_28_aarch64 wheels (unlike torch for Jetson), and a vLLM source
# build is one of the heaviest in the ecosystem. Mirroring the artifact that
# actually exists beats an hours-long build that would produce a worse copy of
# it. --keep-sources still snapshots the tree if you want the option back.
build_vllm() {
    if [ -z "$VLLM_VERSION" ]; then
        warn "vLLM does not support sm_${CUDA_ARCH}."
        warn "  Its CUDA_SUPPORTED_ARCHS is a discrete list and ${TORCH_ARCH_LIST} is in none"
        warn "  of its branches - they start at 7.0/7.5. This is a property of the"
        warn "  GPU, not of packaging, so no version of vLLM will run here."
        warn "  On this box llama.cpp is not the alternative synth backend, it is"
        warn "  the only one. That is why both exist."
        note_skip vllm "vLLM has no kernels for sm_${CUDA_ARCH} (Volta); use llama.cpp here"
        return 0
    fi
    [ -n "${USER_VLLM_VERSION:-}" ] && VLLM_VERSION="$USER_VLLM_VERSION"

    # ITS OWN VENV AT BUILD TIME TOO, and this is the case that made
    # venv-per-phase mandatory rather than merely tidy. vLLM pins torch to an
    # exact version. Sharing an interpreter, that pin either loses (and vllm
    # links a torch it was not built for) or wins (and torchvision's freshly
    # compiled extension is now sitting on a different torch than it compiled
    # against). In its own venv the pin is simply true, and costs nobody.
    use_venv vllm 3.27

    local VLLM_DIR="$PLATFORM_DIR/vllm"
    mkdir -p "$VLLM_DIR"

    # ── BUILT, NOT PULLED ──
    # The earlier version of this phase downloaded vLLM's published aarch64
    # wheel. That works today and is exactly the dependency this repo exists to
    # remove: a wheel you fetched is a wheel somebody else has to keep serving.
    # Compiled here, against this box's arch and this archive's torch, it stays
    # reproducible from the source snapshot even if the project disappears.
    #
    # --vllm-wheel-only is the escape hatch, not the default. It exists because
    # this build is genuinely brutal on small boxes (see the RAM note below) and
    # a mirrored wheel beats an empty folder.

    # THE TORCH IT WILL LINK AGAINST HAS TO BE THE ONE IT PINS. vLLM pins torch
    # exactly; building against a different one produces a wheel that installs
    # and then fails on an ABI mismatch at import. Checked, not assumed.
    local have_torch
    if ! ensure_torch "$VLLM_TORCH_VERSION"; then
        warn "vLLM needs torch ${VLLM_TORCH_VERSION} and none could be installed."
        warn "  Run --pytorch first (the phase table orders this for you when both"
        warn "  are requested); this archive builds exactly that version."
        note_skip vllm "torch ${VLLM_TORCH_VERSION} unavailable"
        return 0
    fi
    have_torch="$("$PYBIN" -c 'import torch; print(torch.__version__)' 2>/dev/null || true)"
    if [ "${have_torch%%+*}" != "$VLLM_TORCH_VERSION" ]; then
        warn "torch ${have_torch} is installed but vllm ${VLLM_VERSION} pins ${VLLM_TORCH_VERSION}."
        warn "  Building anyway would give you a wheel that imports and then dies"
        warn "  on an ABI mismatch, which is a worse outcome than not having one."
        note_skip vllm "torch ${have_torch} != pinned ${VLLM_TORCH_VERSION}"
        return 0
    fi
    log "torch ${have_torch} matches vllm's pin ✓"

    if $VLLM_WHEEL_ONLY; then
        log "Mirroring the published vLLM wheel (--vllm-wheel-only)..."
        "$PYBIN" -m pip download --no-deps --only-binary=:all: \
            --platform manylinux_2_28_aarch64 --python-version "${PYTAG#cp}" \
            ${VENDOR_INDEX:+--extra-index-url "$VENDOR_INDEX"} \
            "vllm==${VLLM_VERSION}" -d "$VLLM_DIR" -q 2>/dev/null \
            && echo "vllm     vllm==${VLLM_VERSION} (MIRRORED aarch64 wheel, not built here)" >> "$PROVENANCE" \
            || { warn "  no aarch64 wheel for vllm==${VLLM_VERSION} at ${PYTAG}"
                 note_skip vllm "no published wheel and --vllm-wheel-only was set"; return 0; }
    else
        log "Building vLLM ${VLLM_VERSION} from source for sm_${CUDA_ARCH}..."
        warn "  This is the heaviest build in this script. Hours, and RAM-hungry"
        warn "  per job - an 8GB Nano will OOM at anything but MAX_JOBS=1."

        cd "$BUILD_DIR"
        clone_or_reuse vllm "v${VLLM_VERSION}" https://github.com/vllm-project/vllm \
            || fail "vllm: no such tag v${VLLM_VERSION}"
        record_source vllm "$PWD/vllm"
        cd vllm

        # RAM, NOT CORES, IS THE LIMIT HERE. The shared RESOLVED_MAX_JOBS is
        # nproc-derived, which is right for llama.cpp and wrong for vLLM: its
        # CUDA translation units are large enough that jobs x ~4GB is the real
        # constraint. Derived from what the box actually has rather than
        # hardcoded, and never above the core count.
        local mem_gb jobs
        mem_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)
        # /6, NOT /4. The warning above says an 8GB Nano needs MAX_JOBS=1 and
        # the first version of this line handed it 2 - a formula that disagreed
        # with the caution printed directly above it. 6GB per job also matches
        # vLLM's translation units better than 4 does.
        jobs=$(( mem_gb / 6 )); [ "$jobs" -lt 1 ] && jobs=1
        [ "$jobs" -gt "$RESOLVED_MAX_JOBS" ] && jobs="$RESOLVED_MAX_JOBS"
        log "  ${mem_gb}GB RAM -> MAX_JOBS=$jobs (vLLM wants roughly 6GB per job)"

        export VLLM_TARGET_DEVICE=cuda
        export TORCH_CUDA_ARCH_LIST="$TORCH_ARCH_LIST"
        export MAX_JOBS="$jobs"
        export NVCC_THREADS=1
        export CMAKE_BUILD_TYPE=Release

        # ── BUILD DEPENDENCIES, FROM THE ONE PLACE THAT IS AUTHORITATIVE ──
        #
        # This used to guess at two filenames and shrug:
        #
        #   pip install -r requirements/build.txt 2>/dev/null \
        #     || pip install -r requirements-build.txt 2>/dev/null \
        #     || warn "no build requirements file found where expected - continuing"
        #
        # By 0.26.0 neither path exists. Both greps missed, stderr went to
        # /dev/null, "continuing" sounded harmless, and the build walked into:
        #
        #   File "/mnt/nvme/vllm/setup.py", line 21, in <module>
        #     from setuptools_rust.build import build_rust
        #   ModuleNotFoundError: No module named 'setuptools_rust'
        #
        # The real list was never in those files anyway - it is pyproject.toml's
        # [build-system] requires, which is the thing PEP 517 defines as the
        # answer. `setup.py bdist_wheel` is a direct invocation of the legacy
        # entry point, so it NEVER reads that section and never installs any of
        # it. Guessing at a requirements file was standing in for a mechanism
        # that already exists; install_build_requires reads the section instead.
        #
        # TORCH IS FILTERED OUT OF THAT LIST, AND THAT IS NOT AN OPTIMISATION.
        # vLLM pins `torch == 2.11.0` in its build requires. Handing that to pip
        # would fetch a generic aarch64 torch from an index and install it OVER
        # the sm_121 wheel this archive just spent hours building - and the
        # resulting vllm would be compiled against the wrong one. ensure_torch
        # above has already put the correct torch in this venv and verified it;
        # this list must not be allowed to undo that.
        # install_build_requires lives in lib/venv.sh because bitsandbytes needs
        # exactly the same step for exactly the same reason.
        if ! install_build_requires vllm torch; then
            if [ -f requirements/build.txt ]; then
                "$PYBIN" -m pip install -r requirements/build.txt \
                    || fail "vllm: requirements/build.txt would not install"
            else
                fail "vllm: no [build-system] requires in pyproject.toml and no requirements/build.txt.
  Upstream has moved its build dependencies again. Whatever setup.py imports at
  the top is what has to be installed into this venv before it will run."
            fi
        fi

        # numpy is not in the build requires, and torch says so out loud the
        # moment anything imports it:
        #   UserWarning: Failed to initialize NumPy: No module named 'numpy'
        # A torch that cannot convert to ndarray is not something to hand to a
        # build that imports torch. Same pin the rest of the archive uses.
        "$PYBIN" -c 'import numpy' 2>/dev/null \
            || "$PYBIN" -m pip install -q "numpy==${NUMPY_BUILD_VERSION}" \
            || warn "  numpy would not install - torch will warn, and some builds care"

        # The torch that survived all of the above is the one it will link.
        # Checked here rather than assumed, because everything between
        # ensure_torch and this line had the opportunity to change it.
        local linked
        linked="$("$PYBIN" -c 'import torch; print(torch.__version__)' 2>/dev/null || true)"
        [ "${linked%%+*}" = "$VLLM_TORCH_VERSION" ] \
            || fail "vllm: torch is ${linked:-absent} but the pin is ${VLLM_TORCH_VERSION}.
  Something in the build-requirements install replaced it. Building now would
  produce a wheel that imports and then dies on an ABI mismatch."
        log "  torch ${linked} still in place after installing build requirements ✓"

        "$PYBIN" setup.py bdist_wheel || fail "vLLM build failed - see above"

        local WHEEL; WHEEL=$(ls dist/vllm-*.whl 2>/dev/null | head -1)
        [ -n "$WHEEL" ] || fail "vLLM build produced no wheel"
        cp "$WHEEL" "$VLLM_DIR/"
        echo "vllm     vllm==${VLLM_VERSION} (BUILT from source, sm_${CUDA_ARCH})" >> "$PROVENANCE"
        log "  built $(basename "$WHEEL")"
        cd ~
    fi

    local f
    for f in "$VLLM_DIR"/*.whl; do
        [ -e "$f" ] || continue
        record_artifact "$f"
    done

    log "vLLM -> $VLLM_DIR ✓"
    log "  ITS OWN VENV, never ms-moe-maker's - that separation is what lets"
    log "  vLLM pin torch exactly without constraining the training stack:"
    log "    $HOST_PYBIN -m venv ~/seren-venvs/vllm"
    log "    ~/seren-venvs/vllm/bin/pip install $VLLM_DIR/*.whl"
    note_built vllm
    cd ~
}

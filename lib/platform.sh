# ------------------------------------------------------------
# lib/platform.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

# ─────────────────────────────────────────────────────────────
# Platform detection: Xavier (jp5/Volta), Orin (jp6/Ampere), Spark (jp7/Blackwell)
# ─────────────────────────────────────────────────────────────
#
# THE SPARK HAS NO /etc/nv_tegra_release AT ALL. That is not an oversight in
# its image - it is simply not a Tegra release in that sense - and it is why
# detection cannot be one file read. The same lesson already cost Starwright a
# complete set of unreachable Spark modules.
#
# --platform IS CHECKED FIRST AND ON PURPOSE. The heuristics below are written
# from spec for the Spark; an explicit answer from a person who is standing in
# front of the machine beats a guess from a script every time.
detect_platform() {
    local jp_release=""

    if [ -n "${USER_PLATFORM:-}" ]; then
        log "Platform forced to '$USER_PLATFORM' by --platform"
        case "$USER_PLATFORM" in
            xavier) jp_release="R35" ;;
            orin|nano) jp_release="R36" ;;
            spark) jp_release="SPARK" ;;
            *) fail "--platform must be one of: xavier, orin, spark (got: $USER_PLATFORM)" ;;
        esac
    elif [ -f /etc/nv_tegra_release ]; then
        jp_release=$(head -1 /etc/nv_tegra_release | grep -oP 'R\d+' | head -1)
    else
        # No Tegra release file. Three independent signals, any one of which is
        # enough - a GB10 answers to at least one of them.
        local model="" gpu="" dmi=""
        [ -r /proc/device-tree/model ] && model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
        command -v nvidia-smi &>/dev/null && gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
        [ -r /sys/class/dmi/id/product_name ] && dmi="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
        if echo "$model $gpu $dmi" | grep -qiE 'spark|GB10'; then
            jp_release="SPARK"
            log "Detected DGX Spark (no /etc/nv_tegra_release; matched: ${model:-}${gpu:+ / $gpu}${dmi:+ / $dmi})"
        fi
    fi

    case "$jp_release" in
        R35)
            JP_FAMILY="jp5"
            PLATFORM_TAG="xavier"
            CUDA_ARCH="72"
            TORCH_ARCH_LIST="7.2"
            # PyTorch 2.1.0 is the latest version that builds cleanly against
            # the CUDA 12.2 toolkit on JetPack 5.1.x.
            PYTORCH_VERSION="2.1.0"
            TORCHVISION_VERSION="0.16.0"
            # 0.45.5 is the LAST bitsandbytes that accepts torch 2.1.0. The
            # floor becomes torch>=2.2 at 0.46.0 and torch>=2.4 at 0.50.0, so
            # on a box pinned to 2.1.0 by CUDA 12.2 this is a ceiling, not a
            # preference. Bump it only together with PYTORCH_VERSION.
            BITSANDBYTES_VERSION="0.45.5"
            PYTHON_VERSION="3.10.14"
            ;;
        R36)
            JP_FAMILY="jp6"
            PLATFORM_TAG="orin"
            CUDA_ARCH="87"
            TORCH_ARCH_LIST="8.7"
            # PyTorch 2.1.0 fails on CUDA 12.6 (JetPack 6) because Thrust
            # removed the primitive-type swap() overload that 2.1.0's
            # LinearAlgebra.cu calls. Fixed upstream around 2.3.0.
            # Pin to 2.3.1 (last 2.3 patch) + matching torchvision 0.18.1.
            # 2.11.0, NOT 2.3.1, AND THE REASON IS vLLM. vllm 0.26.0 pins
            # torch==2.11.0 exactly. Leaving the baseline at 2.3.1 would mean
            # building torch TWICE on this box - once for ms-moe-maker and once
            # for vLLM - which is hours of compute to end up with two torches
            # that do the same job. One build, two consumers.
            #
            # Corroborated by this repo's own shipping history: the
            # 2026.05.24-nano release already carries
            # torch-2.11.0-cp310-cp310-linux_aarch64.whl, so the 2.3.1 pin here
            # was already behind what was actually published.
            PYTORCH_VERSION="2.11.0"
            TORCHVISION_VERSION="0.26.0"
            # 0.50.2 here too. An archive that holds a spare for one box and
            # not another is not an archive.
            BITSANDBYTES_VERSION="0.50.2"
            PYTHON_VERSION="3.10.14"
            ;;
        SPARK)
            JP_FAMILY="jp7"
            PLATFORM_TAG="spark"
            CUDA_ARCH="121"
            TORCH_ARCH_LIST="12.1"
            # BUILT FROM SOURCE HERE TOO, and "NVIDIA ships it, so we don't"
            # was the wrong policy twice over. Mirroring their wheel still
            # leaves you depending on them having served it once; if you never
            # built it yourself you cannot make another one the day that index
            # reorganises. Self-sufficient means from source.
            #
            # 2.8.0 IS A FLOOR, NOT A PREFERENCE. From pytorch's own arch table
            # in torch/utils/cpp_extension.py:
            #   2.7.0  ('Blackwell', '10.0;10.3;12.0+PTX')      <- no 12.1
            #   2.8.0  ('Blackwell', '10.0;10.3;12.0;12.1+PTX') <- GB10
            # and 12.1 is in 2.8.0's supported_arches, not only the named list.
            # torchvision 0.23.0 declares torch==2.8.0, so the pair is fixed.
            # 2.11.0 for the same reason as jp6: it is what vllm 0.26.0 pins,
            # and 2.11.0's arch table still carries Blackwell 12.1, so the one
            # build serves both consumers. 2.8.0 was the FLOOR for sm_121, not
            # a ceiling - see torch/utils/cpp_extension.py:
            #   2.7.0  ('Blackwell', '10.0;10.3;12.0+PTX')       <- no 12.1
            #   2.8.0+ ('Blackwell', '10.0;10.3;12.0;12.1+PTX')
            PYTORCH_VERSION="2.11.0"
            TORCHVISION_VERSION="0.26.0"
            # 0.50.2 supports CUDA 11.8-13.x and lists 121 in its CUDA>=13 arch
            # set. Its torch>=2.4 floor is no obstacle here - unlike Xavier,
            # which is why that one is pinned five releases back.
            BITSANDBYTES_VERSION="0.50.2"
            # 24.04 ships 3.12; build the same series from source anyway so the
            # archive does not depend on the distro still serving it.
            PYTHON_VERSION="3.12.8"
            ;;
        *)
            # REFUSING TO GUESS, and this replaced a default that WAS a guess.
            # The old fallback quietly assumed Xavier/arch 72. On a Spark - the
            # one machine with no /etc/nv_tegra_release, so the one that always
            # lands here - that produced artifacts compiled for sm_72 on an
            # sm_121 box, with nothing in the filename to say so. A wrong wheel
            # that installs and imports cleanly is worse than no wheel: you
            # find out hours into a run, months after you built the "backup".
            fail "Could not determine the platform.
  /etc/nv_tegra_release is absent and nothing identified this as a DGX Spark.
  Say which box this is - guessing a GPU architecture is not a safe default:
     $(basename "$0") --platform xavier|orin|spark ${SEREN_ORIGINAL_ARGS[*]}"
            ;;
    esac
    # ── the held baseline, in one place ──
    # "Build all the same stuff, the same way" only means something if there is
    # ONE declaration of what the same stuff is. These are the versions THIS
    # ARCHIVE holds - not whatever an index happens to serve today, which is
    # the entire point of the repo.
    # ── vLLM: its own venv, so its own torch ──
    # vLLM pins torch to an exact version, which would be a nasty constraint on
    # the baseline above IF they shared an interpreter. They do not: vLLM is an
    # external synth-data backend that ms-moe-maker talks to, not a python
    # dependency of it (there is no vllm in MsMoEMaker's pyproject), so it gets
    # its own venv and its own torch and the two never have to agree.
    #
    # 0.26.0 pins torch==2.11.0, which pairs with torchvision 0.26.0 - and
    # torch 2.11.0 is already what the nano release ships, so the stack lands
    # on a line that is in use rather than a new one.
    # vLLM's pin IS the platform baseline now, not a parallel one. Kept as
    # named variables so a mismatch between what vLLM wants and what this
    # archive builds is checkable rather than implicit - build_vllm asserts it.
    VLLM_VERSION="0.26.0"
    VLLM_TORCH_VERSION="2.11.0"
    VLLM_TVISION_VERSION="0.26.0"
    # Xavier cannot run vLLM AT ALL, and this is a hardware fact rather than a
    # packaging one. vLLM's CUDA_SUPPORTED_ARCHS is a discrete list and 7.2 is
    # in none of its branches (they start 7.0/7.5). That is the structural
    # reason llama.cpp matters: on a Xavier it is not the alternative synth
    # backend, it is the only one.
    [ "$JP_FAMILY" = "jp5" ] && VLLM_VERSION=""

    # NUMPY, AND IT IS NOT COSMETIC. These were hardcoded 1.24.4 (build) and
    # 1.26.1 (runtime) - correct for JP5's Python 3.10 and IMPOSSIBLE on the
    # Spark, because numpy 1.26.0 is the first release with cp312 wheels and
    # 1.24.4's build backend calls pkgutil.ImpImporter, which Python 3.12
    # removed outright:
    #     AttributeError: module 'pkgutil' has no attribute 'ImpImporter'
    # Neither torch nor torchvision actually pins numpy - these are OUR build
    # stability choices, so they belong in the baseline with everything else.
    #
    # 1.26.4 WAS THE CONSERVATIVE PICK AND IT IS THE WRONG WAY ROUND. NumPy's
    # ABI compatibility is one-directional: an extension compiled against the
    # 2.x headers runs on numpy >= 1.19 AND 2.x, while one compiled against
    # 1.26 refuses to import under numpy 2 at all -
    #     "A module that was compiled using NumPy 1.x cannot be run in NumPy 2.x"
    # - which is a wheel that works today and breaks on whatever box installs
    # it in two years. For an archive that is the wrong trade.
    #
    # 2.2.6 rather than 2.3: numpy 2.3 dropped Python 3.10, and jp6 is 3.10.
    # One version covers cp310 (Orin) and cp312 (Spark).
    # jp5 stays on 1.x because torch 2.1.0 predates the numpy 2 headers
    # outright - it reads PyArray_Descr->elsize, which numpy 2 moved.
    case "$JP_FAMILY" in
        jp5) NUMPY_BUILD_VERSION="1.24.4";  NUMPY_RUNTIME_VERSION="1.26.1" ;;
        *)   NUMPY_BUILD_VERSION="2.2.6";   NUMPY_RUNTIME_VERSION="2.2.6" ;;
    esac

    SQLITE_VERSION="3.45.1"
    SQLITE_URL_VERSION="3450100"
    SQLITE_YEAR="2024"

    KERNEL_VER=$(uname -r)
}

# Common build env - SET BEFORE THE CHECKS BELOW, AND THE ORDER IS THE FIX.
#
# This export used to sit AFTER the nvcc check, which meant the check ran
# against whatever PATH the caller happened to have. From a login shell that
# is harmless, because the profile already puts /usr/local/cuda-12.2/bin on
# PATH - so the check passed for years. Run the same script under `sudo` and
# it died with "nvcc required - CUDA toolkit not installed" on a box where
# `which nvcc` answers /usr/local/cuda-12.2/bin/nvcc, because sudo replaces
# PATH with sudoers' secure_path. The very next line of this script would have
# put it back.
#
# A preflight has to run in the environment the build will use, not the one it
# inherited. So the environment is built first and the checks judge THAT.
# THE TOOLKIT IS FOUND, NOT ASSUMED, and this line used to spell out
# /usr/local/cuda-12.2 three times. That is JetPack 5's toolkit and nobody
# else's:
#     Xavier / jp5   CUDA 12.2
#     Orin   / jp6   CUDA 12.6
#     Spark  / jp7   CUDA 13.x
# The other two only ever worked because the Jetson images put the real
# directory on PATH from /etc/profile.d - so the "fix" above was inheriting
# the answer from the login shell, which is precisely what stops being true
# under sudo, cron, or a DGX OS box that never had that profile snippet. On
# the Spark it meant a hardcoded path to a directory that does not exist.
resolve_cuda_home() {
    local c
    if [ -n "${CUDA_HOME:-}" ] && [ -x "${CUDA_HOME}/bin/nvcc" ]; then
        echo "$CUDA_HOME"; return 0
    fi
    if c="$(command -v nvcc 2>/dev/null)"; then
        echo "$(dirname "$(dirname "$c")")"; return 0
    fi
    [ -x /usr/local/cuda/bin/nvcc ] && { echo /usr/local/cuda; return 0; }
    # Highest version last-resort. sort -V so cuda-13.0 beats cuda-9.0.
    for c in $(ls -d /usr/local/cuda-* 2>/dev/null | sort -Vr); do
        [ -x "$c/bin/nvcc" ] && { echo "$c"; return 0; }
    done
    return 1
}

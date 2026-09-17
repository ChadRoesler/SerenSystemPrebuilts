#!/bin/bash
# ══════════════════════════════════════════════════════════════
# Jetson Prebuilt Artifact Builder
#
# Builds portable artifacts for Nvidia Jetson devices:
#   - llama-server binary (CUDA, arch-tagged for Xavier or Orin)
#   - PyTorch wheel (cp310, CUDA, arch-tagged)
#   - torchvision wheel (depends on PyTorch)
#   - Coral TPU kernel modules (gasket + apex, kernel-tagged)
#
# Auto-detects:
#   - JetPack version (5.x → Xavier/Volta arch 72, 6.x → Orin/Ampere arch 87)
#   - Output filenames tagged accordingly:
#       llama-server-xavier-aarch64       (jp5)
#       llama-server-orin-aarch64         (jp6)
#       gasket-jp5-xavier-aarch64.ko
#       gasket-jp6-orin-aarch64.ko
#
# Prerequisites (handled by from-zero scripts):
#   - python3.10 (for torch/torchvision builds)
#   - CUDA 12.x (for llama/torch CUDA builds)
#   - SQLite 3.45+ (only needed if you're building things that need it)
#   - NVMe at /mnt/nvme (recommended; build space is large)
#
# Usage:
#   tmux new -s build
#   bash build-jetson-prebuilts.sh --all                    # everything
#   bash build-jetson-prebuilts.sh --llama --coral          # just two
#   bash build-jetson-prebuilts.sh --pytorch --torchvision  # ML stack only
#   bash build-jetson-prebuilts.sh --coral                  # Coral .ko modules only
#
# Output: $PREBUILT_DIR (default /mnt/nvme/prebuilt, falls back to ~/prebuilt)
# Resumable: re-run after a failure, completed phases skip
# ══════════════════════════════════════════════════════════════

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# The rest of this script, in pieces
# ─────────────────────────────────────────────────────────────
#
# SOURCED, NOT EXECUTED, and that distinction is the whole design. The phases
# hand things to each other through shell variables - build_pytorch sets
# SEREN_TORCH_WHEEL and ensure_torch reads it three phases later, note_skip
# appends to SEREN_SKIPPED and the summary reads it at the end. Run as
# subprocesses those hand-offs would each need a serialised contract, and every
# one of those is a new seam to get wrong. Sourced, they keep working exactly as
# they did when this was one file.
#
# lib/ and phases/ therefore contain FUNCTION DEFINITIONS ONLY. Nothing in them
# runs at source time, so the order they are read in cannot matter and the glob
# below is free to be alphabetical. Every line of imperative setup - argument
# parsing, platform detection, the directory layout, the phase table - stayed
# in this file, in the order it was already in.
#
# THE FILE IS NO LONGER SELF-CONTAINED, which matters because these get moved
# to the boxes by hand. A lone build-jetson-prebuilts.sh on a Jetson used to
# work; now it needs its directory. Said plainly here rather than discovered as
# "build_pytorch: command not found" forty minutes in.
SEREN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -d "$SEREN_ROOT/lib" ] || [ ! -d "$SEREN_ROOT/phases" ]; then
    echo "This script needs lib/ and phases/ beside it, and $SEREN_ROOT has neither." >&2
    echo "Copy the whole directory to the box, not just this file:" >&2
    echo "    rsync -a --delete <repo>/ ${USER:-you}@<box>:~/SerenSystemPrebuilts/" >&2
    exit 1
fi
for _seren_part in "$SEREN_ROOT"/lib/*.sh "$SEREN_ROOT"/phases/*.sh; do
    [ -r "$_seren_part" ] || { echo "cannot read $_seren_part" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$_seren_part"
done
unset _seren_part

# ─────────────────────────────────────────────────────────────
# Defaults & flag parsing
# ─────────────────────────────────────────────────────────────
BUILD_LLAMA=false
BUILD_PYTORCH=false
BUILD_TORCHVISION=false
BUILD_CORAL=false
BUILD_PYTHON=false
BUILD_SQLITE=false
BUILD_BITSANDBYTES=false
BUILD_VENDOR=false
BUILD_VLLM=false
BUILD_WHEELHOUSE=false
BUILD_SELFTEST=false
BUILD_CUDADEBS=false
DO_VERIFY=false
# The default closure is deliberately small - see the note in build_wheelhouse.
WHEELHOUSE_PKGS="pip setuptools wheel numpy"
WHEELHOUSE_REQS=""
# Which apt packages count as "the CUDA layer". Matched against the package
# NAME only, never the version string. Override with --cuda-debs-match.
CUDA_DEB_MATCH="cuda|cudnn|cublas|cufft|curand|cusolver|cusparse|npp|nvinfer|nvjpeg|nvjitlink|nvrtc|nvtx|tensorrt|nvidia-l4t|nvidia-jetpack|nvidia-container|libnvidia"
USER_VLLM_VERSION=""
VENDOR_PKGS="torch torchvision"
VENDOR_WHEELS=""
VENDOR_INDEX=""
VENDOR_PYTHON=""
VENDOR_TORCH_VERSION=""
VENDOR_TVISION_VERSION=""
USER_PLATFORM=""
USER_PYBIN=""
USER_BNB_VERSION=""
KEEP_SOURCES=false
VLLM_WHEEL_ONLY=false
USER_LLAMA_REF=""
USER_GASKET_REF=""
USER_BUILD_DIR=""
USER_OUTPUT_DIR=""
USER_MAX_JOBS=""
USER_CUDA_HOST_CC=""


# Kept because the parse loop below SHIFTS them away, and the root guard
# wants to hand back a command you can actually paste.
SEREN_ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case "$1" in
        --llama)        BUILD_LLAMA=true; shift ;;
        --pytorch)      BUILD_PYTORCH=true; shift ;;
        --torchvision)  BUILD_TORCHVISION=true; shift ;;
        --coral)        BUILD_CORAL=true; shift ;;
        --python)       BUILD_PYTHON=true; shift ;;
        --sqlite)       BUILD_SQLITE=true; shift ;;
        --bitsandbytes) BUILD_BITSANDBYTES=true; shift ;;
        --platform)     USER_PLATFORM="$2"; shift 2 ;;
        --python-bin)   USER_PYBIN="$2"; shift 2 ;;
        --bitsandbytes-version) USER_BNB_VERSION="$2"; shift 2 ;;
        --vllm)         BUILD_VLLM=true; shift ;;
        --vllm-version) USER_VLLM_VERSION="$2"; shift 2 ;;
        --vendor)       BUILD_VENDOR=true; shift ;;
        --wheelhouse)   BUILD_WHEELHOUSE=true; shift ;;
        --wheelhouse-reqs) WHEELHOUSE_REQS="$2"; shift 2 ;;
        --cuda-debs|--cudadebs) BUILD_CUDADEBS=true; shift ;;
        --cuda-debs-match) CUDA_DEB_MATCH="$2"; shift 2 ;;
        --selftest)     BUILD_SELFTEST=true; shift ;;
        --verify-archive) DO_VERIFY=true; shift ;;
        --vendor-pkgs)  VENDOR_PKGS="$2"; shift 2 ;;
        --vendor-wheel) VENDOR_WHEELS="$VENDOR_WHEELS $2"; shift 2 ;;
        --vendor-index) VENDOR_INDEX="$2"; shift 2 ;;
        --vendor-python) VENDOR_PYTHON="$2"; shift 2 ;;
        --vendor-torch-version) VENDOR_TORCH_VERSION="$2"; shift 2 ;;
        --vendor-torchvision-version) VENDOR_TVISION_VERSION="$2"; shift 2 ;;
        --keep-sources) KEEP_SOURCES=true; shift ;;
        --vllm-wheel-only) VLLM_WHEEL_ONLY=true; shift ;;
        --llama-ref)    USER_LLAMA_REF="$2"; shift 2 ;;
        --gasket-ref)   USER_GASKET_REF="$2"; shift 2 ;;
        # --all MEANS ALL, which it did not. It set four of seven, so the
        # two Xavier-only tarballs and bitsandbytes were silently absent from
        # every "full" build - which is a bad shape for an archive whose whole
        # job is completeness. Phases the platform does not support skip with a
        # reason of their own; that is the right place for that decision, not
        # a flag that quietly means "most".
        --all)          BUILD_LLAMA=true; BUILD_PYTORCH=true; BUILD_TORCHVISION=true
                        BUILD_CORAL=true; BUILD_PYTHON=true; BUILD_SQLITE=true
                        BUILD_BITSANDBYTES=true; BUILD_VENDOR=true
                        BUILD_VLLM=true; BUILD_WHEELHOUSE=true
                        BUILD_CUDADEBS=true; BUILD_SELFTEST=true; shift ;;
        --build-dir)    USER_BUILD_DIR="$2"; shift 2 ;;
        --output-dir)   USER_OUTPUT_DIR="$2"; shift 2 ;;
        --max-jobs)     USER_MAX_JOBS="$2"; shift 2 ;;
        --cuda-host-compiler) USER_CUDA_HOST_CC="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              fail "Unknown option: $1" ;;
    esac
done

# DERIVED FROM THE TOGGLES, NOT A SECOND LIST OF THEM.
#
# This was a hand-written condition naming six flags by name, and when a
# seventh (--bitsandbytes) was added it was not updated - so the script parsed
# the flag, set its variable, and then refused to run because "no build flag
# given". The flag existed in three places (the variable, the case branch, the
# usage text) and was missing from the fourth, which is what a second source of
# truth always costs.
#
# Every build toggle is a BUILD_<NAME> boolean set to the literal true/false.
# Ask the shell which of those are set, instead of restating the list. The two
# BUILD_ names that hold paths rather than booleans are excluded explicitly and
# would fail the = "true" test anyway - belt and braces, because this is the
# line that decides whether the script does anything at all.
build_requested=false
build_available=""
for _v in $(compgen -A variable BUILD_ 2>/dev/null); do
    case "$_v" in BUILD_DIR|BUILD_INFO|BUILD_FS_AVAIL_GB) continue ;; esac
    [ "${!_v}" = "true" ] || [ "${!_v}" = "false" ] || continue
    # BUILD_TORCHVISION -> --torchvision
    _f="$(echo "${_v#BUILD_}" | tr '[:upper:]' '[:lower:]')"
    build_available="${build_available:+$build_available }--${_f}"
    [ "${!_v}" = "true" ] && build_requested=true
done
if ! $build_requested && ! $DO_VERIFY; then
    fail "No build flag given. Pass --all, --verify-archive, or any of: ${build_available}. Try -h."
fi
# --verify-archive READS an archive; it must not also build one. Silently
# ignoring the combination would be worse than refusing it: you would wait
# through a four-hour build to find out the verification never ran.
if $DO_VERIFY && $build_requested; then
    fail "--verify-archive builds nothing - run it on its own, after the build."
fi

# Validate --max-jobs if provided
if [ -n "$USER_MAX_JOBS" ]; then
    if ! [[ "$USER_MAX_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        fail "--max-jobs must be a positive integer (got: $USER_MAX_JOBS)"
    fi
fi

detect_platform

# ─────────────────────────────────────────────────────────────
# Which Python builds the wheels
# ─────────────────────────────────────────────────────────────
#
# THIS USED TO BE THE LITERAL STRING python3.10, TWENTY TIMES OVER. True for
# both Jetsons and false for the Spark, which is Ubuntu 24.04 and ships 3.12 -
# so the script could not build a wheel there at all, and if it somehow had,
# the wheel would have carried a cp310 tag for an interpreter that was not
# used. The cpXX tag in every artifact name comes from whichever interpreter
# runs setup.py, so getting this right is what makes the filenames honest.
#
# Order: --python-bin wins, then the platform's expected version, then a probe.
# The probe WARNS rather than proceeding quietly, because a wheel built by an
# unexpected interpreter is a thing you want to know about before you ship it
# as a backup.
case "$JP_FAMILY" in
    jp5) EXPECTED_PY="python3.10" ;;   # built from source; JP5 is Ubuntu 20.04
    jp6) EXPECTED_PY="python3.10" ;;   # JetPack 6 / Ubuntu 22.04 native
    jp7) EXPECTED_PY="python3.12" ;;   # DGX Spark / Ubuntu 24.04 native
    *)   EXPECTED_PY="python3" ;;
esac

if [ -n "$USER_PYBIN" ]; then
    PYBIN="$USER_PYBIN"
    command -v "$PYBIN" &>/dev/null || fail "--python-bin '$PYBIN' not found on PATH"
elif command -v "$EXPECTED_PY" &>/dev/null; then
    PYBIN="$EXPECTED_PY"
else
    PYBIN=""
    for _c in python3.12 python3.11 python3.10 python3; do
        command -v "$_c" &>/dev/null && { PYBIN="$_c"; break; }
    done
    [ -n "$PYBIN" ] || fail "no python3 found - $PLATFORM_TAG expects $EXPECTED_PY"
    warn "$EXPECTED_PY not found on this $PLATFORM_TAG; falling back to $PYBIN."
    warn "  Wheels will be tagged for $PYBIN, not $EXPECTED_PY. Pass --python-bin"
    warn "  if that is not what you want."
fi
PYTAG="$("$PYBIN" -c 'import sys;print("cp%d%d" % sys.version_info[:2])' 2>/dev/null || echo "cp???")"

# ─────────────────────────────────────────────────────────────
# Output dir + build dir + state file
# ─────────────────────────────────────────────────────────────
# Output dir: where finished artifacts get staged
if [ -n "$USER_OUTPUT_DIR" ]; then
    PREBUILT_DIR="$USER_OUTPUT_DIR"
elif [ -d /mnt/nvme ]; then
    PREBUILT_DIR="/mnt/nvme/prebuilt"
else
    PREBUILT_DIR="$HOME/prebuilt"
    warn "No /mnt/nvme - using $PREBUILT_DIR (make sure you have ~30GB free)"
fi

# Build dir: where pytorch/torchvision source trees get cloned + compiled
# This is where space goes - pytorch alone needs ~25GB during build.
if [ -n "$USER_BUILD_DIR" ]; then
    BUILD_DIR="$USER_BUILD_DIR"
elif [ -d /mnt/nvme ]; then
    BUILD_DIR="/mnt/nvme"
else
    BUILD_DIR="$HOME"
fi

# Validate dirs exist or can be created, and are writable
mkdir -p "$PREBUILT_DIR" || fail "Cannot create output dir: $PREBUILT_DIR"
mkdir -p "$BUILD_DIR"    || fail "Cannot create build dir:  $BUILD_DIR"
[ -w "$PREBUILT_DIR" ]   || fail "Output dir not writable: $PREBUILT_DIR"
[ -w "$BUILD_DIR" ]      || fail "Build dir not writable:  $BUILD_DIR"

# Redirect ALL temp writes off the eMMC, once, for every build step.
# Compilers (gcc/nvcc), linkers (ld/collect2), cmake, and python setup.py all
# scribble intermediate files to $TMPDIR - which defaults to /tmp, on Jetson
# the tiny ~32GB eMMC root. A big static link or a pytorch build blows that
# out with "No space left on device", surfacing as a misleading
# "collect2: ld returned 1". Setting TMPDIR here means every child process
# inherits it - no per-build-step export needed, and any build step added
# later is automatically covered. TMPDIR is the var the GNU toolchain
# actually honors on Linux; TMP/TEMP are Windows-isms we don't need.
export TMPDIR="$BUILD_DIR/tmp"
mkdir -p "$TMPDIR"

# Sanity check: warn if build dir is on eMMC (small) and we're building pytorch
if $BUILD_PYTORCH || $BUILD_TORCHVISION; then
    BUILD_FS_AVAIL_GB=$(df -BG "$BUILD_DIR" | awk 'NR==2 {gsub("G",""); print $4}')
    if [ -n "$BUILD_FS_AVAIL_GB" ] && [ "$BUILD_FS_AVAIL_GB" -lt 30 ] 2>/dev/null; then
        warn "Build dir $BUILD_DIR has only ${BUILD_FS_AVAIL_GB}GB free - pytorch needs ~25GB."
        warn "If this is the eMMC, pass --build-dir /mnt/nvme/build or similar."
        warn "Continuing in 5 seconds - Ctrl-C to abort..."
        sleep 5
    fi
fi

# ── nvcc's host compiler ──
# NVCC_PREPEND_FLAGS rather than CMAKE_CUDA_HOST_COMPILER on purpose: the cmake
# variable is baked into the configured build tree, so changing it invalidates
# the cache and rebuilds everything. This one is read by nvcc at exec time, so
# a build that stopped at object 2250 picks up the new host compiler and keeps
# going from 2250.
#
# THE MIXED-OBJECT CAVEAT, because it matters for an archive: objects compiled
# before the switch used the old host compiler. GCC's C++ ABI has been stable
# since 5.x so they link, but the provenance file records ONE gcc version and
# would be describing only part of the wheel. Use this to find out whether a
# host compiler is the problem; then rebuild clean for the artifact you ship.
if [ -n "$USER_CUDA_HOST_CC" ]; then
    [ -x "$USER_CUDA_HOST_CC" ] || fail "--cuda-host-compiler: not executable: $USER_CUDA_HOST_CC"
    export NVCC_PREPEND_FLAGS="${NVCC_PREPEND_FLAGS:-} -ccbin $USER_CUDA_HOST_CC"
    log "nvcc host cc: $USER_CUDA_HOST_CC ($("$USER_CUDA_HOST_CC" --version 2>/dev/null | head -1))"
fi

# MAX_JOBS resolution - used only for pytorch/torchvision
if [ -n "$USER_MAX_JOBS" ]; then
    RESOLVED_MAX_JOBS="$USER_MAX_JOBS"
else
    RESOLVED_MAX_JOBS="$(nproc)"
fi

# WHOSE ARTIFACTS ARE ALREADY IN HERE? Wheel names carry cp310/cp312 but NOT
# the GPU arch, so a Spark build and a Xavier build produce colliding filenames
# in a shared --output-dir. That matters most for exactly the thing these are
# for: a spare wheel you grab months later and cannot tell apart. The build info
# files are per-platform, so they are a reliable witness.
for _bi in "$PREBUILT_DIR"/BUILD_INFO_*.txt; do
    [ -e "$_bi" ] || continue
    case "$(basename "$_bi")" in
        "BUILD_INFO_${PLATFORM_TAG}_${JP_FAMILY}.txt") ;;
        *) warn "$PREBUILT_DIR already holds artifacts from another platform ($(basename "$_bi"))."
           warn "  Wheel names do not carry the GPU arch, so these can overwrite each other."
           warn "  Consider --output-dir $PREBUILT_DIR/${PLATFORM_TAG}-${JP_FAMILY}" ;;
    esac
done

# ═════════════════════════════════════════════════════════════
#  PROVENANCE - what a stranger needs when the upstreams are gone
# ═════════════════════════════════════════════════════════════
#
# THE PREMISE: in four years the person holding these files will not have this
# script, this box, or the repositories it clones from. llama.cpp has ALREADY
# moved organisation once (ggerganov -> ggml-org). A binary with no record of
# what produced it is a dead end - it either works or it does not, and there is
# no way to find out why, or to make another one.
#
# So every build writes three things next to the artifacts:
#
#   PROVENANCE-<platform>-<jp>.txt   what machine, what toolchain, what source
#                                    commit produced each artifact
#   SHA256SUMS                       verifiable with sha256sum -c, offline
#   sources/*.tar.gz                 (--keep-sources) the exact trees that were
#                                    compiled, so the thing can be REBUILT and
#                                    not merely re-downloaded
#
# The third is the one that makes this an archive rather than a cache.

# Artifacts go in a per-platform folder. Wheel names carry cp310/cp312 but NOT
# the GPU arch, so a Xavier torch and an Orin torch are byte-different and
# identically named. One folder per box makes that impossible to get wrong, and
# it matches the per-platform release tags these get uploaded to.
#
# THE STATE FILE DELIBERATELY STAYS AT THE PARENT. Moving it would orphan the
# record of every phase already completed - and re-running a four-hour pytorch
# build to tidy a directory layout is not a trade worth making.
PLATFORM_DIR="$PREBUILT_DIR/${PLATFORM_TAG}-${JP_FAMILY}"
mkdir -p "$PLATFORM_DIR" || fail "Cannot create $PLATFORM_DIR"
PROVENANCE="$PLATFORM_DIR/PROVENANCE-${PLATFORM_TAG}-${JP_FAMILY}.txt"
SOURCES_DIR="$PLATFORM_DIR/sources"


# note_skip / note_built - AN ARCHIVE HAS TO KNOW WHAT IT IS MISSING.
#
# Phases skip for good reasons (wrong platform, vendor-supplied, unsupported),
# and a skip scrolls past in a log that is thousands of lines long. For a build
# cache that is fine. For an archive of record it is not: "I ran --all" has to
# be distinguishable from "I have everything", and the only honest way to do
# that is to count what did not happen and say so at the end, next to the
# artifact list, where somebody will actually read it.
SEREN_SKIPPED=()
SEREN_BUILT=()
# Phases that were attempted and broke, or were blocked by one that did. Kept
# apart from SEREN_SKIPPED on purpose - see note_fail.
SEREN_FAILED=()


STATE_FILE="$PREBUILT_DIR/.build.state.json"
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

ensure_jq


# ─────────────────────────────────────────────────────────────
# Banner + prereqs
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Jetson Prebuilt Artifact Builder${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
log "Platform:    $PLATFORM_TAG ($JP_FAMILY)"
log "Kernel:      $KERNEL_VER"
log "CUDA arch:   $CUDA_ARCH"
log "PyTorch:     $PYTORCH_VERSION (torchvision $TORCHVISION_VERSION)"
log "Output dir:  $PREBUILT_DIR"
log "Build dir:   $BUILD_DIR"
log "Max jobs:    $RESOLVED_MAX_JOBS$([ -z "$USER_MAX_JOBS" ] && echo ' (auto, all cores)' || echo ' (user set)')"
# EVERY flag, not four of six. This line said
    #   llama=false pytorch=false torchvision=false coral=false
    # during a bitsandbytes build, which reads as "building nothing".
log "Building:    llama=$BUILD_LLAMA pytorch=$BUILD_PYTORCH torchvision=$BUILD_TORCHVISION coral=$BUILD_CORAL"
log "             python=$BUILD_PYTHON sqlite=$BUILD_SQLITE bitsandbytes=$BUILD_BITSANDBYTES"
log "             vllm=$BUILD_VLLM vendor=$BUILD_VENDOR"
log "             wheelhouse=$BUILD_WHEELHOUSE cuda-debs=$BUILD_CUDADEBS selftest=$BUILD_SELFTEST"
$DO_VERIFY && log "             VERIFY ONLY - nothing will be built"
echo ""

# ── DO NOT RUN THIS UNDER SUDO ──────────────────────────────────────────────
#
# Caught the hard way, twice in one sitting. `sudo ./build-jetson-prebuilts.sh`
# fails in two different places for two different reasons, and NEITHER error
# message mentions sudo:
#
#   1. PATH. sudo replaces it with sudoers' secure_path, which has no
#      the CUDA bin directory - so nvcc "does not exist" on a box where
#      `which nvcc` answers fine. (resolve_cuda_home below now runs before the
#      preflight checks and repairs this one without hardcoding a version.)
#   2. HOME. sudo sets HOME=/root, so every `pip install --user` package the
#      real user owns - torch included - becomes invisible. The build then
#      reports "torch not installed" about a torch that is installed.
#
# And a build run as root leaves root-owned wheels and source trees behind for
# the next non-root run to trip over.
#
# This script escalates on its own where it actually needs to (apt, chown,
# kernel modules). Run it as yourself.
if [ "$(id -u)" -eq 0 ] && [ "${SEREN_ALLOW_ROOT:-0}" != "1" ]; then
    warn "Running as root${SUDO_USER:+ (via sudo, as $SUDO_USER)}."
    warn ""
    warn "  sudo replaces PATH with sudoers' secure_path and sets HOME=/root, so"
    warn "  nvcc and any 'pip install --user' package (torch!) go missing - and"
    warn "  the resulting errors blame the toolchain instead of the shell."
    warn ""
    warn "  This script already sudo's for the parts that need root."
    if [ -n "${SUDO_USER:-}" ]; then
        warn "  Run it as yourself instead:"
        warn "     ./$(basename "$0") ${SEREN_ORIGINAL_ARGS[*]}"
        warn "  If /mnt/nvme is not writable by $SUDO_USER, fix that once:"
        warn "     sudo chown -R $SUDO_USER:$SUDO_USER /mnt/nvme"
    fi
    warn ""
    warn "  Override with SEREN_ALLOW_ROOT=1 if you really mean it."
    fail "Refusing to build as root."
fi

# Per-target prereq checks
need_python310=false
need_nvcc=false
$BUILD_LLAMA       && need_nvcc=true
$BUILD_PYTORCH     && { need_python310=true; need_nvcc=true; }
$BUILD_TORCHVISION && { need_python310=true; need_nvcc=true; }
# It compiles .cu sources, so it needs the toolkit just as much as the others.
$BUILD_BITSANDBYTES && { need_python310=true; need_nvcc=true; }
# Everything that configures with cmake. Checked here rather than discovered
# 430MB into a git clone.
need_cmake=false
$BUILD_LLAMA        && need_cmake=true
$BUILD_PYTORCH      && need_cmake=true
$BUILD_TORCHVISION  && need_cmake=true
$BUILD_BITSANDBYTES && need_cmake=true

CUDA_HOME="$(resolve_cuda_home || true)"
if [ -n "$CUDA_HOME" ]; then
    export CUDA_HOME
    export PATH="$HOME/.local/bin:$CUDA_HOME/bin:/usr/local/bin:$PATH"
    # compat/ only exists on the Jetsons; a missing entry on LD_LIBRARY_PATH is
    # ignored, so naming it unconditionally costs nothing.
    export LD_LIBRARY_PATH="$CUDA_HOME/compat:$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"
else
    export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
    # Not fatal HERE - only the phases that compile CUDA care, and need_nvcc
    # below is what refuses. Said now so the reason is visible before the
    # error rather than inferred from it.
    warn "No CUDA toolkit found: \$CUDA_HOME unset, no nvcc on PATH, nothing at /usr/local/cuda*"
fi

if $need_python310; then
    command -v "$PYBIN" &>/dev/null || fail "$PYBIN required for pytorch/torchvision build - run from-zero script first"
    log "python:      $("$PYBIN" --version 2>&1) [$PYBIN, $PYTAG]"
fi
if $need_cmake; then
    # NOT fatal on its own - the apt install below adds it. This exists so the
    # log says what is about to happen instead of dying at the first configure.
    if command -v cmake &>/dev/null; then
        log "cmake:       $(cmake --version | head -1 | awk '{print $3}')"
    else
        warn "cmake not installed - it is in the apt list below and will be added"
    fi
fi
if $need_nvcc; then
    command -v nvcc &>/dev/null || fail "nvcc required - CUDA toolkit not found on PATH.
  Looked in: $PATH
  If nvcc exists somewhere else, this script's PATH export needs that directory."
    log "nvcc:        $(nvcc --version | grep release | awk '{print $6}' | cut -d',' -f1) [${CUDA_HOME:-?}]"
fi

# ── open the provenance record ──
# Written BEFORE anything is built, so a run that dies partway still leaves the
# environment it died in. Toolchain versions are captured from the machine, not
# assumed: four years from now "gcc 9.4.0 on Ubuntu 20.04" is the difference
# between reproducing this and guessing at it.
# NOT WHEN VERIFYING. This block truncates PROVENANCE and SHA256SUMS - which
# on a --verify-archive run would destroy the very checksums being checked
# before a single one was read.
if ! $DO_VERIFY; then
{
    echo "# SerenSystemPrebuilts provenance"
    echo "# Everything below was read from the machine that did the build."
    echo "built            $(date -Iseconds)"
    echo "host             $(uname -n)"
    echo "platform         ${PLATFORM_TAG}"
    echo "jp_family        ${JP_FAMILY}"
    echo "cuda_arch        sm_${CUDA_ARCH}"
    echo "kernel           $(uname -r)"
    echo "os               $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"
    echo "l4t              $(head -1 /etc/nv_tegra_release 2>/dev/null || echo 'n/a (not a Tegra release)')"
    echo "python           $("$PYBIN" --version 2>&1) [$PYBIN, $PYTAG]"
    echo "gcc              $(gcc --version 2>/dev/null | head -1 || echo absent)"
    echo "nvcc_host_cc     ${USER_CUDA_HOST_CC:-<distro default>}"
    echo "cmake            $(cmake --version 2>/dev/null | head -1 || echo absent)"
    echo "nvcc             $(nvcc --version 2>/dev/null | grep release | sed 's/^ *//' || echo absent)"
    echo "cuda_home        ${CUDA_HOME:-<none found>}"
    echo "builder          $(basename "$0") ${SEREN_ORIGINAL_ARGS[*]}"
    echo ""
    echo "# The held baseline - what THIS archive is pinned to, per platform."
    echo "baseline python        ${PYTHON_VERSION}"
    echo "baseline sqlite        ${SQLITE_VERSION}"
    echo "baseline pytorch       ${PYTORCH_VERSION:-<none for this platform>}"
    echo "baseline torchvision   ${TORCHVISION_VERSION:-<none for this platform>}"
    echo "baseline bitsandbytes  ${BITSANDBYTES_VERSION:-<none for this platform>}"
    echo "baseline numpy         build ${NUMPY_BUILD_VERSION} / runtime ${NUMPY_RUNTIME_VERSION}"
    echo "baseline vllm          ${VLLM_VERSION:-<unsupported on this GPU>}"
    echo "baseline vllm-torch    ${VLLM_TORCH_VERSION} (vLLM's own venv, not the one above)"
    echo "baseline llama.cpp     ${USER_LLAMA_REF:-<unpinned: master HEAD, sha recorded below>}"
    echo "baseline gasket        ${USER_GASKET_REF:-<unpinned: default HEAD, sha recorded below>}"
    echo ""
} > "$PROVENANCE"
: > "$PLATFORM_DIR/SHA256SUMS"
fi

# Common build deps (only install what's needed)
#
# CMAKE IS IN THIS LIST NOW, AND ITS ABSENCE WAS NOT THEORETICAL: a Xavier with
# build-essential, ninja and the full CUDA toolkit installed still died at
#   ./build-jetson-prebuilts.sh: line 436: cmake: command not found
# after cloning 430MB of llama.cpp. Every compiled target here configures with
# cmake, it was never installed by this script, and it was never checked for -
# so the failure landed mid-phase instead of in the preflight.
#
# $BUILD_BITSANDBYTES joins the trigger for the same reason: it compiles .cu
# sources and needs exactly this toolchain.
# ── DECLARED ONCE, USED TWICE ──
# This list is the toolchain every compiled phase needs. It is also exactly what
# the cudadebs phase archives, so a rebuild on a box whose mirror has aged out
# does not need the mirror. Two hand-maintained copies of the same list is how
# you end up archiving eleven of the twelve packages you actually depend on.
SEREN_APT_BUILD_DEPS=(
    build-essential git ninja-build pkg-config cmake python3-venv
    libopenblas-dev libopenmpi-dev libomp-dev
    libjpeg-dev libpng-dev libffi-dev libssl-dev
    # THE OPENMP FLAVOUR, EXPLICITLY. libopenblas-dev pulls the pthread build on
    # Debian and Ubuntu, and a pthread OpenBLAS nested inside torch's OpenMP is
    # what made the Xavier's first CPU matmul return NaN. See
    # ensure_openblas_openmp for the measurements. Named here as well as
    # selected below so it is in the closure the cudadebs phase archives - a fix
    # that only exists on the box that discovered it is not a fix.
    libopenblas0-openmp
)
if ! $DO_VERIFY && { $BUILD_LLAMA || $BUILD_PYTORCH || $BUILD_TORCHVISION || $BUILD_BITSANDBYTES; }; then
    apt_require "${SEREN_APT_BUILD_DEPS[@]}"
    ensure_openblas_openmp
fi


# ═════════════════════════════════════════════════════════════
#  A VENV PER PHASE - PEP 668 forced venvs; pip pins forced MORE THAN ONE
# ═════════════════════════════════════════════════════════════
#
# Ubuntu 24.04 marks the system interpreter EXTERNALLY-MANAGED, so every
# `pip install --user` in this script is refused outright:
#
#     error: externally-managed-environment
#     × This environment is externally managed
#
# --break-system-packages would silence it and is the wrong answer: it makes a
# build script write into the OS interpreter of a machine whose whole job is
# running something else.
#
# THAT ARGUMENT EARNED ONE VENV. It should have earned one PER PHASE, because
# these phases disagree about their dependencies on purpose:
#
#   pytorch       needs its build-time numpy pin to survive to the compiler
#   torchvision   must compile against the EXACT torch this archive just built
#   bitsandbytes  wants a clean interpreter it can stamp a version into
#   vllm          pins torch EXACTLY - that pin is the entire reason it gets its
#                 own venv at INSTALL time, and it was sharing one at BUILD time
#
# In a single venv those are resolved by whichever phase ran last, silently.
# Not hypothetical: build_torchvision used to end by reinstalling numpy at a
# different version "to restore runtime" - a line that only had to exist
# because the next phase was going to inherit the interpreter.
#
# So: $BUILD_DIR/seren-build-venvs/<phase>, each created from $PYBIN. Same
# major.minor, therefore the same cp tag - every wheel is tagged exactly as it
# was before and only the build-time dependencies moved. The torch handoff
# between phases is an explicit wheel install now instead of a shared
# site-packages, which is the point: a handoff you can see.
HOST_PYBIN="$PYBIN"
VENV_ROOT="$BUILD_DIR/seren-build-venvs"
# The PATH as it stood BEFORE any venv. use_venv rebuilds from this every time
# rather than prepending, because prepending leaves phase one's bin/ ahead of
# the system for phase four - the shared-state bug wearing a different hat.
SEREN_BASE_PATH="$PATH"


# ── the torch a phase needs, installed into THAT phase's venv ──
#
# THIS USED TO BE FREE, WHICH WAS THE PROBLEM. build_pytorch pip-installed its
# wheel into the shared venv and every later phase silently inherited it -
# convenient right up until vLLM's exact pin lands on the torch that
# torchvision compiled against.
#
# Order of preference, and the first entry is the one that matters: the wheel
# THIS archive built for sm_${CUDA_ARCH}, then one an earlier run left in the
# platform folder, then a vendored copy, then an index. An extension has to
# link the torch it will run beside, and on these boxes that is the local one -
# no index serves a Xavier sm_72 build at all.
SEREN_TORCH_WHEEL=""


# ── the cmake floor, per phase, worked out once ──
#
# WHOSE FLOOR IS HIGHEST WINS, and torch moved its own out from under this.
# pytorch <= 2.5 opens with cmake_minimum_required(3.18); 2.6 raised it to 3.27.
# jp6 and jp7 are both pinned to torch 2.11 now, and Ubuntu 22.04 on the Orin
# ships cmake 3.22.1 - so a flat 3.18 floor PASSES the preflight and then dies
# on pytorch's first configure line, which is the worst place to learn it.
# The floor has to be read off what is actually being built.
CMAKE_MIN_TORCH="3.18"
if [ -n "$PYTORCH_VERSION" ] && \
   [ "$(printf '%s\n%s\n' "2.6" "$PYTORCH_VERSION" | sort -V | head -1)" = "2.6" ]; then
    CMAKE_MIN_TORCH="3.27"
fi
if $need_cmake; then
    log "cmake floors: llama 3.18 | torch $CMAKE_MIN_TORCH | bitsandbytes 3.22.1 | vllm 3.27"
    log "             (per-venv, installed by ensure_cmake only where the system one is too old)"
fi

START_TIME=$(date +%s)
BUILD_INFO="$PREBUILT_DIR/BUILD_INFO_${PLATFORM_TAG}_${JP_FAMILY}.txt"
if ! $DO_VERIFY; then
{
    echo "Build started: $(date)"
    echo "Platform: $PLATFORM_TAG ($JP_FAMILY)"
    echo "Kernel: $KERNEL_VER"
    echo "Host: $(hostname)"
} > "$BUILD_INFO"
fi











# ═════════════════════════════════════════════════════════════
# Coral kernel modules (gasket + apex)
# ═════════════════════════════════════════════════════════════
















# ═════════════════════════════════════════════════════════════
# Dispatch - SQLite must run BEFORE Python in the same pipeline so
# build_python can link against the modern libsqlite3 in /usr/local.
# Both functions must be defined before this point (they are).
# ═════════════════════════════════════════════════════════════


# The summary used to sit HERE, which is before the phase table below and
# therefore before a single phase had run: every invocation announced "Build
# Complete", listed an empty folder and wrote "Total build time: 0 minutes"
# into BUILD_INFO, then started compiling. Moved to after the run loop, where
# the words are true.
# ═════════════════════════════════════════════════════════════
#  THE BUILD GRAPH - declared once, ordered by dependency
# ═════════════════════════════════════════════════════════════
#
# THESE USED TO RUN IN THE ORDER THEY HAPPENED TO BE WRITTEN, which was
#   llama -> pytorch -> torchvision -> bitsandbytes -> vendor -> coral
#         -> sqlite -> python
# and that is backwards where it matters. pytorch needs the Python this script
# builds, and that Python wants the SQLite this script builds - CPython
# otherwise links whatever libsqlite3-dev the distro ships (3.31 on 20.04),
# which ChromaDB then rejects. So `--all` on a genuinely fresh box built torch
# against an interpreter that did not exist yet. It has been working only
# because python3.10 survived from an earlier run.
#
# The README even said "if you are Python and need Sqlite make sure you build
# sqlite first" - a dependency that was known, written down in prose, and not
# enforced anywhere. That is the whole bug class: the fact existed, nothing
# acted on it.
#
# Now it is data. One row per phase: name | flag | state key | function | deps.
# The order of this table IS the compile order, deps are checked against what
# was actually requested, and adding a phase means adding a row.
declare -a PHASE_TABLE=(
    # leaves first - nothing else has to exist for these
    "sqlite|BUILD_SQLITE|sqlite_${JP_FAMILY}_${PLATFORM_TAG}|build_sqlite|"
    "python|BUILD_PYTHON|python_${JP_FAMILY}_${PLATFORM_TAG}|build_python|sqlite"
    # independent of the python stack entirely: C++ and a kernel module
    "llama|BUILD_LLAMA|llama_${PLATFORM_TAG}|build_llama|"
    "coral|BUILD_CORAL|coral_${JP_FAMILY}_${PLATFORM_TAG}|build_coral|"
    # independent of everything, and the one thing nobody else can rebuild
    "cudadebs|BUILD_CUDADEBS|cudadebs_${JP_FAMILY}_${PLATFORM_TAG}|build_cudadebs|"
    # the python stack, in the only order that works
    "pytorch|BUILD_PYTORCH|pytorch_${PLATFORM_TAG}|build_pytorch|python"
    "torchvision|BUILD_TORCHVISION|torchvision_${PLATFORM_TAG}|build_torchvision|pytorch"
    "bitsandbytes|BUILD_BITSANDBYTES|bitsandbytes_${PLATFORM_TAG}|build_bitsandbytes|pytorch"
    "vllm|BUILD_VLLM|vllm_${PLATFORM_TAG}|build_vllm|pytorch"
    # the dependency closure, seeded from the wheels built above
    "wheelhouse|BUILD_WHEELHOUSE|wheelhouse_${PLATFORM_TAG}|build_wheelhouse|pytorch"
    # mirrors of things other phases may have just installed
    "vendor|BUILD_VENDOR|vendor_${PLATFORM_TAG}_${JP_FAMILY}|build_vendor|"
    # LAST, ALWAYS. It is the only phase that asks whether any of this works.
    "selftest|BUILD_SELFTEST|selftest_${PLATFORM_TAG}|build_selftest|pytorch"
)

for _row in "${PHASE_TABLE[@]}"; do
    IFS='|' read -r _n _f _k _fn _deps <<< "$_row"
    [ "${!_f}" = "true" ] || continue
    for _d in ${_deps//,/ }; do
        _phase_requested "$_d" ||             warn "$_n depends on $_d, which was not requested - relying on whatever is already on this box"
    done
done

# ── said BEFORE the hours, not after them ──
#
# The summary at the end already points out when --keep-sources was not passed.
# That is the wrong end of a four-hour build: by the time you read it the trees
# have been used and the only way to get the sources is to run the whole thing
# again. The point of this archive is to survive an upstream disappearing, and
# a wheel without the source that made it only survives until the day you need
# to change something.
#
# NOT DEFAULTED ON, deliberately. pytorch alone is ~30GB of checkout, and the
# Xavier's eMMC is 32GB - flipping this default would turn "no sources" into
# "no space" on the one box that needs the archive most. So it stays a choice,
# made loudly, while it is still free to make.
if ! $DO_VERIFY && ! $KEEP_SOURCES && \
   { $BUILD_LLAMA || $BUILD_PYTORCH || $BUILD_TORCHVISION || $BUILD_BITSANDBYTES || $BUILD_VLLM; }; then
    warn "--keep-sources was NOT passed: the source trees will be discarded."
    warn "  You will get wheels and binaries, and no way to rebuild them if an"
    warn "  upstream tag, repo or index goes away - which is the exact failure"
    warn "  this archive exists to outlive. Decide now; afterwards costs another run."
    warn "  Needs roughly 30GB extra for pytorch. Ctrl-C and re-run with"
    warn "  --keep-sources if that is what you want."
fi

# ── the box as it stood, recorded before anything is compiled ──
# Down here rather than beside BUILD_INFO because bash resolves a function name
# when the call RUNS, and record_system_snapshot is defined with the phases -
# calling it up there was a "command not found" on every run.
$DO_VERIFY || record_system_snapshot

# ── verify instead of building, if that is what was asked ──
# Here rather than at parse time because it needs every function above, and the
# platform/output-dir resolution that decides WHICH folder to look at.
if $DO_VERIFY; then
    if verify_archive; then exit 0; else exit 1; fi
fi


# ── run them, in table order ──
#
# ONE PHASE FAILING NO LONGER ENDS THE RUN, and the reason is an overnight build
# that got twenty minutes in. bitsandbytes died on a version literal upstream had
# moved, `fail` did what it has always done - exit 1 - and vllm, wheelhouse,
# vendor and selftest never ran. None of those four depend on bitsandbytes in any
# way. Eight hours of unattended machine time bought nothing, because a phase
# whose own log line calls it "insurance, not a fix" was allowed to speak for
# the entire archive.
#
# So a phase now runs inside a subshell. `fail` is `exit 1` in a hundred places
# and rewriting all of them was never the move; containing them is one line. The
# subshell exits, the loop reads the status, records it with note_fail, and goes
# on to the phases that do not need it. See _seren_export_handoff for the three
# variables that have to survive that boundary and why nothing else does.
#
# WHAT STILL STOPS DEPENDENTS: the deps column. pytorch failing skips
# torchvision, bitsandbytes, vllm, wheelhouse and selftest, because building any
# of them against a torch that is not there produces a worse outcome than not
# building them - a wheel that installs and dies at import. That is the same
# judgement the phases already make internally about mismatched torch; this just
# applies it one level up.
#
# AND THE RUN STILL FAILS. Continuing is not forgiving: every failure is on
# stdout as it happens, listed again in the summary, written to the provenance
# file, and the script exits non-zero at the end. What changes is WHEN you find
# out about the other eleven phases - now, instead of on the next run.
for _row in "${PHASE_TABLE[@]}"; do
    IFS='|' read -r _n _f _k _fn _deps <<< "$_row"
    [ "${!_f}" = "true" ] || continue

    _blocker="$(_phase_first_failed_dep "$_deps")"
    if [ -n "$_blocker" ]; then
        warn "$_n needs $_blocker, which failed earlier in this run - not attempting it."
        warn "  Building it anyway would produce an artifact against a dependency"
        warn "  that is not there, which is worse than not having one."
        note_fail "$_n" "dependency $_blocker failed"
        continue
    fi

    # SELFTEST IS NEVER "ALREADY COMPLETE". Every other phase is expensive and
    # resumable, which is what the state file is for. A verification you skipped
    # because you ran it last week is not a verification - and the artifacts it
    # checks may well have been rebuilt since.
    #
    # WHEELHOUSE IS THE SAME KIND OF THING, and leaving it out of this cost the
    # Xavier a self-sufficient archive. It is not a build; it is the dependency
    # CLOSURE OVER whatever wheels exist when it runs. An earlier run closed
    # over torch alone and got marked complete. torchvision was built later,
    # bringing a dependency on requests with it, and because wheelhouse was
    # "already complete" that requirement was never mirrored - so the offline
    # install in selftest failed on a package nothing had ever been asked to
    # fetch:
    #
    #   ERROR: Could not find a version that satisfies the requirement requests
    #   OFFLINE INSTALL FAILED - the archive cannot satisfy its own dependencies
    #
    # A closure is only valid for the set it closed over. Both of these phases
    # are functions of the other artifacts rather than artifacts themselves, and
    # state-skipping a derived thing caches an answer to a question that has
    # since changed. Re-running is cheap: pip reuses --find-links against the
    # existing wheelhouse and only fetches what is genuinely new.
    #
    # CUDADEBS IS THE THIRD, and it cost the Xavier its OpenBLAS deb. That phase
    # closes over WHAT IS INSTALLED ON THIS BOX RIGHT NOW. It ran, got marked
    # complete, and then the run that diagnosed the pthread/OpenMP fault
    # installed libopenblas0-openmp - the one package that makes that archive
    # restore correctly. Being "already complete", cudadebs never saw it. The
    # artifacts were right, the provenance recorded the right answer, INSTALL.sh
    # knew to select it, and the .deb that makes any of that possible offline
    # was not there.
    #
    # Same test as the other two: is this phase a thing, or a function of other
    # things? It is a function, so it runs every time and skips per-package on
    # what is already in the folder.
    case "$_n" in
        selftest|wheelhouse|cudadebs) ;;
        *) if phase_skip_if_done "$_k"; then continue; fi ;;
    esac

    _rc=0
    _handoff="$(mktemp)"
    (
        trap '_seren_export_handoff "$_handoff"' EXIT
        "$_fn"
    ) || _rc=$?
    [ -s "$_handoff" ] && source "$_handoff"
    rm -f "$_handoff"

    if [ "$_rc" -ne 0 ]; then
        warn "$_n FAILED (exit $_rc). Not marking it complete; re-running retries it."
        warn "  Carrying on with the phases that do not depend on it."
        note_fail "$_n" "exit $_rc"
        continue
    fi

    if _phase_skipped_itself "$_n"; then
        warn "$_n skipped itself - NOT marking it complete, so fixing the cause"
        warn "  and re-running actually retries it. Reason is in $PROVENANCE."
    else
        phase_mark "$_k"
    fi
done

# ── the folder explains itself from here on ──
write_install_script

# ═════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════
END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))
echo "Total build time: ${ELAPSED} minutes" >> "$BUILD_INFO"

echo ""
if [ ${#SEREN_FAILED[@]} -gt 0 ]; then
    echo -e "${RED}══════════════════════════════════════════${NC}"
    echo -e "${RED}  Build FINISHED WITH FAILURES${NC}"
    echo -e "${RED}══════════════════════════════════════════${NC}"
else
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Build Complete${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
fi
echo ""
ls -lh "$PLATFORM_DIR/" | grep -v '^total' | grep -v '^\.build'

# ── what broke, first and loudest ──
# Above the skip list deliberately. A skip is a decision; a failure is a thing
# to go and fix, and it is the reason this run exits non-zero.
if [ ${#SEREN_FAILED[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}FAILED (${#SEREN_FAILED[@]}):${NC}"
    for _s in "${SEREN_FAILED[@]}"; do
        printf "  %-16s %s\n" "${_s%%|*}" "${_s#*|}"
    done
    echo -e "  ${RED}None of these were marked complete, so re-running retries them${NC}"
    echo -e "  ${RED}once the cause is fixed. Nothing else has to be rebuilt.${NC}"
fi

# ── completeness, said out loud ──
echo ""
if [ ${#SEREN_SKIPPED[@]} -gt 0 ]; then
    echo -e "${YELLOW}NOT in this archive (${#SEREN_SKIPPED[@]}):${NC}"
    for _s in "${SEREN_SKIPPED[@]}"; do
        printf "  %-16s %s\n" "${_s%%|*}" "${_s#*|}"
    done
    echo -e "  ${YELLOW}Each of these is a deliberate skip, not a failure - but an archive${NC}"
    echo -e "  ${YELLOW}is only as good as what is in it. Worth a look before you publish.${NC}"
else
    echo -e "${GREEN}Nothing was skipped - every requested phase produced artifacts.${NC}"
fi

echo ""
echo -e "${GREEN}Archive records:${NC}"
echo "  provenance : $PROVENANCE"
echo "  checksums  : $PLATFORM_DIR/SHA256SUMS   (sha256sum -c SHA256SUMS)"
if $KEEP_SOURCES && [ -d "$SOURCES_DIR" ]; then
  echo "  sources    : $SOURCES_DIR ($(du -sh "$SOURCES_DIR" 2>/dev/null | cut -f1))"
else
  echo -e "  ${YELLOW}sources    : not archived - pass --keep-sources to keep the trees"
  echo -e "               that were actually compiled. Without them these binaries"
  echo -e "               cannot be rebuilt if an upstream goes away.${NC}"
fi
echo "  upload the whole ${PLATFORM_TAG}-${JP_FAMILY}/ folder to one release tag"
echo ""
cat "$BUILD_INFO"
echo ""
log "Upload to release: https://github.com/ChadRoesler/SerenSystemPrebuilts/releases"
echo ""
if [ ${#SEREN_FAILED[@]} -gt 0 ]; then
    echo -e "${RED}══════════════════════════════════════════${NC}"
    echo -e "${RED}  ${ELAPSED} minutes. ${#SEREN_FAILED[@]} phase(s) failed - see above.${NC}"
    echo -e "${RED}══════════════════════════════════════════${NC}"
    echo ""
    # NON-ZERO, ALWAYS. Carrying on past a failed phase is about not wasting the
    # rest of the run; it is not about pretending the run was clean. Anything
    # driving this from cron or a pipeline has to be able to tell.
    exit 1
fi
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  ${ELAPSED} minutes. Never build these again.${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""

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
#   bash build-prebuilts.sh --all                    # everything
#   bash build-prebuilts.sh --llama --coral          # just two
#   bash build-prebuilts.sh --pytorch --torchvision  # ML stack only
#   bash build-prebuilts.sh --coral                  # Coral .ko modules only
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
log()  { echo -e "${GREEN}[BUILD]${NC} $1"; }
warn() { echo -e "${YELLOW}[BUILD]${NC} $1"; }
fail() { echo -e "${RED}[BUILD]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[BUILD]${NC} $1"; }

# ─────────────────────────────────────────────────────────────
# Defaults & flag parsing
# ─────────────────────────────────────────────────────────────
BUILD_LLAMA=false
BUILD_PYTORCH=false
BUILD_TORCHVISION=false
BUILD_CORAL=false
USER_BUILD_DIR=""
USER_OUTPUT_DIR=""
USER_MAX_JOBS=""

usage() {
    cat <<EOF
Usage: $0 [BUILD FLAGS] [OPTIONS]

Build flags (combine freely):
  --llama              Build llama-server binary (~10 min)
  --pytorch            Build PyTorch 2.1.0 cp310 wheel (~2-4 hours, RAM hungry)
  --torchvision        Build torchvision 0.16.0 cp310 wheel (~30 min, needs torch installed)
  --coral              Build Coral TPU kernel modules (gasket + apex, ~5 min)
  --all                Build everything

Options:
  --build-dir DIR      Where source trees get cloned (~30GB for pytorch).
                       Default: /mnt/nvme if mounted, else \$HOME.
                       USE THIS on Xavier — eMMC is only 32GB and pytorch
                       source + objects will fill it.
  --output-dir DIR     Where finished artifacts get staged.
                       Default: /mnt/nvme/prebuilt if mounted, else ~/prebuilt.
  --max-jobs N         Cap parallel compile jobs (only affects pytorch/torchvision).
                       Default: \$(nproc). On 8GB Nano, set to 2 to avoid OOM.
                       On 16GB Xavier, 4 is safe; 32GB Xavier handles full nproc.
  -h, --help           Show this help

Examples:
  # Xavier 32GB, NVMe mounted, full send
  $0 --all

  # Xavier 16GB, explicit dirs, conservative parallelism
  $0 --pytorch --build-dir /mnt/nvme/build --max-jobs 4

  # Orin Nano 8GB, two cores per build, output to NVMe
  $0 --pytorch --max-jobs 2 --build-dir /mnt/nvme/build

  # Just the fast stuff
  $0 --llama --coral

Output is tagged by JetPack version: jp5/Xavier (arch 72) vs jp6/Orin (arch 87).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --llama)        BUILD_LLAMA=true; shift ;;
        --pytorch)      BUILD_PYTORCH=true; shift ;;
        --torchvision)  BUILD_TORCHVISION=true; shift ;;
        --coral)        BUILD_CORAL=true; shift ;;
        --all)          BUILD_LLAMA=true; BUILD_PYTORCH=true; BUILD_TORCHVISION=true; BUILD_CORAL=true; shift ;;
        --build-dir)    USER_BUILD_DIR="$2"; shift 2 ;;
        --output-dir)   USER_OUTPUT_DIR="$2"; shift 2 ;;
        --max-jobs)     USER_MAX_JOBS="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              fail "Unknown option: $1" ;;
    esac
done

if ! $BUILD_LLAMA && ! $BUILD_PYTORCH && ! $BUILD_TORCHVISION && ! $BUILD_CORAL; then
    fail "No build flag given. Pass --all or specific --llama/--pytorch/--torchvision/--coral. Try -h."
fi

# Validate --max-jobs if provided
if [ -n "$USER_MAX_JOBS" ]; then
    if ! [[ "$USER_MAX_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        fail "--max-jobs must be a positive integer (got: $USER_MAX_JOBS)"
    fi
fi

# ─────────────────────────────────────────────────────────────
# Platform detection: Xavier (jp5/Volta) vs Orin (jp6/Ampere)
# ─────────────────────────────────────────────────────────────
detect_platform() {
    local jp_release=""
    if [ -f /etc/nv_tegra_release ]; then
        jp_release=$(head -1 /etc/nv_tegra_release | grep -oP 'R\d+' | head -1)
    fi

    case "$jp_release" in
        R35)
            JP_FAMILY="jp5"
            PLATFORM_TAG="xavier"
            CUDA_ARCH="72"
            TORCH_ARCH_LIST="7.2"
            ;;
        R36)
            JP_FAMILY="jp6"
            PLATFORM_TAG="orin"
            CUDA_ARCH="87"
            TORCH_ARCH_LIST="8.7"
            ;;
        *)
            warn "Could not detect JetPack version from /etc/nv_tegra_release"
            warn "Defaulting to Xavier/jp5 (arch 72). Override by editing this script if you're on something else."
            JP_FAMILY="jp5"
            PLATFORM_TAG="xavier"
            CUDA_ARCH="72"
            TORCH_ARCH_LIST="7.2"
            ;;
    esac
    KERNEL_VER=$(uname -r)
}
detect_platform

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
    warn "No /mnt/nvme — using $PREBUILT_DIR (make sure you have ~30GB free)"
fi

# Build dir: where pytorch/torchvision source trees get cloned + compiled
# This is where space goes — pytorch alone needs ~25GB during build.
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

# Sanity check: warn if build dir is on eMMC (small) and we're building pytorch
if $BUILD_PYTORCH || $BUILD_TORCHVISION; then
    BUILD_FS_AVAIL_GB=$(df -BG "$BUILD_DIR" | awk 'NR==2 {gsub("G",""); print $4}')
    if [ -n "$BUILD_FS_AVAIL_GB" ] && [ "$BUILD_FS_AVAIL_GB" -lt 30 ] 2>/dev/null; then
        warn "Build dir $BUILD_DIR has only ${BUILD_FS_AVAIL_GB}GB free — pytorch needs ~25GB."
        warn "If this is the eMMC, pass --build-dir /mnt/nvme/build or similar."
        warn "Continuing in 5 seconds — Ctrl-C to abort..."
        sleep 5
    fi
fi

# MAX_JOBS resolution — used only for pytorch/torchvision
if [ -n "$USER_MAX_JOBS" ]; then
    RESOLVED_MAX_JOBS="$USER_MAX_JOBS"
else
    RESOLVED_MAX_JOBS="$(nproc)"
fi

STATE_FILE="$PREBUILT_DIR/.build.state.json"
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

ensure_jq() {
    command -v jq &>/dev/null || sudo apt-get install -y jq
}
ensure_jq

phase_done() { jq -r ".\"$1\" // false" "$STATE_FILE"; }
phase_mark() {
    local key="$1"
    local tmp; tmp="$(mktemp)"
    jq ".\"$key\" = true" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}
phase_skip_if_done() {
    if [ "$(phase_done "$1")" = "true" ]; then
        info "Phase '$1' already complete — skipping (delete $STATE_FILE to redo)"
        return 0
    fi
    return 1
}

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
log "Output dir:  $PREBUILT_DIR"
log "Build dir:   $BUILD_DIR"
log "Max jobs:    $RESOLVED_MAX_JOBS$([ -z "$USER_MAX_JOBS" ] && echo ' (auto, all cores)' || echo ' (user set)')"
log "Building:    llama=$BUILD_LLAMA pytorch=$BUILD_PYTORCH torchvision=$BUILD_TORCHVISION coral=$BUILD_CORAL"
echo ""

# Per-target prereq checks
need_python310=false
need_nvcc=false
$BUILD_LLAMA       && need_nvcc=true
$BUILD_PYTORCH     && { need_python310=true; need_nvcc=true; }
$BUILD_TORCHVISION && { need_python310=true; need_nvcc=true; }

if $need_python310; then
    command -v python3.10 &>/dev/null || fail "python3.10 required for pytorch/torchvision build — run from-zero script first"
    log "python3.10: $(python3.10 --version 2>&1)"
fi
if $need_nvcc; then
    command -v nvcc &>/dev/null || fail "nvcc required — CUDA toolkit not installed"
    log "nvcc:        $(nvcc --version | grep release | awk '{print $6}' | cut -d',' -f1)"
fi

# Common build env
export PATH=$HOME/.local/bin:/usr/local/cuda-12.2/bin:/usr/local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.2/compat:/usr/local/cuda-12.2/lib64:${LD_LIBRARY_PATH:-}

# Common build deps (only install what's needed)
if $BUILD_LLAMA || $BUILD_PYTORCH || $BUILD_TORCHVISION; then
    sudo apt install -y \
        build-essential git ninja-build pkg-config \
        libopenblas-dev libopenmpi-dev libomp-dev \
        libjpeg-dev libpng-dev libffi-dev libssl-dev 2>/dev/null || true
fi

START_TIME=$(date +%s)
BUILD_INFO="$PREBUILT_DIR/BUILD_INFO_${PLATFORM_TAG}_${JP_FAMILY}.txt"
{
    echo "Build started: $(date)"
    echo "Platform: $PLATFORM_TAG ($JP_FAMILY)"
    echo "Kernel: $KERNEL_VER"
    echo "Host: $(hostname)"
} > "$BUILD_INFO"

# ═════════════════════════════════════════════════════════════
# llama.cpp
# ═════════════════════════════════════════════════════════════
build_llama() {
    log "Building llama-server (${PLATFORM_TAG}, arch $CUDA_ARCH)..."
    cd ~
    rm -rf llama.cpp
    git clone https://github.com/ggml-org/llama.cpp
    cd llama.cpp

    cmake -B build \
        -DGGML_CUDA=ON \
        -DGGML_CUDA_F16=on \
        -DGGML_CUDA_FA_ALL_QUANTS=ON \
        -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH"
    cmake --build build --config Release -j"$(nproc)"

    [ -f build/bin/llama-server ] || fail "llama.cpp build failed"

    local OUT="$PREBUILT_DIR/llama-server-${PLATFORM_TAG}-aarch64"
    cp build/bin/llama-server "$OUT"
    chmod +x "$OUT"

    local LLAMA_VER; LLAMA_VER=$(./build/bin/llama-server --version 2>&1 | head -1 || echo "unknown")
    echo "llama.cpp: $LLAMA_VER → $(basename "$OUT")" >> "$BUILD_INFO"
    log "llama.cpp built → $OUT ✓"
    cd ~
}

if $BUILD_LLAMA; then
    if phase_skip_if_done "llama_${PLATFORM_TAG}"; then :; else
        build_llama
        phase_mark "llama_${PLATFORM_TAG}"
    fi
fi

# ═════════════════════════════════════════════════════════════
# PyTorch 2.1.0 (cp310)
# ═════════════════════════════════════════════════════════════
build_pytorch() {
    log "Building PyTorch 2.1.0 cp310 (${PLATFORM_TAG}, arch $TORCH_ARCH_LIST)..."

    # numpy 1.24.4 for build — PyTorch 2.1.0 uses numpy 1.x C API
    # numpy 1.26+ ships 2.0-style headers (no elsize on PyArray_Descr)
    python3.10 -m pip install --user \
        "numpy==1.24.4" \
        scikit-build ninja pyyaml \
        typing-extensions cffi future six requests dataclasses setuptools wheel

    export USE_CUDA=1
    export USE_CUDNN=1
    export USE_NCCL=0
    export USE_DISTRIBUTED=0
    export USE_QNNPACK=0
    export USE_PYTORCH_QNNPACK=0
    export USE_MKLDNN=0
    export USE_XNNPACK=0
    export TORCH_CUDA_ARCH_LIST="$TORCH_ARCH_LIST"
    export PYTORCH_BUILD_VERSION=2.1.0
    export PYTORCH_BUILD_NUMBER=1
    export MAX_JOBS="$RESOLVED_MAX_JOBS"
    export CMAKE_POLICY_VERSION_MINIMUM=3.5

    cd "$BUILD_DIR"
    rm -rf pytorch
    git clone --recursive --branch v2.1.0 --depth 1 https://github.com/pytorch/pytorch
    cd pytorch
    python3.10 -m pip install --user -r requirements.txt

    log "Starting PyTorch build (this takes 2-4 hours)..."
    python3.10 setup.py bdist_wheel

    local WHEEL; WHEEL=$(ls dist/torch-*.whl 2>/dev/null | head -1)
    [ -z "$WHEEL" ] && fail "PyTorch build failed — no wheel produced"

    cp "$WHEEL" "$PREBUILT_DIR/"
    echo "pytorch: $(basename "$WHEEL")" >> "$BUILD_INFO"
    log "PyTorch wheel saved → $PREBUILT_DIR/$(basename "$WHEEL") ✓"

    # Install so torchvision can build against it
    python3.10 -m pip install --user "$WHEEL"
    cd ~
}

if $BUILD_PYTORCH; then
    if phase_skip_if_done "pytorch_${PLATFORM_TAG}"; then :; else
        build_pytorch
        phase_mark "pytorch_${PLATFORM_TAG}"
    fi
fi

# ═════════════════════════════════════════════════════════════
# torchvision 0.16.0 (cp310)
# ═════════════════════════════════════════════════════════════
build_torchvision() {
    log "Building torchvision 0.16.0 cp310 (${PLATFORM_TAG}, arch $TORCH_ARCH_LIST)..."

    # Verify torch is importable
    python3.10 -c "import torch; print('torch:', torch.__version__)" 2>/dev/null || \
        fail "torch not installed in python3.10 — run --pytorch first or pip install the wheel"

    export TORCH_CUDA_ARCH_LIST="$TORCH_ARCH_LIST"
    export CMAKE_POLICY_VERSION_MINIMUM=3.5
    export MAX_JOBS="$RESOLVED_MAX_JOBS"

    cd "$BUILD_DIR"
    rm -rf torchvision
    git clone --branch v0.16.0 --depth 1 https://github.com/pytorch/vision torchvision
    cd torchvision
    python3.10 setup.py bdist_wheel

    local WHEEL; WHEEL=$(ls dist/torchvision-*.whl 2>/dev/null | head -1)
    [ -z "$WHEEL" ] && fail "torchvision build failed — no wheel produced"

    cp "$WHEEL" "$PREBUILT_DIR/"
    echo "torchvision: $(basename "$WHEEL")" >> "$BUILD_INFO"
    log "torchvision wheel saved → $PREBUILT_DIR/$(basename "$WHEEL") ✓"

    # Restore numpy to runtime version
    python3.10 -m pip install --user "numpy==1.26.1"
    cd ~
}

if $BUILD_TORCHVISION; then
    if phase_skip_if_done "torchvision_${PLATFORM_TAG}"; then :; else
        build_torchvision
        phase_mark "torchvision_${PLATFORM_TAG}"
    fi
fi

# ═════════════════════════════════════════════════════════════
# Coral kernel modules (gasket + apex)
# ═════════════════════════════════════════════════════════════
build_coral() {
    log "Building Coral kernel modules (${PLATFORM_TAG}, $JP_FAMILY, kernel $KERNEL_VER)..."

    # Kernel headers required
    sudo apt install -y nvidia-l4t-kernel-headers build-essential 2>/dev/null || \
        sudo apt install -y "linux-headers-$KERNEL_VER" build-essential 2>/dev/null || \
        warn "Could not install kernel headers via standard packages — module build may fail"

    cd /tmp
    rm -rf gasket-driver
    git clone https://github.com/google/gasket-driver.git
    cd gasket-driver/src

    log "Compiling gasket + apex against kernel $KERNEL_VER..."
    make -C "/lib/modules/$KERNEL_VER/build" M="$(pwd)" modules

    [ -f gasket.ko ] || fail "gasket.ko not produced"
    [ -f apex.ko ]   || fail "apex.ko not produced"

    local GASKET_OUT="$PREBUILT_DIR/gasket-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
    local APEX_OUT="$PREBUILT_DIR/apex-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
    cp gasket.ko "$GASKET_OUT"
    cp apex.ko   "$APEX_OUT"

    # Capture kernel version into a manifest so install side can validate
    local MANIFEST="$PREBUILT_DIR/coral-${JP_FAMILY}-${PLATFORM_TAG}.manifest"
    {
        echo "kernel=$KERNEL_VER"
        echo "jp_family=$JP_FAMILY"
        echo "platform=$PLATFORM_TAG"
        echo "gasket=$(basename "$GASKET_OUT")"
        echo "apex=$(basename "$APEX_OUT")"
        echo "built=$(date -Iseconds)"
    } > "$MANIFEST"

    {
        echo "coral gasket: $(basename "$GASKET_OUT")"
        echo "coral apex:   $(basename "$APEX_OUT")"
        echo "coral kernel: $KERNEL_VER"
    } >> "$BUILD_INFO"

    log "Coral modules built ✓"
    log "  $GASKET_OUT"
    log "  $APEX_OUT"
    log "  $MANIFEST"
    cd ~
    rm -rf /tmp/gasket-driver
}

if $BUILD_CORAL; then
    if phase_skip_if_done "coral_${JP_FAMILY}_${PLATFORM_TAG}"; then :; else
        build_coral
        phase_mark "coral_${JP_FAMILY}_${PLATFORM_TAG}"
    fi
fi

# ═════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════
END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))
echo "Total build time: ${ELAPSED} minutes" >> "$BUILD_INFO"

echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Build Complete${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
ls -lh "$PREBUILT_DIR/" | grep -v '^total' | grep -v '^\.build'
echo ""
cat "$BUILD_INFO"
echo ""
log "Upload to release: https://github.com/ChadRoesler/Nvidia_Jetson_Prebuilt/releases"
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  ${ELAPSED} minutes. Never build these again.${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
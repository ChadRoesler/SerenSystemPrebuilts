#!/bin/bash
# ══════════════════════════════════════════════════════════════
# Xavier AGX — Build Portable Prebuilt Artifacts
#
# Builds the three things that take forever and ARE portable:
#   1. llama.cpp binary (CUDA, arch 72 Volta)
#   2. PyTorch 2.1.0 wheel (CUDA, arch 72, python3.10)
#   3. torchvision 0.16.0 wheel (matching PyTorch)
#
# Does NOT build (these are system installs, not portable):
#   - Python 3.10 (handled by xavier-from-zero.sh)
#   - SQLite 3.45 (handled by xavier-from-zero.sh)
#
# Prerequisites:
#   - Run xavier-from-zero.sh first (python3.10 + sqlite + cuda)
#   - NVMe mounted at /mnt/nvme
#
# Output: /mnt/nvme/prebuilt/
# Total time: ~3-5 hours (PyTorch is the big one)
#
# Usage:
#   tmux new -s build
#   bash build-prebuilts.sh
#   # go do literally anything else
#
# After building:
#   scp -r user@xavier:/mnt/nvme/prebuilt/ ~/prebuilt/
# ══════════════════════════════════════════════════════════════

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[BUILD]${NC} $1"; }
warn() { echo -e "${YELLOW}[BUILD]${NC} $1"; }
fail() { echo -e "${RED}[BUILD]${NC} $1"; exit 1; }

PREBUILT_DIR="/mnt/nvme/prebuilt"

echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Building Portable Prebuilt Artifacts${NC}"
echo -e "${GREEN}  llama.cpp + PyTorch + torchvision${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""

# ══ Prerequisite checks ══════════════════════════════════════
command -v python3.10 &>/dev/null || fail "python3.10 not found — run xavier-from-zero.sh first"
command -v nvcc &>/dev/null || fail "nvcc not found — CUDA not installed"

SQLITE_VER=$(python3.10 -c "import sqlite3; print(sqlite3.sqlite_version)" 2>/dev/null || echo "0")
SQLITE_MINOR=$(echo "$SQLITE_VER" | cut -d. -f2)
[ "$SQLITE_MINOR" -ge 35 ] 2>/dev/null || warn "SQLite ${SQLITE_VER} < 3.35 — ChromaDB may not work"

[ -d /mnt/nvme ] || fail "/mnt/nvme not mounted — need NVMe for build space"

log "python3.10: $(python3.10 --version 2>&1)"
log "nvcc: $(nvcc --version 2>/dev/null | grep release | awk '{print $6}' | cut -d',' -f1)"
log "sqlite3: ${SQLITE_VER}"
echo ""

# ══ Setup ════════════════════════════════════════════════════
rm -rf "$PREBUILT_DIR"
mkdir -p "$PREBUILT_DIR"

export PATH=$HOME/.local/bin:/usr/local/cuda-12.2/bin:/usr/local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.2/compat:/usr/local/cuda-12.2/lib64:$LD_LIBRARY_PATH

sudo apt remove cmake -y 2>/dev/null || true

sudo apt install -y build-essential git ninja-build \
    libopenblas-dev libopenmpi-dev libomp-dev \
    libjpeg-dev libpng-dev libffi-dev libssl-dev \
    pkg-config 2>/dev/null

pip3 install cmake --user
export PATH=$HOME/.local/bin:$PATH
grep -q '.local/bin' ~/.bashrc || \
    echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc

START_TIME=$(date +%s)
echo "Build started: $(date)" > "$PREBUILT_DIR/BUILD_INFO.txt"

# ══════════════════════════════════════════════════════════════
# 1. llama.cpp
# ══════════════════════════════════════════════════════════════
log "1/3: llama.cpp (~10 min)"

cd ~
rm -rf llama.cpp
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp

cmake -B build \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_F16=on \
    -DGGML_CUDA_FA_ALL_QUANTS=ON \
    -DCMAKE_CUDA_ARCHITECTURES="72"
cmake --build build --config Release -j$(nproc)

[ -f build/bin/llama-server ] || fail "llama.cpp build failed"

cp build/bin/llama-server "$PREBUILT_DIR/llama-server-xavier-aarch64"
chmod +x "$PREBUILT_DIR/llama-server-xavier-aarch64"
LLAMA_VER=$(./build/bin/llama-server --version 2>&1 | head -1)
echo "llama.cpp: ${LLAMA_VER}" >> "$PREBUILT_DIR/BUILD_INFO.txt"
log "llama.cpp built and saved ✓"
cd ~

# ══════════════════════════════════════════════════════════════
# 2. PyTorch 2.1.0
# ══════════════════════════════════════════════════════════════
log "2/3: PyTorch 2.1.0 (~2-4 hours)"

# Pin numpy 1.24.4 for build — PyTorch 2.1.0 uses numpy 1.x C API
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
export TORCH_CUDA_ARCH_LIST="7.2"
export PYTORCH_BUILD_VERSION=2.1.0
export PYTORCH_BUILD_NUMBER=1
export MAX_JOBS=$(nproc)
export CMAKE_POLICY_VERSION_MINIMUM=3.5

cd /mnt/nvme
rm -rf pytorch
git clone --recursive --branch v2.1.0 --depth 1 https://github.com/pytorch/pytorch
cd pytorch

python3.10 -m pip install --user -r requirements.txt

log "Starting PyTorch build (this takes 2-4 hours)..."
python3.10 setup.py bdist_wheel

WHEEL=$(ls dist/torch-*.whl 2>/dev/null | head -1)
[ -z "$WHEEL" ] && fail "PyTorch build failed — no wheel produced"

cp "$WHEEL" "$PREBUILT_DIR/"
echo "pytorch: $(basename $WHEEL)" >> "$PREBUILT_DIR/BUILD_INFO.txt"
log "PyTorch wheel saved ✓"

# Install so torchvision can build against it
python3.10 -m pip install --user "$WHEEL"
cd ~

# ══════════════════════════════════════════════════════════════
# 3. torchvision 0.16.0
# ══════════════════════════════════════════════════════════════
log "3/3: torchvision 0.16.0 (~30 min)"

cd /mnt/nvme
rm -rf torchvision
git clone --branch v0.16.0 --depth 1 https://github.com/pytorch/vision torchvision
cd torchvision

python3.10 setup.py bdist_wheel

VISION_WHEEL=$(ls dist/torchvision-*.whl 2>/dev/null | head -1)
[ -z "$VISION_WHEEL" ] && fail "torchvision build failed — no wheel produced"

cp "$VISION_WHEEL" "$PREBUILT_DIR/"
echo "torchvision: $(basename $VISION_WHEEL)" >> "$PREBUILT_DIR/BUILD_INFO.txt"
log "torchvision wheel saved ✓"
cd ~

# Restore numpy to runtime version
python3.10 -m pip install --user "numpy==1.26.1"

# ══════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════
END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))
echo "Total build time: ${ELAPSED} minutes" >> "$PREBUILT_DIR/BUILD_INFO.txt"
echo "Built on: $(hostname) @ $(date)" >> "$PREBUILT_DIR/BUILD_INFO.txt"

echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Prebuilt Artifacts — Complete${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""

ls -lh "$PREBUILT_DIR/"
echo ""
cat "$PREBUILT_DIR/BUILD_INFO.txt"
echo ""

log "Usage on a fresh Xavier (after xavier-from-zero.sh):"
echo ""
echo "  python3.10 -m pip install --user /path/to/torch-*.whl"
echo "  python3.10 -m pip install --user /path/to/torchvision-*.whl"
echo "  cp /path/to/llama-server-xavier-aarch64 ~/llama.cpp/build/bin/llama-server"
echo "  chmod +x ~/llama.cpp/build/bin/llama-server"
echo ""
log "Backup to desktop:"
echo "  scp -r user@xavier:/mnt/nvme/prebuilt/ C:\\path\\to\\local\\prebuilt\\"
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Never build these again.${NC}"
echo -e "${GREEN}  Total: ${ELAPSED} minutes${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
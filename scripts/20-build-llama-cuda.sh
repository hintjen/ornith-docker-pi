#!/usr/bin/env bash
# Build llama.cpp with CUDA from a pinned commit into <repo>/build/llama.cpp.
# Requires: NVIDIA driver + CUDA toolkit (nvcc). Installs modern cmake/ninja via pip.
#
#   ./scripts/20-build-llama-cuda.sh
#
# Env overrides: LLAMA_COMMIT, CUDA_ARCH (89=Ada/4090, 86=Ampere, 90=Hopper),
#                CUDACXX (default /usr/local/cuda/bin/nvcc), ORNITH_BUILD_DIR
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

BUILD_DIR="${ORNITH_BUILD_DIR:-$HERE/build}"
LLAMA_COMMIT="${LLAMA_COMMIT:-050ee92d04c2e1f639025786dea701c70e7d4204}"
CUDA_ARCH="${CUDA_ARCH:-89}"
export CUDACXX="${CUDACXX:-/usr/local/cuda/bin/nvcc}"
export CUDA_PATH="${CUDA_PATH:-/usr/local/cuda}"

command -v "$CUDACXX" >/dev/null || { echo "ERROR: nvcc not found at $CUDACXX (install CUDA toolkit)" >&2; exit 1; }
echo "[build] cmake/ninja..."; python3 -m pip install -U cmake ninja >/dev/null
export PATH="$(python3 -c 'import sysconfig,os;print(os.path.join(sysconfig.get_path("scripts","posix_user")))' 2>/dev/null):$HOME/.local/bin:$PATH"

mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
[ -d llama.cpp/.git ] || git clone https://github.com/ggml-org/llama.cpp llama.cpp
cd llama.cpp && git fetch --all -q && git checkout -q "$LLAMA_COMMIT"
echo "[build] llama.cpp @ $(git rev-parse --short HEAD)  CUDA_ARCH=$CUDA_ARCH"

cmake -S . -B build -G Ninja \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DLLAMA_CURL=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON
cmake --build build -j --target llama-server llama-cli llama-bench
echo "[build] binaries at $BUILD_DIR/llama.cpp/build/bin"

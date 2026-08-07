#!/usr/bin/env bash
# Build llama.cpp with CUDA + Laguna support into <repo>/build/llama.cpp-laguna.
#
# Laguna (XS.2 / XS 2.1 / M.1) support merged upstream in ggml-org/llama.cpp#25165
# on 2026-07-22 (commit 1f66c3ce1c26c95db3fadb734086c7d9fba23bb9) — AFTER the
# commit 20-build-llama-cuda.sh pins for Ornith (2026-06-26). It needs its own
# build tree at a newer commit; it does not touch or replace the Ornith build.
#
#   ./scripts/25-build-llama-laguna.sh
#
# Env overrides: LAGUNA_LLAMA_COMMIT, CUDA_ARCH (89=Ada/4090, 86=Ampere, 90=Hopper),
#                CUDACXX (default /usr/local/cuda/bin/nvcc), LAGUNA_BUILD_DIR
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

BUILD_DIR="${LAGUNA_BUILD_DIR:-$HERE/build}"
LLAMA_COMMIT="${LAGUNA_LLAMA_COMMIT:-1f66c3ce1c26c95db3fadb734086c7d9fba23bb9}"
CUDA_ARCH="${CUDA_ARCH:-89}"
export CUDACXX="${CUDACXX:-/usr/local/cuda/bin/nvcc}"
export CUDA_PATH="${CUDA_PATH:-/usr/local/cuda}"

command -v "$CUDACXX" >/dev/null || { echo "ERROR: nvcc not found at $CUDACXX (install CUDA toolkit)" >&2; exit 1; }
echo "[build] cmake/ninja..."; python3 -m pip install -U cmake ninja >/dev/null
export PATH="$(python3 -c 'import sysconfig,os;print(os.path.join(sysconfig.get_path("scripts","posix_user")))' 2>/dev/null):$HOME/.local/bin:$PATH"

mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
[ -d llama.cpp-laguna/.git ] || git clone https://github.com/ggml-org/llama.cpp llama.cpp-laguna
cd llama.cpp-laguna && git fetch --all -q && git checkout -q "$LLAMA_COMMIT"
echo "[build] llama.cpp (laguna) @ $(git rev-parse --short HEAD)  CUDA_ARCH=$CUDA_ARCH"

cmake -S . -B build -G Ninja \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DLLAMA_CURL=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON
cmake --build build -j --target llama-server llama-cli llama-bench
echo "[build] binaries at $BUILD_DIR/llama.cpp-laguna/build/bin"

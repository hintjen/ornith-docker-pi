#!/usr/bin/env bash
# Host prerequisites. CUDA toolkit + NVIDIA driver must already be installed.
# This installs the NVIDIA Container Toolkit (only needed for the Docker path).
#
#   sudo ./scripts/00-host-prereqs.sh
set -euo pipefail

echo "[prereq] driver / toolkit check:"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || { echo "ERROR: NVIDIA driver not working"; exit 1; }
command -v nvcc >/dev/null || ls /usr/local/cuda/bin/nvcc >/dev/null 2>&1 || echo "WARN: nvcc not found (needed for the bare-metal build path)"

if ! docker info 2>/dev/null | grep -qi nvidia; then
  echo "[prereq] installing nvidia-container-toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update && apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi
echo "[prereq] docker runtimes: $(docker info 2>/dev/null | grep -i runtimes || true)"
echo "[prereq] OK"

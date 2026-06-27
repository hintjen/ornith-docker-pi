#!/usr/bin/env bash
# Install the Pi model config so `pi` can reach the local Ornith server on :8090.
#
#   ./scripts/40-configure-pi.sh
#
# Env override: PI_CONFIG_DIR (default ~/.pi/agent)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

DEST="${PI_CONFIG_DIR:-$HOME/.pi/agent}"
mkdir -p "$DEST"
cp "$HERE/config/pi-models.json" "$DEST/models.json"
echo "[pi] wrote $DEST/models.json (provider ornith-local -> http://localhost:8090/v1)"

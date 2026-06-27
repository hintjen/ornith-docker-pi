#!/usr/bin/env bash
# Install a self-contained Node + the Pi coding agent into <repo>/build/node.
# (Avoids snap Node, which fails when $HOME is outside /home.)
#
#   ./scripts/30-install-node-pi.sh
#
# Env overrides: NODE_VERSION, PI_VERSION, ORNITH_NODE_DIR
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

NODE_VERSION="${NODE_VERSION:-v24.18.0}"
PI_VERSION="${PI_VERSION:-0.73.1}"
PREFIX="${ORNITH_NODE_DIR:-$HERE/build/node}"

mkdir -p "$PREFIX"
echo "[node] downloading $NODE_VERSION..."
curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz" -o /tmp/ornith-node.tar.xz
tar xf /tmp/ornith-node.tar.xz -C "$PREFIX" --strip-components=1
rm -f /tmp/ornith-node.tar.xz

echo "[node] installing pi-coding-agent@$PI_VERSION..."
"$PREFIX/bin/npm" install -g "@mariozechner/pi-coding-agent@${PI_VERSION}"
echo "[node] done. add to PATH:  export PATH=\"$PREFIX/bin:\$PATH\""

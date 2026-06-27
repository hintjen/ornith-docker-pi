#!/usr/bin/env bash
# Download an Ornith-1.0-35B GGUF quant from Hugging Face into the repo's models/ dir.
#
#   ./scripts/10-download-model.sh [QUANT] [DEST_DIR]
#
#   QUANT     Q4_K_M (default) | Q5_K_M | Q6_K | Q8_0 | bf16
#   DEST_DIR  default: <repo>/models  (override with $ORNITH_MODEL_DIR)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

REPO="deepreinforce-ai/Ornith-1.0-35B-GGUF"
QUANT="${1:-Q4_K_M}"
DEST="${2:-${ORNITH_MODEL_DIR:-$HERE/models}}"

echo "[download] repo=$REPO quant=$QUANT dest=$DEST"
mkdir -p "$DEST" 2>/dev/null || true
# Guard against a root-owned models/ (Docker creates the bind-mount dir as root if you
# 'docker compose up' before downloading). hf would then fail deep inside with EACCES.
if ! { [ -d "$DEST" ] && touch "$DEST/.write_test" 2>/dev/null; }; then
  echo "[download] ERROR: $DEST is not writable by $(id -un)." >&2
  echo "[download]   Likely root-owned because 'docker compose up' created it first." >&2
  echo "[download]   Fix:  sudo chown -R \"$(id -un):$(id -gn)\" \"$DEST\"" >&2
  exit 1
fi
rm -f "$DEST/.write_test"
# Resolve an 'hf' CLI WITHOUT touching system packages. On Debian 12+/Ubuntu 23.04+
# (PEP 668 "externally-managed-environment"), `pip install` into system Python errors out
# unless you pass --break-system-packages. Use a self-contained repo-local venv instead.
HF="$(command -v hf || true)"
if [ -z "$HF" ]; then
  VENV="${ORNITH_VENV:-$HERE/build/venv}"
  if [ ! -x "$VENV/bin/hf" ]; then
    echo "[download] no 'hf' on PATH; creating venv at $VENV ..."
    python3 -m venv "$VENV" 2>/dev/null || {
      echo "[download] ERROR: 'python3 -m venv' failed — install the venv module first:" >&2
      echo "[download]   Debian/Ubuntu:  sudo apt-get install -y python3-venv" >&2
      exit 1; }
    "$VENV/bin/pip" install -q -U pip huggingface_hub
  fi
  HF="$VENV/bin/hf"
fi
echo "[download] using hf: $HF"

# Faster downloads if hf_transfer is present (optional).
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-0}"

"$HF" download "$REPO" --include "*${QUANT}*.gguf" --local-dir "$DEST"

FILE="$(ls -1 "$DEST"/*"${QUANT}"*.gguf 2>/dev/null | head -1 || true)"
[ -n "$FILE" ] || { echo "[download] ERROR: no *${QUANT}*.gguf in $DEST" >&2; exit 1; }
echo "[download] done: $FILE ($(stat -c %s "$FILE") bytes)"

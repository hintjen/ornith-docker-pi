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
command -v hf >/dev/null 2>&1 || { echo "[download] installing huggingface_hub..."; python3 -m pip install -U huggingface_hub >/dev/null; }

hf download "$REPO" --include "*${QUANT}*.gguf" --local-dir "$DEST"

FILE="$(ls -1 "$DEST"/*"${QUANT}"*.gguf 2>/dev/null | head -1 || true)"
[ -n "$FILE" ] || { echo "[download] ERROR: no *${QUANT}*.gguf in $DEST" >&2; exit 1; }
echo "[download] done: $FILE ($(stat -c %s "$FILE") bytes)"

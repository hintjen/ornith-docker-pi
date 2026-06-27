#!/usr/bin/env bash
# Run the Ornith llama-server on the local GPU (full offload, OpenAI API on :8090).
#
#   ./scripts/serve-ornith.sh [CTX]      # CTX default 65536; 131072 for 128K
#
# Env overrides: ORNITH_BIN_DIR, ORNITH_MODEL, ORNITH_CTX, ORNITH_NCMOE
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"

BIN="${ORNITH_BIN_DIR:-$HERE/build/llama.cpp/build/bin}"
MODEL="${ORNITH_MODEL:-$(ls "$HERE"/models/*Q4_K_M*.gguf 2>/dev/null | head -1)}"
CTX="${1:-${ORNITH_CTX:-65536}}"          # 65536 ~22GB | 131072 ~23.4GB | 262144 needs NCMOE>0
NCMOE="${ORNITH_NCMOE:-0}"                 # 0 = whole model on GPU (fastest)

[ -x "$BIN/llama-server" ] || { echo "ERROR: llama-server not found at $BIN — run scripts/20-build-llama-cuda.sh" >&2; exit 1; }
[ -n "$MODEL" ] && [ -f "$MODEL" ] || { echo "ERROR: model not found — run scripts/10-download-model.sh" >&2; exit 1; }

export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$BIN:${LD_LIBRARY_PATH:-}"
exec "$BIN/llama-server" \
  -m "$MODEL" \
  --alias ornith \
  -ngl 99 \
  --n-cpu-moe "$NCMOE" \
  -fa on \
  -c "$CTX" \
  --temp 0.6 --top-p 0.95 --top-k 20 \
  --jinja \
  --host 0.0.0.0 --port 8090 --no-webui

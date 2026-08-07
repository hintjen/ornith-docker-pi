#!/usr/bin/env bash
# Run the Laguna XS 2.1 llama-server on the local GPU (OpenAI API on :8090).
#
# Same port as serve-ornith.sh — Ornith (~21GB) and Laguna (~20GB) both need most
# of a 24GB card, so only ONE of the two servers can run at a time. Stop whichever
# is running before starting the other.
#
#   ./scripts/serve-laguna.sh [CTX]      # CTX default 32768
#
# Env overrides: LAGUNA_BIN_DIR, LAGUNA_MODEL, LAGUNA_CTX, LAGUNA_NCMOE, LAGUNA_PARALLEL
#
# Troubleshooting (from the upstream PR notes):
#   - If generation stops early / EOG-token errors: try adding --reasoning off
#   - --no-mmap + full GPU offload can fail pinned-memory allocation on some hosts
#     with large system RAM but limited VRAM — drop --no-mmap if you hit that (we
#     don't pass it here, so this is only relevant if you add it yourself)
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"

BIN="${LAGUNA_BIN_DIR:-$HERE/build/llama.cpp-laguna/build/bin}"
MODEL="${LAGUNA_MODEL:-$(ls "$HERE"/models-laguna/*Q4_K_M*.gguf 2>/dev/null | head -1)}"
CTX="${1:-${LAGUNA_CTX:-32768}}"           # Laguna supports up to 262144; start conservative
NCMOE="${LAGUNA_NCMOE:-0}"                 # 0 = whole model on GPU (fastest)
NPAR="${LAGUNA_PARALLEL:-1}"               # concurrent slots; CTX is SPLIT across them

[ -x "$BIN/llama-server" ] || { echo "ERROR: llama-server not found at $BIN — run scripts/25-build-llama-laguna.sh" >&2; exit 1; }
[ -n "$MODEL" ] && [ -f "$MODEL" ] || { echo "ERROR: model not found — run scripts/15-download-laguna.sh" >&2; exit 1; }

export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$BIN:${LD_LIBRARY_PATH:-}"
exec "$BIN/llama-server" \
  -m "$MODEL" \
  --alias laguna \
  -ngl 99 \
  --n-cpu-moe "$NCMOE" \
  -fa on \
  --swa-full \
  -c "$CTX" \
  --parallel "$NPAR" \
  --jinja \
  --host 0.0.0.0 --port 8090 --no-webui

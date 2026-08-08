#!/usr/bin/env bash
# Run the Laguna XS 2.1 llama-server on the local GPU (OpenAI API on :8090).
#
# Same port as serve-ornith.sh — Ornith (~21GB) and Laguna (~20GB) both need most
# of a 24GB card, so only ONE of the two servers can run at a time. Stop whichever
# is running before starting the other.
#
#   ./scripts/serve-laguna.sh [CTX]      # CTX default 65536 (~22GB, 1.5GB headroom on a 4090)
#
# Env overrides: LAGUNA_BIN_DIR, LAGUNA_MODEL, LAGUNA_CTX, LAGUNA_NCMOE, LAGUNA_PARALLEL
#
# Context/VRAM (Q4_K_M, RTX 4090, measured): 32768 ctx -> 21.3GB used, 2.8GB free.
# 65536 -> 22.7GB used, 1.5GB free (the default below). 98304 -> 24.0GB used, only
# 234MB free — loads but too tight for real inference (compute buffers scale with
# request size; risks an OOM crash mid-session). 131072 -> OOM at load time, doesn't
# fit at all. Don't go above 65536 without also raising --n-cpu-moe to offload some
# experts to CPU and free VRAM.
#
# Do NOT add --swa-full: it forces a full-context KV cache on every layer instead of
# the memory-efficient sliding-window cache Laguna uses on 30 of its 40 layers, and
# OOMs even at 32768 ctx. The upstream PR notes call it "effectively mandatory for
# prefix reuse" — that's a performance nicety we're trading away to fit on 24GB.
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
CTX="${1:-${LAGUNA_CTX:-65536}}"           # see VRAM table above before raising this
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
  -c "$CTX" \
  --parallel "$NPAR" \
  --jinja \
  --host 0.0.0.0 --port 8090 --no-webui

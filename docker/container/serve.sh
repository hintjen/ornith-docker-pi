#!/usr/bin/env bash
# In-container launcher for the Ornith llama-server (full GPU offload).
set -e
export LD_LIBRARY_PATH=/opt/ornith/bin:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
MODEL="${ORNITH_MODEL:-/models/ornith-1.0-35b-Q4_K_M.gguf}"
CTX="${ORNITH_CTX:-65536}"     # 65536 (~22GB) | 131072 (~23.4GB) | 262144 needs NCMOE>0
NCMOE="${ORNITH_NCMOE:-0}"     # 0 = whole model on GPU (fastest)
NPAR="${ORNITH_PARALLEL:-1}"   # concurrent slots; CTX is SPLIT across them (per-client = CTX/NPAR)

exec /opt/ornith/bin/llama-server \
  -m "$MODEL" \
  --alias ornith \
  -ngl 99 \
  --n-cpu-moe "$NCMOE" \
  -fa on \
  -c "$CTX" \
  --parallel "$NPAR" \
  --temp 0.6 --top-p 0.95 --top-k 20 \
  --jinja \
  --host 0.0.0.0 --port 8090 --no-webui

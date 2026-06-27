> **Note:** As-built reference from the original host; absolute paths like `/mnt/archive/ens/...` reflect that machine. For a portable reproduction use this repo's `scripts/` and `docker/` (see ../README.md).

# Ornith-1.0-35B on RTX 4090 — Local Coding-Agent Setup

A fully reproducible guide to running **deepreinforce-ai/Ornith-1.0-35B-GGUF** locally on a
single RTX 4090 with `llama.cpp` (CUDA), and wiring it into the **Pi** coding agent.

Everything below was benchmarked and verified end-to-end on the machine described in
[Hardware](#1-hardware--baseline). Result: the full Q4_K_M model runs entirely on the GPU at
**~210 tok/s generation / ~5200 tok/s prefill**.

---

## 0. TL;DR (if it's already installed)

```bash
pi-ornith              # 64K context  (~22 GB VRAM)   — interactive TUI
pi-ornith --128k       # 128K context (~23.4 GB VRAM)
pi-ornith -p "fix the failing test in foo.py"   # one-shot headless
pi-ornith @main.py "add type hints"             # include files in the prompt
```

`pi-ornith` auto-starts (or restarts at the right context) the `llama-server` backend on
`localhost:8090`, then launches Pi against it.

---

## 1. Hardware & baseline

| Component | Value |
|---|---|
| OS | Ubuntu 20.04.6 LTS (kernel 5.15) |
| CPU | 32 cores |
| RAM | 62 GB |
| GPU | NVIDIA GeForce RTX 4090, 24 GB (compute capability 8.9 / Ada) |
| NVIDIA driver | 550.144.03 |
| CUDA toolkit | 12.3 (`/usr/local/cuda`, `nvcc` V12.3.103) |
| `$HOME` | `/mnt/archive/ens` (note: **outside `/home`** — matters for Node, see §5) |

> The CUDA **toolkit** (nvcc) is required to *build* llama.cpp. The CUDA **driver** alone is
> enough to *run* it. This box already had toolkit 12.3 installed.

---

## 2. The model — what makes it special

- **deepreinforce-ai/Ornith-1.0-35B** — reasoning-focused agentic coding model, MIT license.
- Architecture: **Qwen3.5-MoE** (`qwen35moe 35B.A3B`) — 34.66B total params, **256 experts,
  8 active/token → ~3B active**, so it generates fast despite its size.
- **Hybrid linear attention**: full attention only every 4th layer (~10 of 40 layers).
  Consequence: the **KV cache is tiny** (~20 KB/token), so the whole quantized model fits in
  24 GB VRAM with room for a large context.
- **Reasoning model**: emits `<think>…</think>` blocks. With `llama-server --jinja` these are
  parsed into the API's `reasoning_content` field; the final answer goes to `content`.
- Recommended sampling: **temp 0.6, top-p 0.95, top-k 20**.

### GGUF quants available

| Quant | Size | Notes |
|---|---|---|
| **Q4_K_M** | 21.2 GB | **Use this** — fits entirely on the 4090 |
| Q5_K_M | 24.7 GB | Won't fit fully on GPU; would need expert offload (slower) |
| Q6_K | 28.5 GB | CPU/partial only |
| Q8_0 | 36.9 GB | CPU only |
| BF16 | 69.4 GB | CPU only |

---

## 3. Install prerequisites

Modern `cmake` (≥3.18) and `ninja` are required; Ubuntu 20.04's apt cmake (3.16) is too old.
The system was set up with `pyenv` (Python 3.14) on PATH, so the pip-provided cmake/ninja
binaries land on the `pyenv` shims path.

```bash
# Modern build tools (system cmake 3.16 is too old for CUDA builds)
python3 -m pip install -U cmake ninja        # gives cmake 4.x, ninja 1.13
cmake --version                              # confirm >= 3.18

# huggingface CLI for the model download
python3 -m pip install -U huggingface_hub
```

---

## 4. Build llama.cpp with CUDA + download the model

> llama.cpp does **not** ship prebuilt CUDA binaries for Linux (only Windows; Linux gets
> CPU/Vulkan/ROCm/SYCL). The NVIDIA Vulkan ICD on this box was also incomplete. So we build
> CUDA from source — which is also the fastest backend on the 4090.

```bash
mkdir -p /mnt/archive/ens/llama /mnt/archive/ens/models/ornith
cd /mnt/archive/ens/llama

# --- 4a. Download the Q4_K_M quant (~21 GB) ---
hf download deepreinforce-ai/Ornith-1.0-35B-GGUF \
  --include "*Q4_K_M*.gguf" \
  --local-dir /mnt/archive/ens/models/ornith
# -> /mnt/archive/ens/models/ornith/ornith-1.0-35b-Q4_K_M.gguf  (21,166,757,760 bytes)

# --- 4b. Clone + build llama.cpp (CUDA, arch 89 = Ada/4090) ---
git clone --depth 1 https://github.com/ggml-org/llama.cpp src    # verified @ commit 050ee92
cd src
export CUDACXX=/usr/local/cuda/bin/nvcc
export CUDA_PATH=/usr/local/cuda
cmake -S . -B build -G Ninja \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=89 \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DLLAMA_CURL=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON
cmake --build build -j --target llama-bench llama-server llama-cli
# binaries -> /mnt/archive/ens/llama/src/build/bin/
```

Build notes:
- `-DCMAKE_CUDA_ARCHITECTURES=89` targets only the 4090 → faster compile.
- `-DGGML_CUDA_FA_ALL_QUANTS=ON` builds all flash-attention kernel variants (thorough; slower
  compile). Drop it to speed up the build if you don't need every KV-quant combo.
- `-DLLAMA_CURL=OFF` avoids the libcurl build dependency (we load a local file).
- The build compiles `gated_delta_net.cu` — the linear-attention kernel this arch needs.
  A recent llama.cpp (late-2025+) is required for Qwen3.5-MoE support.

Sanity check:
```bash
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/mnt/archive/ens/llama/src/build/bin:$LD_LIBRARY_PATH
/mnt/archive/ens/llama/src/build/bin/llama-bench \
  -m /mnt/archive/ens/models/ornith/ornith-1.0-35b-Q4_K_M.gguf \
  -ngl 99 -ncmoe 0 -fa 1 -p 512 -n 128
# expect: "Device 0: NVIDIA GeForce RTX 4090" and a qwen35moe row
```

---

## 5. Optimal serving parameters (benchmarked)

The one tuning knob that matters is **`--n-cpu-moe N`** = how many layers' experts to keep on
CPU RAM instead of GPU. Lower = more on GPU = faster. We swept it.

### `--n-cpu-moe` sweep (Q4_K_M, `-ngl 99 -fa on -p 512 -n 128`)

| n-cpu-moe | prefill t/s | **gen t/s** |
|---:|---:|---:|
| **0 (all on GPU)** | **5219** | **210** ✅ |
| 2 | 2466 | 170 |
| 4 | 1994 | 147 |
| 6 | 1461 | 125 |
| 8 | 1267 | 110 |
| 10 | 1034 | 101 |
| 12 | 946 | 74 |
| 16 | 795 | 73 |

**Full GPU offload (`--n-cpu-moe 0`) wins by ~3×.** No expert offload needed.

### Context vs VRAM at `--n-cpu-moe 0`

| Context | VRAM used | Verdict |
|---:|---:|---|
| 32K | 21.4 GB | comfortable |
| 64K | 22.0 GB | **recommended default** |
| 128K | 23.4 GB | fits, ~1 GB headroom (tight) |
| 262K | — | **OOM** → needs `--n-cpu-moe ~6` or KV-cache quant |

### Final serving command

```bash
llama-server \
  -m ornith-1.0-35b-Q4_K_M.gguf \
  --alias ornith \
  -ngl 99 --n-cpu-moe 0 -fa on \
  -c 65536 \
  --temp 0.6 --top-p 0.95 --top-k 20 \
  --jinja \
  --host 0.0.0.0 --port 8090 --no-webui
```

- `--alias ornith` → the `/v1/models` id clients use is `ornith`.
- `--jinja` → enables `<think>` parsing + tool-call template (essential for agent use).
- For full 262K context: add `--n-cpu-moe 6` (frees ~3 GB; drops to ~125 tok/s).

---

## 6. Helper scripts

### `/mnt/archive/ens/llama/serve-ornith.sh`

```bash
#!/usr/bin/env bash
# Optimal serving config for Ornith-1.0-35B (Q4_K_M) on an RTX 4090 (24 GB).
# Full GPU offload (ncmoe=0): ~210 tok/s gen, ~5200 tok/s prefill, ~22 GB VRAM @ 64K ctx.
set -e
BIN=/mnt/archive/ens/llama/src/build/bin
MODEL=/mnt/archive/ens/models/ornith/ornith-1.0-35b-Q4_K_M.gguf
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$BIN:$LD_LIBRARY_PATH

CTX="${1:-65536}"   # 65536 default (~22GB). 131072 fits (~23.4GB). For 262144 add --n-cpu-moe 6

exec "$BIN/llama-server" \
  -m "$MODEL" \
  --alias ornith \
  -ngl 99 \
  --n-cpu-moe 0 \
  -fa on \
  -c "$CTX" \
  --temp 0.6 --top-p 0.95 --top-k 20 \
  --jinja \
  --host 0.0.0.0 --port 8090 --no-webui
```

Run directly: `./serve-ornith.sh` (64K) or `./serve-ornith.sh 131072` (128K).

---

## 7. Wire up the Pi coding agent

[Pi](https://github.com/earendil-works/pi) is a BYOK CLI agent that speaks the OpenAI
chat-completions protocol — so our `llama-server` is a drop-in backend.

> **Package moved:** this original build used `@mariozechner/pi-coding-agent` (frozen at
> 0.73.1). Active development is now **`@earendil-works/pi-coding-agent`** (0.80.2+, needs
> Node 22+). The reproducible scripts/Dockerfile use the new package; the commands below are
> the historical as-built record.

### 7a. Install Node + Pi

> **Gotcha:** snap's Node refuses to run because `$HOME` is outside `/home`
> ("home directories outside of /home needs configuration"). Use an official Node tarball
> instead — no root, no snap confinement.

```bash
mkdir -p /mnt/archive/ens/tools && cd /mnt/archive/ens/tools
curl -sL -o node.tar.xz https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-x64.tar.xz
tar xf node.tar.xz && mv node-v22.14.0-linux-x64 node && rm node.tar.xz
export PATH="/mnt/archive/ens/tools/node/bin:$PATH"     # node v22.14.0, npm 10.9.2

npm install -g @mariozechner/pi-coding-agent            # installs `pi` (v0.73.1)
pi --version
```

### 7b. Point Pi at the local model — `~/.pi/agent/models.json`

(`~` = `/mnt/archive/ens`.) Two entries so you can pick context from Pi's `/model` picker.

```json
{
  "providers": {
    "ornith-local": {
      "baseUrl": "http://localhost:8090/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "compat": {
        "supportsDeveloperRole": false
      },
      "models": [
        {
          "id": "ornith",
          "name": "Ornith-1.0-35B (local RTX 4090, 64K)",
          "contextWindow": 65536,
          "maxTokens": 16384,
          "reasoning": true,
          "input": ["text"]
        },
        {
          "id": "ornith-128k",
          "name": "Ornith-1.0-35B (local RTX 4090, 128K)",
          "contextWindow": 131072,
          "maxTokens": 16384,
          "reasoning": true,
          "input": ["text"]
        }
      ]
    }
  }
}
```

Field notes:
- `api: "openai-completions"` — standard OpenAI chat-completions.
- `compat.supportsDeveloperRole: false` — llama-server doesn't understand the `developer`
  role; Pi sends `system` instead.
- `reasoning: true` — Pi handles the `reasoning_content` stream (the `<think>` output) instead
  of dumping it into the visible answer.
- `contextWindow` must match the server's `-c`, and Pi caps output at `maxTokens`.

Verify Pi sees it:
```bash
pi --list-models ornith
# ornith-local  ornith      65.5K  16.4K  thinking:yes
# ornith-local  ornith-128k 131K   16.4K  thinking:yes
```

### 7c. One-command launcher — `/mnt/archive/ens/tools/bin/pi-ornith`

```bash
#!/usr/bin/env bash
# Launch Pi against the local Ornith server; auto-(re)starts llama-server at the right ctx.
#   pi-ornith            # 64K
#   pi-ornith --128k     # 128K
#   pi-ornith --128k -p "..."   # flag works with any pi args
export PATH="/mnt/archive/ens/tools/node/bin:$PATH"

CTX=65536
MODEL=ornith-local/ornith
if [ "$1" = "--128k" ]; then CTX=131072; MODEL=ornith-local/ornith-128k; shift; fi
[ -n "$ORNITH_CTX" ] && CTX="$ORNITH_CTX"

need_restart() {
  curl -sf http://localhost:8090/health >/dev/null 2>&1 || return 0
  [ "$(cat /tmp/ornith.ctx 2>/dev/null)" != "$CTX" ] && return 0
  return 1
}

if need_restart; then
  pkill -f "llama-server.*--alias ornith" 2>/dev/null && sleep 2
  echo "[pi-ornith] starting llama-server at ${CTX} context (full 4090 offload)..." >&2
  nohup /mnt/archive/ens/llama/serve-ornith.sh "$CTX" >/tmp/ornith-server.log 2>&1 &
  echo "$CTX" > /tmp/ornith.ctx
  for i in $(seq 1 90); do
    curl -sf http://localhost:8090/health >/dev/null 2>&1 && break
    grep -qiE "out of memory|failed to allocate" /tmp/ornith-server.log && {
      echo "[pi-ornith] OOM at ${CTX} ctx — use a smaller ctx or add --n-cpu-moe" >&2; exit 1; }
    sleep 2
  done
  echo "[pi-ornith] ready on :8090 (${CTX} context)" >&2
fi

exec pi --model "$MODEL" "$@"
```

Install on PATH:
```bash
chmod +x /mnt/archive/ens/tools/bin/pi-ornith
sudo ln -sf /mnt/archive/ens/tools/bin/pi-ornith /usr/local/bin/pi-ornith
```

---

## 8. Verify end-to-end

```bash
# Raw server check (reasoning model: give it room or `content` comes back empty)
curl -s http://localhost:8090/v1/chat/completions -H "Content-Type: application/json" -d '{
  "messages":[{"role":"user","content":"Reverse a string in Python, one-liner only."}],
  "max_tokens":1200, "temperature":0.6, "top_p":0.95, "top_k":20
}' | python3 -c "import sys,json;m=json.load(sys.stdin)['choices'][0]['message']; \
print('reasoning chars:', len(m.get('reasoning_content') or '')); print(m['content'])"
# -> reasoning chars: ~3500 ; s[::-1]

# Full agent loop through Pi (creates a file + runs bash to verify)
cd /tmp && pi-ornith -p "Create fizzbuzz.py printing FizzBuzz for 1..20, then stop."
cat /tmp/fizzbuzz.py
```

---

## 9. File map

| Path | What |
|---|---|
| `/mnt/archive/ens/models/ornith/ornith-1.0-35b-Q4_K_M.gguf` | the model (21 GB) |
| `/mnt/archive/ens/llama/src/` | llama.cpp source + `build/bin/` CUDA binaries |
| `/mnt/archive/ens/llama/serve-ornith.sh` | server launcher (takes ctx arg) |
| `/mnt/archive/ens/tools/node/` | Node v22.14.0 (official tarball) |
| `/mnt/archive/ens/tools/bin/pi-ornith` | Pi launcher (→ symlinked to `/usr/local/bin`) |
| `~/.pi/agent/models.json` | Pi model config (`~` = `/mnt/archive/ens`) |
| `/tmp/ornith-server.log` | server log; `/tmp/ornith.ctx` tracks running context |

---

## 10. Troubleshooting & gotchas

- **`nvidia-smi` can't talk to the driver** → driver not loaded; the rest is moot until fixed.
- **cmake too old / CUDA arch errors** → use the pip cmake (4.x), not apt's 3.16.
- **Vulkan build runs on CPU (lavapipe)** → NVIDIA Vulkan ICD missing from
  `/usr/share/vulkan/icd.d/` (it may live in `/etc/vulkan/icd.d/`). We use CUDA, not Vulkan.
- **snap Node: "home directories outside of /home"** → `$HOME` is `/mnt/archive/ens`; use the
  official Node tarball (§7a), not snap.
- **Pi answer is empty** → it's a reasoning model; raise `maxTokens` (the reasoning consumes
  the budget) and ensure `reasoning: true` in models.json.
- **OOM at 262K context** → add `--n-cpu-moe 6` to `serve-ornith.sh` (or quantize the KV cache
  with `--cache-type-k q8_0 --cache-type-v q8_0`).
- **`pi-ornith` doesn't pick up a context change** → it restarts the server only when
  `/tmp/ornith.ctx` differs from the requested context; delete that file to force a restart.
- **Tool calls are text-based** (Pi's Read/Write/Edit/Bash core over OpenAI completions), not
  native function-calling — worked cleanly in testing, but it's the layer to inspect if the
  agent ever struggles with tools.

---

## 11. Verified versions (as built)

| Thing | Version |
|---|---|
| llama.cpp | commit `050ee92d04c2e1f639025786dea701c70e7d4204` |
| CUDA nvcc | 12.3, V12.3.103 |
| NVIDIA driver | 550.144.03 |
| cmake / ninja | 4.3.4 / 1.13 |
| Node / npm | v22.14.0 / 10.9.2 |
| Pi | @mariozechner/pi-coding-agent 0.73.1 |
| Model file | `ornith-1.0-35b-Q4_K_M.gguf`, 21,166,757,760 bytes |

---

## 12. Docker

A containerized version (GPU passthrough, build-from-source image) is documented separately —
see **[docker-setup.md](docker-setup.md)**.

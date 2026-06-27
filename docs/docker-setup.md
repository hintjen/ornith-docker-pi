> **Note:** As-built reference from the original host; absolute paths like `/mnt/archive/ens/...` reflect that machine. For a portable reproduction use this repo's `scripts/` and `docker/` (see ../README.md).

# Orin / Ornith — Dockerized Coding-Agent Stack

Containerized **Ornith-1.0-35B** (Qwen3.5-MoE coding agent) served by CUDA `llama.cpp` with
GPU passthrough, plus the **Pi** coding agent. Two build paths:

| Image | Dockerfile | What it does | When to use |
|---|---|---|---|
| `ornith:latest` | `Dockerfile` | **Copies** prebuilt host artifacts (no compile) | Fast rebuilds on *this* host |
| `ornith:src` | `Dockerfile.source` | **Compiles** llama.cpp + installs Pi from pinned sources | Reproduce anywhere, host-independent |

Both mount the 20 GB model as a **read-only volume** (`/models`) — it is never baked into the image.

Everything lives in **`/mnt/archive/ens/docker/`**:

```
docker/
├── Dockerfile              # prebuilt-artifacts image (ornith:latest)
├── Dockerfile.source       # build-from-source multi-stage image (ornith:src)
├── docker-compose.yml      # one-command run (prebuilt image), GPU + model volume
├── download-model.sh       # fetch a GGUF quant from Hugging Face
├── orin_docker.md          # this file
└── artifacts/              # inputs copied into the prebuilt image
    ├── bin/                # llama.cpp CUDA binaries + .so  (used by Dockerfile only)
    ├── node/               # Node v22 + global pi           (used by Dockerfile only)
    ├── serve.sh            # in-container server launcher    (both images)
    ├── pi-ornith           # in-container Pi launcher        (both images)
    └── models.json         # Pi model config                (both images)
```

---

## 1. Host prerequisite (once) — NVIDIA Container Toolkit

Docker needs the NVIDIA runtime for `--gpus all`. Install + register:

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit   # this box: 1.19.1
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker info | grep -i runtimes        # expect: runc io.containerd.runc.v2 nvidia
```

Requires an NVIDIA driver new enough for CUDA 12.3 (this box: **550.144.03**). The driver
(`libcuda.so.1`) is injected into the container at runtime by the toolkit — not in the image.

---

## 2. Download the model

```bash
cd /mnt/archive/ens/docker
./download-model.sh                 # Q4_K_M -> /mnt/archive/ens/models/ornith  (recommended)
./download-model.sh Q5_K_M          # other quant
./download-model.sh Q8_0 /data/ornith   # custom quant + dir
```

`Q4_K_M` (21 GB) is the pick for a 24 GB GPU — the whole model fits on the card. The script
installs the `hf` CLI if missing and prints the final path/size.

---

## 3a. Run — prebuilt image (fast, this host)

```bash
cd /mnt/archive/ens/docker

# compose (recommended)
docker compose up -d --build
docker compose logs -f                 # watch for "server is listening" (~18s)

# …or plain docker
docker build -t ornith:latest .
docker run -d --name ornith --gpus all -p 8090:8090 \
  -v /mnt/archive/ens/models/ornith:/models:ro \
  ornith:latest
```

To (re)stage the artifacts from a fresh host build before building this image:
```bash
cp -al /mnt/archive/ens/llama/src/build/bin   artifacts/bin     # hardlinks, preserves symlinks
cp -al /mnt/archive/ens/tools/node            artifacts/node
cp     /mnt/archive/ens/.pi/agent/models.json artifacts/models.json
```

## 3b. Run — build from source (reproducible anywhere)

```bash
cd /mnt/archive/ens/docker
docker build -f Dockerfile.source -t ornith:src .          # compiles llama.cpp (CUDA) + installs Pi
# override pins if needed:
#   --build-arg LLAMA_COMMIT=<sha> --build-arg CUDA_ARCH=86 --build-arg PI_VERSION=0.73.1

docker run -d --name ornith --gpus all -p 8090:8090 \
  -v /mnt/archive/ens/models/ornith:/models:ro \
  ornith:src
```

`Dockerfile.source` is multi-stage: a `…-devel-ubuntu22.04` **builder** compiles llama.cpp
(`-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89 …`), and a slim `…-runtime-ubuntu22.04` stage
copies only the binaries, then downloads Node and `npm install -g @mariozechner/pi-coding-agent`.
Set `CUDA_ARCH` for non-4090 GPUs (86=Ampere/3090, 89=Ada/4090, 90=Hopper).

---

## 4. Use it

```bash
# OpenAI-compatible API on the published port
curl http://localhost:8090/v1/chat/completions -H 'Content-Type: application/json' -d \
  '{"messages":[{"role":"user","content":"Reverse a string in Python, one-liner."}],"max_tokens":1200}'

# Pi coding agent inside the container
docker exec -it ornith pi-ornith            # 64K interactive TUI
docker exec -it ornith pi-ornith --128k     # 128K context
docker exec ornith pi-ornith -p "fix the bug in foo.py"   # headless

# The HOST pi-ornith also works — its ~/.pi config points at localhost:8090 too.
```

Reasoning model: chain-of-thought is in the API `reasoning_content` field, the answer in
`content`; give generous `max_tokens` or `content` comes back empty.

---

## 5. Configuration (env vars)

Set in `docker-compose.yml`, or `-e` on `docker run`, or `docker exec -e`:

| Var | Default | Meaning |
|---|---|---|
| `ORNITH_CTX` | `65536` | context window. 65536≈22 GB · 131072≈23.4 GB · 262144 needs `ORNITH_NCMOE>0` |
| `ORNITH_NCMOE` | `0` | expert layers kept on CPU. `0` = whole model on GPU (fastest). Raise to free VRAM |
| `ORNITH_MODEL` | `/models/ornith-1.0-35b-Q4_K_M.gguf` | model path inside the container |

Measured (Q4_K_M, full offload): ~22 GB VRAM @ 64K, **~210 tok/s gen / ~5200 tok/s prefill**
on bare metal; ~198 tok/s inside the container.

---

## 6. How GPU & libraries resolve

- **Base image** provides CUDA 12.3 `libcudart` / `libcublas` / `libcublasLt` matching the
  nvcc the binaries were built with.
- `libgomp1` (OpenMP) added via apt; `curl` for the HEALTHCHECK.
- **`libcuda.so.1`** (the driver) is injected at run time by nvidia-container-toolkit; the
  `ENV NVIDIA_VISIBLE_DEVICES=all` + `NVIDIA_DRIVER_CAPABILITIES=compute,utility` declare it,
  and `--gpus all` (or the compose `deploy.resources` block) activates it.
- glibc: prebuilt image uses **ubuntu20.04** (matches the host that built the binaries);
  the from-source image uses **ubuntu22.04** end-to-end (builds and runs in the same base).

Verify passthrough:
```bash
docker exec ornith nvidia-smi --query-gpu=name,memory.used --format=csv,noheader
# NVIDIA GeForce RTX 4090, <~22000> MiB
```

---

## 7. In-container file map

| Path | Source |
|---|---|
| `/opt/ornith/bin/` | llama.cpp CUDA binaries (`COPY` or `--from=builder`) |
| `/opt/ornith/node/` | Node + global `pi` |
| `/opt/ornith/serve.sh` | env-driven `llama-server` launcher (CMD) |
| `/opt/ornith/pi-ornith` | Pi launcher |
| `/root/.pi/agent/models.json` | Pi model config (`ornith` 64K + `ornith-128k`) |
| `/models/…Q4_K_M.gguf` | **volume mount** from host |

---

## 8. Troubleshooting

- **`docker: could not select device driver "" with capabilities: [[gpu]]`** → toolkit not
  installed/registered; redo §1 and restart docker.
- **`nvidia-smi` works on host but not in container** → missing `--gpus all` / compose
  `deploy.resources` block, or `NVIDIA_VISIBLE_DEVICES` not set.
- **OOM on load** → context too large for the quant; lower `ORNITH_CTX` or raise `ORNITH_NCMOE`.
- **Port 8090 already in use** → stop the host `llama-server` (`pkill -f 'llama-server.*--alias ornith'`)
  or change the published port (`-p 8091:8090`).
- **Dockerfile inline comments** → not allowed on instruction lines (`ARG x=1 # note` fails);
  put comments on their own line.
- **Empty Pi answer** → reasoning model; raise `maxTokens` in `~/.pi/agent/models.json`.
- **Second container OOMs on load** → only **one** container can hold the full model at full
  offload on a single 24 GB GPU (~22 GB each). Stop the other (`docker stop ornith`) before
  starting a second, or give one a smaller `ORNITH_CTX` / higher `ORNITH_NCMOE`.
- **Source build fails at link: `undefined reference to cuMem*` / `libcuda.so.1 not found`** →
  the build container has no driver. `Dockerfile.source` fixes this by symlinking the CUDA
  driver **stub** to its SONAME (`ln -sf …/stubs/libcuda.so /usr/lib/x86_64-linux-gnu/libcuda.so.1
  && ldconfig`) before compiling. The stub is link-time only; the real driver is injected at run time.

---

## 9. Pinned versions

| Thing | Version |
|---|---|
| Base (prebuilt) | `nvidia/cuda:12.3.2-runtime-ubuntu20.04` |
| Base (source) | `nvidia/cuda:12.3.2-devel/-runtime-ubuntu22.04` |
| llama.cpp | commit `050ee92d04c2e1f639025786dea701c70e7d4204` |
| CUDA arch | `89` (Ada / RTX 4090) |
| Node | `v22.14.0` |
| Pi | `@mariozechner/pi-coding-agent@0.73.1` |
| NVIDIA Container Toolkit | `1.19.1` |
| Host driver | `550.144.03` |
| Model | `ornith-1.0-35b-Q4_K_M.gguf` (21,166,757,760 bytes) |

> Full bare-metal build/benchmark details: `/mnt/archive/ens/llama/ORNITH-1.0-35B-RTX4090-SETUP.md`.

# Ornith-1.0-35B — Docker setup (GPU passthrough)

Run Ornith-1.0-35B in a container with the GPU passed through. The image **compiles llama.cpp
from source** (`docker/Dockerfile.source`) and installs the Pi agent; the 20 GB model is mounted
as a **read-only volume** at `/models`, never baked into the image.

Run all commands from the **repo root**. For the bare-metal (no-Docker) path, see
[baremetal-setup.md](baremetal-setup.md).

```
docker-compose.yml            # build-from-source image + GPU + ./models volume
docker/
├── Dockerfile.source         # multi-stage: compile llama.cpp (CUDA) + install Node/Pi
└── container/
    ├── serve.sh              # in-container llama-server launcher (CMD)
    └── pi-ornith             # in-container Pi launcher
config/pi-models.json         # Pi model config, baked to /root/.pi/agent/models.json
```

---

## 1. Host prerequisite (once) — NVIDIA Container Toolkit

`--gpus all` needs Docker's NVIDIA runtime. Run `sudo ./scripts/00-host-prereqs.sh`, or manually:

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker info | grep -i runtimes        # expect: runc io.containerd.runc.v2 nvidia
```

Needs an NVIDIA driver new enough for CUDA 12.3 (reference box: **550.144.03**). The driver
(`libcuda.so.1`) is injected into the container at run time by the toolkit — never in the image.

---

## 2. Download the model

```bash
./scripts/10-download-model.sh          # Q4_K_M (~21 GB) -> ./models   (recommended for 24 GB)
./scripts/10-download-model.sh Q5_K_M   # other quant
```

---

## 3. Build & run

```bash
docker compose up -d --build            # builds ornith:src, mounts ./models, reserves the GPU
docker compose logs -f                  # wait for "server is listening" (~18s)
```

Or without compose:

```bash
docker build -f docker/Dockerfile.source -t ornith:src .
docker run -d --name ornith --gpus all -p 8090:8090 \
  -v "$PWD/models:/models:ro" ornith:src
# override pins:  --build-arg LLAMA_COMMIT=<sha>  --build-arg CUDA_ARCH=86  --build-arg PI_VERSION=0.80.2
```

`Dockerfile.source` is multi-stage: a `cuda:12.3.2-devel-ubuntu22.04` **builder** compiles
llama.cpp (`-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89 …`); a slim `…-runtime-ubuntu22.04`
stage copies just the binaries and adds Node + Pi. Set `CUDA_ARCH` for other GPUs
(86=Ampere/3090, 89=Ada/4090, 90=Hopper).

---

## 4. Use it

```bash
# OpenAI-compatible API on the published port
curl http://localhost:8090/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Reverse a string in Python, one-liner."}],"max_tokens":1200}'

# Pi coding agent inside the container
docker exec -it ornith pi-ornith            # 64K interactive TUI
docker exec -it ornith pi-ornith --128k     # 128K context
docker exec ornith pi-ornith -p "fix the bug in foo.py"   # headless
```

The **host** `pi-ornith` works too — its `~/.pi/agent/models.json` also points at `localhost:8090`.

Ornith is a *reasoning* model: chain-of-thought goes to the API `reasoning_content` field, the
answer to `content`. Give generous `max_tokens` or `content` comes back empty.

---

## 5. Configuration (env vars)

Set in `docker-compose.yml`, or `-e` on `docker run`:

| Var | Default | Meaning |
|---|---|---|
| `ORNITH_CTX` | `65536` | context window. 65536 ≈ 22 GB · 131072 ≈ 23.4 GB · 262144 needs `ORNITH_NCMOE>0` |
| `ORNITH_NCMOE` | `0` | expert layers kept on CPU. `0` = whole model on GPU (fastest); raise to free VRAM |
| `ORNITH_MODEL` | `/models/ornith-1.0-35b-Q4_K_M.gguf` | model path inside the container |

Measured on the reference 4090 (Q4_K_M, full offload): ~22 GB VRAM @ 64K, **~198 tok/s gen**
in-container (~210 bare metal).

---

## 6. How GPU & libraries resolve

- The `…-runtime` base image provides CUDA 12.3 `libcudart` / `libcublas` / `libcublasLt`.
- `libgomp1` (OpenMP) is added via apt; `curl` for the HEALTHCHECK.
- **`libcuda.so.1`** (the driver) is injected at run time by nvidia-container-toolkit. `ENV
  NVIDIA_VISIBLE_DEVICES=all` + `NVIDIA_DRIVER_CAPABILITIES=compute,utility` declare it; `--gpus all`
  (or the compose `deploy.resources` block) activates it.
- **Build-time link fix:** the builder stage has no driver, so `Dockerfile.source` symlinks the
  CUDA driver *stub* to its SONAME (`ln -sf …/stubs/libcuda.so /usr/lib/x86_64-linux-gnu/libcuda.so.1`)
  before compiling — otherwise the final link fails with `undefined reference to cuMem*`. The stub
  is link-time only.

Verify passthrough:
```bash
docker exec ornith nvidia-smi --query-gpu=name,memory.used --format=csv,noheader
# NVIDIA GeForce RTX 4090, ~22000 MiB
```

---

## 7. In-container file map

| Path | Source |
|---|---|
| `/opt/ornith/bin/` | llama.cpp CUDA binaries (`--from=builder`) |
| `/opt/ornith/node/` | Node + global `pi` |
| `/opt/ornith/serve.sh` | env-driven `llama-server` launcher (CMD) |
| `/opt/ornith/pi-ornith` | Pi launcher |
| `/root/.pi/agent/models.json` | Pi model config (`ornith` 64K + `ornith-128k`) |
| `/models/…Q4_K_M.gguf` | **volume mount** from host |

---

## 8. Troubleshooting

- **`could not select device driver "" with capabilities: [[gpu]]`** → toolkit not installed/
  registered; redo §1 and restart docker.
- **`nvidia-smi` works on host but not in container** → missing `--gpus all` / compose
  `deploy.resources`, or `NVIDIA_VISIBLE_DEVICES` unset.
- **OOM on load** → context too large; lower `ORNITH_CTX` or raise `ORNITH_NCMOE`.
- **Only one model at a time** → a single 24 GB GPU holds one full-offload instance (~22 GB).
  Stop the other (`docker stop ornith`) before starting a second.
- **Port 8090 in use** → stop the host server (`pkill -f 'llama-server.*--alias ornith'`) or
  publish elsewhere (`-p 8091:8090`).
- **Dockerfile inline comments** → not allowed on instruction lines (`ARG x=1 # note` fails);
  put comments on their own line.

---

## 9. Pinned versions

| Thing | Version |
|---|---|
| Base images | `nvidia/cuda:12.3.2-{devel,runtime}-ubuntu22.04` |
| llama.cpp | commit `050ee92d04c2e1f639025786dea701c70e7d4204` |
| CUDA arch | `89` (Ada / RTX 4090) |
| Node / Pi | `v24.18.0` (LTS) / `@earendil-works/pi-coding-agent@0.80.2` |
| NVIDIA Container Toolkit | `1.19.1` |
| Host driver | `550.144.03` |
| Model | `ornith-1.0-35b-Q4_K_M.gguf` (21,166,757,760 bytes) |

---

## Appendix — faster "prebuilt artifacts" image (not in this repo)

On the original host a second image copied the already-built host binaries instead of compiling
(image ~2.85 GB, base `…-runtime-ubuntu20.04` to match the host's glibc). It rebuilds in seconds
but is host-specific — so it's omitted here in favor of the portable from-source image above.
The recipe (a `Dockerfile` that `COPY`s a staged `artifacts/{bin,node}` directory) is preserved
in the project history if you need the fast-rebuild path on an identical host.

# Docker Quickstart

Day-to-day operation of the Ornith coding-agent container. Run everything from the repo root.
For how the image is built and why, see [docker-setup.md](docker-setup.md).

---

## First time

```bash
sudo ./scripts/00-host-prereqs.sh     # once per host: NVIDIA Container Toolkit
./scripts/10-download-model.sh        # once: download Q4_K_M (~21 GB) -> ./models
docker compose up -d --build          # build image + start server (first build compiles llama.cpp)
docker compose logs -f                # wait for "server is listening" (~18s), then Ctrl-C
```

> **Order matters:** download the model **before** `docker compose up`. Compose mounts `./models`,
> and if it doesn't exist yet Docker creates it **root-owned**, which then breaks the (non-root)
> download with `Permission denied: …/models/.cache`. If that happened:
> `sudo chown -R "$USER:$USER" models` and re-run the download.

The OpenAI-compatible API is now on `http://localhost:8090`.

---

## Start / stop / status

```bash
docker compose up -d         # start (in background)
docker compose stop          # stop, keep the container
docker compose start         # start it again (no rebuild, model reloads in ~18s)
docker compose restart       # restart
docker compose down          # stop AND remove the container (image + model are kept)

docker ps --filter name=ornith        # is it running?
curl -sf localhost:8090/health && echo OK   # is the server ready?
docker compose logs -f                 # live logs
docker stats ornith                    # live CPU/mem (GPU: use nvidia-smi)
nvidia-smi                             # GPU memory in use (~22 GB when loaded)
```

> Only **one** instance can hold the model on a single 24 GB GPU. Always `stop`/`down` the
> running one before starting another.

---

## Use the coding agent

```bash
# Interactive TUI — run in a real terminal (needs -it)
docker exec -it ornith pi-ornith            # 64K context
docker exec -it ornith pi-ornith --128k     # 128K context

# Headless / one-shot — works from any shell
docker exec ornith pi-ornith -p "explain the failing test"
```

### Work on your own code

The container only sees files mounted into it. Mount your project at `/work`:

```bash
docker compose down                          # free the GPU first
docker run -d --name ornith --gpus all -p 8090:8090 \
  -v "$PWD/models:/models:ro" \
  -v "$HOME/myproject:/work" \
  ornith:src
docker exec -it -w /work ornith pi-ornith    # Pi now operates in /work
```

To make this permanent, add the project line under `volumes:` in `docker-compose.yml`.

---

## Resuming a session

Pi saves each chat as a `.jsonl` under `~/.pi/agent/sessions/`, **bucketed by working
directory**. Two rules make `--resume` actually find them:

1. **Sessions now persist** outside the container via the `./pi-sessions` volume (see
   `docker-compose.yml`), so they survive `docker compose down` / rebuilds. *Without that
   volume they live in the container's writable layer and are wiped on every recreate —
   that's the usual "no previous sessions found".*
2. **Resume from the same directory** you started in. Pi only lists sessions for the current
   cwd, so attach the same way each time (e.g. always `-w /work`, or always plain).

```bash
docker exec -it ornith pi-ornith --continue          # resume the most recent session
docker exec -it ornith pi-ornith --resume            # interactive picker
docker exec -it ornith pi-ornith --session <uuid>    # a specific session (partial UUID ok)
docker exec -it -w /work ornith pi-ornith --continue # match the cwd you created it in
```

(`pi-ornith` passes any flags straight through to `pi`, so `--128k --continue` also works.)
Browse history on the host: `sudo ls pi-sessions/` (files are written by the container as root).
Note: the **host** `pi` and the **container** `pi` keep separate histories (different `~/.pi`).

---

## Change context size

Edit `ORNITH_CTX` in `docker-compose.yml` (`65536` = 64K, `131072` = 128K), then:

```bash
docker compose up -d        # recreates the container with the new setting
```

Or per-run: `docker run -e ORNITH_CTX=131072 …`.

---

## Update / rebuild

```bash
git pull                              # if you changed the repo
docker compose up -d --build          # rebuild image and restart
docker image prune -f                 # reclaim space from old layers
```

---

## Remove everything

```bash
docker compose down                   # stop + remove container
docker rmi ornith:src                 # remove the image
# the model in ./models is untouched; delete it manually if you want the ~21 GB back
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `could not select device driver … [[gpu]]` | NVIDIA toolkit not registered — rerun `sudo ./scripts/00-host-prereqs.sh`, restart Docker |
| Container exits / unhealthy on start | `docker compose logs ornith`; usually OOM — lower `ORNITH_CTX` or raise `ORNITH_NCMOE` |
| `bind: address already in use` (8090) | another server is up — `docker compose down`, or publish elsewhere: `-p 8091:8090` |
| Pi answer comes back empty | reasoning model — it's still "thinking"; allow more output (already configured) |
| Download interrupted / slow | it's pure `curl`/`wget` (no Python) and **resumable** — just re-run `./scripts/10-download-model.sh`. Needs `curl` or `wget` installed |
| `nvidia-smi` fine on host, fails in container | start with `--gpus all` (compose handles this via `deploy.resources`) |

---

## Cheatsheet

```bash
docker compose up -d                     # start
docker compose down                      # stop + remove
docker exec -it ornith pi-ornith         # agent (TUI)
docker exec ornith pi-ornith -p "..."    # agent (headless)
curl localhost:8090/health               # health
docker compose logs -f                   # logs
```

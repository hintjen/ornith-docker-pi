# Local model eval strategy — session handoff

Working doc seeded from the 2026-08-07 session that stood up Laguna XS 2.1 alongside
Ornith on the RTX 4090 box. Captures what's running, what we learned, and the open
questions to pick up when developing an eval strategy for these local models.

## Current state

Two models servable on the GPU box (`192.168.122.26` / `orinth-dev`), one at a time
(both need most of a 24GB card):

| | Ornith-1.0-35B | Laguna XS 2.1 |
|---|---|---|
| Size | 34.66B total / ~3B active (MoE) | 33B total / 3B active (MoE) |
| Quant | Q4_K_M, 21.2GB | Q4_K_M, 20.3GB |
| Serving | Docker (`~/orinth-docker`, `docker compose`) | Docker, manual `docker run` (image `laguna:src`) |
| Context (settled) | 65536 | 65536 (2.8GB free at 32768, 1.5GB at 65536, dangerously tight 234MB at 98304, OOMs at 131072) |
| Key flag gotcha | none known | **do not pass `--swa-full`** — forces full-context KV cache on all 40 layers instead of the sliding-window cache on 30 of them, OOMs even at 32768 ctx |
| llama.cpp build | pinned commit `050ee92d...` (older) | pinned commit `1f66c3ce1c26c95db3fadb734086c7d9fba23bb9` (Laguna support merged upstream 2026-07-22, PR ggml-org/llama.cpp#25165) |

Repo: [hintjen/ornith-docker-pi](https://github.com/hintjen/ornith-docker-pi) (renamed
from `orinth-docker`; old GitHub URL still redirects). Also mirrored at
`ssh://git@ssh.fraigent.com/fraigent/llama-pi.git`. Local dev clone: `~/ornith-docker-pi`.

**Quick access:**
```bash
pi-laguna                 # ~/.local/bin wrapper, zero-arg, connects to the GPU box's Laguna server
pi-laguna -p "prompt"      # headless one-shot
./scripts/pi-remote 192.168.122.26:8090        # generic remote connector (Ornith by default)
```

Both models expose an OpenAI-compatible `/v1/chat/completions` **and** an
Anthropic-compatible `/v1/messages` endpoint on `:8090`. Pi talks OpenAI-style;
Claude Code talks Anthropic-style.

## Key learnings this session

- **Claude Code cannot talk to Ornith** (and would hit the same issue with Laguna):
  Claude Code always sends its system prompt as multiple content blocks, the
  server's Anthropic-API shim explodes those into multiple `role: system`
  messages, and the model's chat template hard-rejects any system message that
  isn't first. Confirmed server-side, not fixable via Claude Code settings. Pi
  works because it collapses everything into one system message client-side.
  Full writeup: memory `project_llama_ornith_system_message_bug`.
- **Disk-full on the GPU box masquerades as GPG/network errors.** `apt-get
  update` inside a Docker build failed with "invalid signature" on every repo
  simultaneously (NVIDIA + all Ubuntu mirrors) — looked like a network/proxy/MITM
  issue, real IPs, correct clock, no proxy config. Actual cause: the host was at
  or near 0 bytes free, silently truncating/corrupting the downloads. Check
  `df -h` before chasing network theories on this box.
- **`Linger=no` on the GPU box kills backgrounded SSH jobs within seconds** of
  the SSH command returning, even under `nohup` — systemd reaps the whole
  session cgroup. Fix: hold the SSH connection open (foreground remotely,
  background only the SSH invocation itself locally), not remote `nohup &`.
- **`--swa-full` is a trap for VRAM-constrained boxes.** Upstream calls it
  "effectively mandatory for prefix reuse" on Laguna, but it disables the
  memory-efficient sliding-window KV cache Laguna's architecture is built
  for. Costs ~3-4x the VRAM for no correctness benefit at these context sizes.
- **Pi natively loads `CLAUDE.md`/`AGENTS.md`** the same way Claude Code does —
  global (`~/.pi/agent/AGENTS.md`), parent-directory walk, and cwd. Confirmed
  from Pi's own bundled docs, not assumed. This means any Claude-Code-oriented
  agent repo (with a `CLAUDE.md`) works unchanged under Pi.
- **`~/.pi/agent/models.json` is a shared, global, non-project-scoped config
  file.** Every `pi-remote`/`pi-laguna`/`40-configure-pi.sh` invocation on this
  machine overwrites it. This collided with the `session-archaeologist` fleet
  agent, which is *also* running on Pi and picked up the Laguna config from our
  testing.

## A real finding that should shape the eval strategy

While testing tonight, we found `session-archaeologist` (a fleet agent whose job
is mining Claude Code transcripts for abandoned/unfinished ideas) running against
Laguna at 65536 context, and it was **thrashing**: 9 compactions in ~7.5 minutes,
each one firing at ~60-73K tokens (right at the context ceiling), with the
retained summary barely growing between cycles. It was reading a transcript file
too large to fit in 65536 tokens, so every few tool calls forced a compaction
that discarded most of what it had just read — it never got far enough into any
one file to actually extract a loose thread.

This is a concrete signal: **"does it respond correctly to a short prompt" (our
PONG smoke tests) says nothing about whether a model/context combo can actually
do real agentic work.** A model that answers cleanly at low context can still be
useless for transcript-mining, long-refactor, or multi-file tasks if the context
ceiling forces constant compaction. Any eval strategy for these local models
needs to account for *sustained* task performance under realistic context
pressure, not just single-turn correctness.

## Open questions to develop into an eval strategy

- What's the actual usable task set for Ornith vs. Laguna given the VRAM-imposed
  context ceilings (65536 for both, on this box)? Coding tasks that fit
  comfortably vs. ones (like transcript mining) that inherently need more.
- How do we measure "thrashing" quantitatively — compactions per task, tokens
  discarded per compaction, task completion rate vs. context ceiling — rather
  than discovering it anecdotally like tonight?
- Is there a principled way to trade `--n-cpu-moe` (offload experts to CPU, free
  VRAM, raise context) against throughput, and where's the knee of that curve
  for realistic agentic workloads (not just raw tok/s benchmarks)?
- Should `session-archaeologist` (and similar transcript-heavy agents) be
  pointed at a different model/host entirely rather than sharing this
  VRAM-constrained box, or is there a context-efficient way to chunk its
  transcript-mining work to fit 65536?
- Ornith vs. Laguna head-to-head on the same coding tasks — no comparison done
  yet, only independent smoke tests.
- Worth benchmarking against a cloud model (e.g. what `session-archaeologist`
  or other fleet agents use today) as a quality/cost baseline?
- Do we need per-agent model config instead of the single shared
  `~/.pi/agent/models.json`, given the collision we hit tonight?

## Relevant scripts (this repo)

- `scripts/serve-ornith.sh` / `scripts/serve-laguna.sh` — start each model's server
- `scripts/pi-ornith` / `scripts/pi-laguna` — local Pi launchers (bare metal)
- `scripts/pi-remote` — connect Pi to any remote host running either server
- `scripts/15-download-laguna.sh`, `scripts/25-build-llama-laguna.sh` — Laguna-specific setup
- `config/pi-models.json` — shared model catalogue (`ornith`, `ornith-128k`, `laguna`)
- `~/.local/bin/pi-laguna` — zero-arg wrapper on this dev machine, hardcoded to the GPU box

#!/usr/bin/env bash
# Download an Ornith-1.0-35B GGUF quant straight from Hugging Face with curl/wget.
# No Python, no huggingface_hub, no venv — the files are public over plain HTTPS.
#
#   ./scripts/10-download-model.sh [QUANT] [DEST_DIR]
#
#   QUANT     Q4_K_M (default) | Q5_K_M | Q6_K | Q8_0 | bf16
#   DEST_DIR  default: <repo>/models  (override with $ORNITH_MODEL_DIR)
#
# The download resumes if interrupted — just re-run the same command.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

REPO="deepreinforce-ai/Ornith-1.0-35B-GGUF"
QUANT="${1:-Q4_K_M}"
DEST="${2:-${ORNITH_MODEL_DIR:-$HERE/models}}"
FILE="ornith-1.0-35b-${QUANT}.gguf"
URL="https://huggingface.co/${REPO}/resolve/main/${FILE}"
OUT="$DEST/$FILE"

echo "[download] $FILE -> $DEST"
mkdir -p "$DEST" 2>/dev/null || true
# Guard against a root-owned models/ (Docker creates the bind-mount dir as root if you
# 'docker compose up' before downloading) — writes would fail with EACCES otherwise.
if ! { [ -d "$DEST" ] && touch "$DEST/.write_test" 2>/dev/null; }; then
  echo "[download] ERROR: $DEST is not writable by $(id -un)." >&2
  echo "[download]   Fix:  sudo chown -R \"$(id -un):$(id -gn)\" \"$DEST\"" >&2
  exit 1
fi
rm -f "$DEST/.write_test"

# Remote size: follow the redirect to the CDN and read the final Content-Length.
EXPECT="$(curl -sIL "$URL" | awk 'tolower($0) ~ /^content-length:/ {n=$2} END{gsub(/\r/,"",n); print n}')" || true
[ -n "${EXPECT:-}" ] && echo "[download] remote size: $EXPECT bytes"

# Skip if already fully downloaded.
if [ -f "$OUT" ] && [ -n "${EXPECT:-}" ] && [ "$(stat -c %s "$OUT")" = "$EXPECT" ]; then
  echo "[download] already complete: $OUT"
  exit 0
fi

echo "[download] fetching (resumable)..."
if command -v curl >/dev/null 2>&1; then
  curl -L --fail --retry 5 --retry-delay 5 -C - -o "$OUT" "$URL"
elif command -v wget >/dev/null 2>&1; then
  wget -c -P "$DEST" "$URL"
else
  echo "[download] ERROR: need 'curl' or 'wget' installed" >&2
  exit 1
fi

GOT="$(stat -c %s "$OUT" 2>/dev/null || echo 0)"
if [ -n "${EXPECT:-}" ] && [ "$EXPECT" != "$GOT" ]; then
  echo "[download] WARNING: size mismatch (expected $EXPECT, got $GOT) — re-run to resume/repair." >&2
  exit 1
fi
echo "[download] done: $OUT ($GOT bytes)"

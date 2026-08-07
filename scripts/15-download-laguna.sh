#!/usr/bin/env bash
# Download a Laguna XS 2.1 GGUF quant straight from Hugging Face with curl/wget.
# Mirrors 10-download-model.sh but writes to a SEPARATE directory (models-laguna/)
# so it never collides with serve-ornith.sh's `ls models/*Q4_K_M*.gguf | head -1`
# auto-detect — dropping this file into models/ would silently hijack that glob.
#
#   ./scripts/15-download-laguna.sh [QUANT] [DEST_DIR]
#
#   QUANT     Q4_K_M (default) | BF16
#   DEST_DIR  default: <repo>/models-laguna  (override with $LAGUNA_MODEL_DIR)
#
# The download resumes if interrupted — just re-run the same command.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

REPO="poolside/Laguna-XS-2.1-GGUF"
QUANT="${1:-Q4_K_M}"
DEST="${2:-${LAGUNA_MODEL_DIR:-$HERE/models-laguna}}"
FILE="Laguna-XS-2.1-${QUANT}.gguf"
URL="https://huggingface.co/${REPO}/resolve/main/${FILE}"
OUT="$DEST/$FILE"

echo "[download] $FILE -> $DEST"
mkdir -p "$DEST" 2>/dev/null || true
if ! { [ -d "$DEST" ] && touch "$DEST/.write_test" 2>/dev/null; }; then
  echo "[download] ERROR: $DEST is not writable by $(id -un)." >&2
  echo "[download]   Fix:  sudo chown -R \"$(id -un):$(id -gn)\" \"$DEST\"" >&2
  exit 1
fi
rm -f "$DEST/.write_test"

EXPECT="$(curl -sIL "$URL" | awk 'tolower($0) ~ /^content-length:/ {n=$2} END{gsub(/\r/,"",n); print n}')" || true
[ -n "${EXPECT:-}" ] && echo "[download] remote size: $EXPECT bytes"

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

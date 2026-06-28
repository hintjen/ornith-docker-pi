#!/usr/bin/env bash
# Install the Pi model config so `pi` can reach an Ornith server (local OR remote).
#
#   ./scripts/40-configure-pi.sh                                  # -> http://localhost:8090
#   ORNITH_SERVER_URL=gpu-box        ./scripts/40-configure-pi.sh # -> http://gpu-box:8090
#   ORNITH_SERVER_URL=gpu-box:9001   ./scripts/40-configure-pi.sh
#   ORNITH_SERVER_URL=http://1.2.3.4:8090/v1 ./scripts/40-configure-pi.sh
#
# Env: ORNITH_SERVER_URL (host | host:port | full url); PI_CONFIG_DIR (default ~/.pi/agent)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${PI_CONFIG_DIR:-$HOME/.pi/agent}"

# Normalize ORNITH_SERVER_URL -> http://host:port/v1
raw="${ORNITH_SERVER_URL:-http://localhost:8090}"
case "$raw" in
  http://*|https://*) base="$raw" ;;          # full url
  *:[0-9]*)           base="http://$raw" ;;    # host:port
  *)                  base="http://$raw:8090" ;; # bare host -> default port
esac
base="${base%/}"
case "$base" in */v1) ;; *) base="$base/v1" ;; esac

mkdir -p "$DEST"
# Substitute the provider baseUrl in the template, keep everything else.
sed "s#\"baseUrl\": *\"[^\"]*\"#\"baseUrl\": \"$base\"#" "$HERE/config/pi-models.json" > "$DEST/models.json"
echo "[pi] wrote $DEST/models.json (provider ornith-local -> $base)"

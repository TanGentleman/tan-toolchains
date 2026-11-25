#!/usr/bin/env bash
# pi-container/run.sh with pi-proxy forwarding model calls to the local
# gateway instead of openrouter.ai. Takes run.sh's arguments:
#   pi.sh check | pi.sh | pi.sh -p "prompt" | pi.sh --instance NAME ...
# Needs `serve.sh pi` running. Plain run.sh afterwards switches back.
set -euo pipefail
. "$(dirname "$0")/env.sh"
[ -f "$INKLING_HOME/run/pi" ] && curl -fsS -m 5 "http://127.0.0.1:$port/health" >/dev/null ||
  die "gateway not running for Pi; start: $spike_dir/serve.sh pi"
read -r gw _ <<<"$(container_net)"
export PI_PROXY_OPENROUTER_HOST=$gw PI_PROXY_OPENROUTER_PORT=$port PI_PROXY_OPENROUTER_TLS=0
exec "$spike_dir/../../pi-container/run.sh" "$@"

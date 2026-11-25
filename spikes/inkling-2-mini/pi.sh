#!/usr/bin/env bash
# pi-container/run.sh with pi-proxy forwarding model calls to the local
# gateway instead of openrouter.ai. Takes run.sh's arguments:
#   pi.sh check | pi.sh | pi.sh -p "prompt" | pi.sh --instance NAME ...
# Needs `serve.sh pi` running. Plain run.sh afterwards switches back.
set -euo pipefail
. "$(dirname "$0")/env.sh"
gw=$(container_gateway)
curl -fsS -m 5 "http://$gw:$port/health" >/dev/null ||
  die "no gateway on $gw:$port; start: $spike_dir/serve.sh pi"
export PI_PROXY_OPENROUTER_HOST=$gw PI_PROXY_OPENROUTER_PORT=$port PI_PROXY_OPENROUTER_TLS=0
exec "$spike_dir/../../pi-container/run.sh" "$@"

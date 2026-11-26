#!/usr/bin/env bash
# pi-container/run.sh in offline egress mode: pi-proxy sends model calls only
# to the local gateway, refuses openrouter.ai and GitHub, and Pi gets no GitHub
# token. Takes run.sh's arguments:
#   pi.sh check | pi.sh | pi.sh pi -p "prompt" | pi.sh --instance NAME ...
# PI_EGRESS=normal pi.sh keeps GitHub (model calls still go to the gateway).
# Needs `inkling up pi`. Plain run.sh afterwards switches back.
set -euo pipefail
. "$(dirname "$0")/env.sh"
gw=$(container_gateway)
# $gw may not exist yet; run.sh's pi-proxy brings it up and the gateway binds then.
[ -f "$INKLING_HOME/run/pi" ] && curl -fsS -m 5 "http://127.0.0.1:$port/health" >/dev/null ||
  die "gateway not running for Pi; start: $spike_dir/inkling up pi"
export PI_EGRESS=${PI_EGRESS:-offline}
export PI_PROXY_OPENROUTER_HOST=$gw PI_PROXY_OPENROUTER_PORT=$port PI_PROXY_OPENROUTER_TLS=0
exec "$spike_dir/../../pi-container/run.sh" "$@"

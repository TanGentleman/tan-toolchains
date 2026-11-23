#!/usr/bin/env bash
# Pi through fleetd and sandbox/pi-v86.sh, against a fake model that asks for
# one bash call. Passes if that call wrote to $FLEET_WORK on the host but could
# not see the session's state, the OpenRouter key or the network. No key needed.
# Skips unless FLEET_SANDBOX_DIR is an npm prefix with external-sandbox-v86 and
# external-sandbox-pi installed and pi is on PATH (docs/sandbox.md).
set -euo pipefail
cd "$(dirname "$0")/.."
D="${FLEET_SANDBOX_DIR:-}"
ext="$D/node_modules/external-sandbox-pi/src/index.ts"
if [ -z "$D" ] || [ ! -x "$D/node_modules/.bin/external-sandbox-v86" ] || [ ! -f "$ext" ] || ! command -v pi >/dev/null; then
  echo "sandbox: SKIP (set FLEET_SANDBOX_DIR, see docs/sandbox.md)"
  exit 0
fi
tmp=$(mktemp -d)
pids=()
trap 'kill "${pids[@]}" 2>/dev/null; rm -rf "$tmp"' EXIT
go build -o "$tmp/fleetd" ./cmd/fleetd
free() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
mp=$(free)
fp=$(free)
data="$tmp/data"
cmd="echo in-guest > proof.txt
ls -d $data/sessions/*/state >/dev/null 2>&1 && echo LEAK-state || echo no-state
printenv OPENROUTER_API_KEY >/dev/null && echo LEAK-key || echo no-key
wget -q -T 3 -O /dev/null http://example.com 2>/dev/null && echo LEAK-net || echo no-net"
python3 e2e/sandbox/model.py "$mp" "$cmd" &
pids+=($!)
FLEET_SANDBOX_V86="$D/node_modules/.bin/external-sandbox-v86" FLEET_SANDBOX_PI_EXT="$ext" FLEETD="$tmp/fleetd" \
OPENROUTER_API_KEY=sk-or-v1-placeholder FLEET_OPENROUTER_BASE="http://127.0.0.1:$mp/api" \
  "$tmp/fleetd" -name sbx -url "http://127.0.0.1:$fp" -data "$data" -listen "127.0.0.1:$fp" -owner t \
  -harness "pi-sbx=$PWD/sandbox/pi-v86.sh" 2>"$tmp/fleetd.log" &
pids+=($!)
api="http://127.0.0.1:$fp/v1"
H='Tailscale-User-Login: t'
for _ in $(seq 100); do curl -fs -H "$H" "$api/node" >/dev/null && break; sleep 0.1; done
sid=$(curl -fs -H "$H" -H 'Content-Type: application/json' -X POST "$api/sessions" \
  -d '{"harness":"pi-sbx","model":"fake/model","key":"k1","prompt":"go"}' | jq -r .sid)
for _ in $(seq 600); do
  [ "$(curl -fs -H "$H" "$api/sessions/$sid" | jq -c '[.running, .run]')" = '[false,1]' ] && break
  sleep 0.2
done
curl -fs -H "$H" "$api/sessions/$sid/events" > "$tmp/events.jsonl"
got=$(jq -r 'select(.kind == "out") | .data | fromjson | select(.type == "tool_execution_end") | .result.content[0].text' "$tmp/events.jsonl")
end=$(jq -c 'select(.kind == "out") | .data | fromjson | select(.type == "fleet.turn_end")' "$tmp/events.jsonl")
want=$'no-state\nno-key\nno-net'
if [ "$got" != "$want" ] || [ "$(jq -r '.code' <<<"$end")" != 0 ] || [ "$(jq -r '.error // ""' <<<"$end")" != "" ] \
  || [ "$(cat "$data/sessions/$sid/work/proof.txt" 2>/dev/null)" != in-guest ]; then
  echo "sandbox: FAIL"; echo "tool output: $got"; echo "turn_end: $end"; cat "$tmp/fleetd.log" "$data/sessions/$sid"/stderr-*.log 2>/dev/null
  exit 1
fi
echo "sandbox: ok ($sid)"

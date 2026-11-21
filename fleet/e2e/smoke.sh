#!/usr/bin/env bash
# Two real fleetd processes on loopback with dev identities. Covers spawn,
# replication, handoff, kill -9 of the writer mid-turn, restart and fork.
# PI=<path to pi> also runs a Pi session (needs a model; see IMPLEMENTATION.md).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$T"' EXIT
go build -o "$T/fleetd" ./cmd/fleetd
cat > "$T/policy.json" <<'P'
{"tan":{"role":"owner","read":"all","spawn":true},"node":{"archive":true}}
P
A=127.0.0.1:7501 B=127.0.0.1:7502
pi_flags=()
[ -n "${PI:-}" ] && pi_flags=(-pi "$PI" ${PI_ARGS:+-pi-args "$PI_ARGS"} ${PI_HOME:+-pi-env HOME=$PI_HOME -pi-env PI_OFFLINE=1})
run() { # name addr peer
  "$T/fleetd" -name "$1" -data "$T/$1" -listen "$2" -dev-policy "$T/policy.json" -peer-as node \
    -peer "http://$3" -fake-slow 30s "${pi_flags[@]}" >>"$T/$1.log" 2>&1 &
  echo $! > "$T/$1.pid"
  for _ in $(seq 50); do curl -sf "http://$2/v1/node?as=tan" >/dev/null && return; sleep 0.1; done
  cat "$T/$1.log"; exit 1
}
api() {
  local out code
  out=$(curl -s -w '\n%{http_code}' -X "$1" "http://$2$3?as=tan" ${4:+-H 'Content-Type: application/json' -d "$4"}) || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  [ "${code:0:1}" = 2 ] || { echo "$1 $3 -> $code $out" >&2; return 1; }
  printf '%s' "$out"
}
field() { python3 -c "import json,sys;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1"; }
wait_for() { # addr sid python-expr-on-meta
  for _ in $(seq 100); do
    m=$(api GET "$1" "/v1/sessions/$2") && python3 -c "import json,sys;m=json.loads(sys.argv[1]);sys.exit(0 if ($3) else 1)" "$m" && return
    sleep 0.1
  done
  echo "timeout: $3 :: $m"; exit 1
}
ok() { echo "ok - $*"; }

run laptop $A $B; run server $B $A

sid=$(api POST $A /v1/sessions '{"harness":"fake","title":"smoke","key":"k1","prompt":"hi TOOL"}' | field "['session']['sid']")
wait_for $A "$sid" "m['last']=='turn 1: hi TOOL' and m['state']=='running'"
ok "spawn + tool call on laptop"

api POST $B "/v1/sessions/$sid/resume" >/dev/null
api POST $B "/v1/sessions/$sid/inputs" '{"key":"i1","text":"SLOW"}' >/dev/null
wait_for $B "$sid" "m['node']=='server' and m['state']=='busy'"
ok "handoff laptop -> server"

kill -9 "$(cat "$T/server.pid")"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$A/v1/sessions/$sid/inputs?as=tan" -H 'Content-Type: application/json' -d '{"key":"i2","text":"x"}')
[ "$code" = 503 ] || { echo "relay to dead writer returned $code"; exit 1; }
ok "kill -9 writer: relays fail loudly ($code)"

fork=$(api POST $A "/v1/sessions/$sid/fork" '{"key":"f1"}' | field "['session']['sid']")
api POST $A "/v1/sessions/$fork/inputs" '{"key":"i3","text":"forked"}' >/dev/null
wait_for $A "$fork" "m['last']=='turn 2: forked'"
ok "fork from last pulled checkpoint while writer is down"

run server $B $A
wait_for $B "$sid" "m['state']=='interrupted' and m['unknown']==['input i1']"
ok "restart: in-flight input recorded as outcome-unknown, not retried"
api POST $B "/v1/sessions/$sid/inputs" '{"key":"i4","text":"back"}' >/dev/null
wait_for $B "$sid" "m['last']=='turn 2: back' and m['run']==3"
ok "new run resumes native history"

for _ in $(seq 50); do
  [ "$(api GET $A "/v1/sessions/$sid/events")" = "$(api GET $B "/v1/sessions/$sid/events")" ] && break; sleep 0.2
done
[ "$(api GET $A "/v1/sessions/$sid/events")" = "$(api GET $B "/v1/sessions/$sid/events")" ]
ok "laptop replica matches server byte for byte"

if [ -n "${PI:-}" ]; then
  p=$(api POST $A /v1/sessions '{"harness":"pi","title":"pi","key":"p1","prompt":"Please run TOOL now"}' | field "['session']['sid']")
  wait_for $A "$p" "m['state']=='running' and m['checkpoint']"
  ev=$(api GET $A "/v1/sessions/$p/events")
  grep -q '"kind":"tool.result"' <<<"$ev" && grep -q 'MOCK_TOOL_OK' <<<"$ev"
  ok "pi rpc: tool call recorded"
  api POST $B "/v1/sessions/$p/resume" >/dev/null
  api POST $B "/v1/sessions/$p/inputs" '{"key":"p2","text":"RECALL"}' >/dev/null
  wait_for $B "$p" "m['last']=='RECALL:yes'"
  ok "pi session resumed on server with its history"
fi
echo PASS

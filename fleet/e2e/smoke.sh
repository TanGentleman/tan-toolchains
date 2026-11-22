#!/usr/bin/env bash
# Two real fleetd processes on loopback with the built-in fake harness run
# as one subprocess per turn: spawn on a, resume on b, kill -9 b in the
# middle of a turn, restart it, and continue from the last checkpoint.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
pids=()
cleanup() { kill ${pids[@]+"${pids[@]}"} 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
go build -o "$tmp/fleetd" ./cmd/fleetd

A=http://127.0.0.1:17431 B=http://127.0.0.1:17432
start() { # name port
  "$tmp/fleetd" -name "$1" -url "http://127.0.0.1:$2" -data "$tmp/$1" -listen "127.0.0.1:$2" -owner tan 2>>"$tmp/$1.log" &
  pids+=($!)
  for _ in $(seq 50); do curl -fs -H 'Tailscale-User-Login: tan' "http://127.0.0.1:$2/v1/node" >/dev/null && return; sleep 0.1; done
  cat "$tmp/$1.log"; exit 1
}
api() { # method url [body]
  curl -fsS -X "$1" -H 'Tailscale-User-Login: tan' -H 'Content-Type: application/json' ${3:+-d "$3"} "$2"
}
wait_for() { # url pattern
  for _ in $(seq 100); do api GET "$1" | grep -q "$2" && return; sleep 0.05; done
  echo "timed out waiting for $2 in $1"; api GET "$1"; exit 1
}
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }

start a 17431
start b 17432

sid=$(api POST $A/v1/sessions '{"harness":"fake","title":"smoke","key":"k1","prompt":"hello"}' | field sid)
wait_for "$A/v1/sessions/$sid/events" 'turn\\":1'
wait_for "$A/v1/sessions/$sid" '"running":false'
again=$(api POST $A/v1/sessions '{"harness":"fake","title":"smoke","key":"k1","prompt":"hello"}' | field sid)
[ "$again" = "$sid" ] || { echo "retried spawn made a new session"; exit 1; }
code=$(curl -s -o /dev/null -w '%{http_code}' "$A/v1/sessions/$sid")
[ "$code" = 401 ] || { echo "no identity got $code"; exit 1; }

api POST "$B/v1/sessions/$sid/resume" "{\"from\":\"$A\"}" >/dev/null
api POST "$B/v1/sessions/$sid/inputs" '{"key":"i1","text":"two"}' >/dev/null
wait_for "$B/v1/sessions/$sid/events" 'turn\\":2'
wait_for "$B/v1/sessions/$sid" '"running":false'
wait_for "$A/v1/sessions/$sid" '"writer":"b"'
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Tailscale-User-Login: tan' -d '{"key":"x","text":"no"}' "$A/v1/sessions/$sid/inputs")
[ "$code" = 409 ] || { echo "old writer accepted input: $code"; exit 1; }

api POST "$B/v1/sessions/$sid/inputs" '{"key":"i2","text":"sleep"}' >/dev/null
wait_for "$B/v1/sessions/$sid/events" 'sleeping'
kill -9 "${pids[1]}"
wait "${pids[1]}" 2>/dev/null || true
start b 17432
wait_for "$B/v1/sessions/$sid/events" 'node restarted'
api POST "$B/v1/sessions/$sid/inputs" '{"key":"i3","text":"three"}' >/dev/null
wait_for "$B/v1/sessions/$sid/events" 'turn\\":3'
echo "smoke: ok ($sid)"

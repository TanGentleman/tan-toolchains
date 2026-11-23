#!/usr/bin/env bash
# One real fleetd on loopback with the fake harness run as one subprocess per
# turn: spawn, retry, refuse a caller without identity, kill -9 fleetd in the
# middle of a turn, restart it, and continue from the last checkpoint.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
pid=""
cleanup() { [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
go build -o "$tmp/fleetd" ./cmd/fleetd

U=http://127.0.0.1:17431
start() {
  "$tmp/fleetd" -name a -url $U -data "$tmp/a" -listen 127.0.0.1:17431 -owner tan -harness "fake=$tmp/fleetd fake" 2>>"$tmp/a.log" &
  pid=$!
  for _ in $(seq 50); do curl -fs -H 'Tailscale-User-Login: tan' "$U/v1/node" >/dev/null && return; sleep 0.1; done
  cat "$tmp/a.log"; exit 1
}
api() { # method path [body]
  curl -fsS -X "$1" -H 'Tailscale-User-Login: tan' -H 'Content-Type: application/json' ${3:+-d "$3"} "$U$2"
}
wait_for() { # path pattern
  for _ in $(seq 100); do api GET "$1" | grep -q "$2" && return; sleep 0.05; done
  echo "timed out waiting for $2 in $1"; api GET "$1"; exit 1
}
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }

start
sid=$(api POST /v1/sessions '{"harness":"fake","title":"smoke","key":"k1","prompt":"hello"}' | field sid)
wait_for "/v1/sessions/$sid/events" 'turn\\":1'
wait_for "/v1/sessions/$sid" '"running":false'
again=$(api POST /v1/sessions '{"harness":"fake","title":"smoke","key":"k1","prompt":"hello"}' | field sid)
[ "$again" = "$sid" ] || { echo "retried spawn made a new session"; exit 1; }
code=$(curl -s -o /dev/null -w '%{http_code}' "$U/v1/sessions/$sid")
[ "$code" = 401 ] || { echo "no identity got $code"; exit 1; }

api POST "/v1/sessions/$sid/inputs" '{"key":"i1","text":"two"}' >/dev/null
wait_for "/v1/sessions/$sid/events" 'turn\\":2'
wait_for "/v1/sessions/$sid" '"running":false'

api POST "/v1/sessions/$sid/inputs" '{"key":"i2","text":"sleep"}' >/dev/null
wait_for "/v1/sessions/$sid/events" 'sleeping'
sleep 0.5
api GET "/v1/sessions/$sid" | grep -q '"running":true' || { echo "sleep turn did not keep running"; api GET "/v1/sessions/$sid/events"; exit 1; }
kill -9 "$pid"
wait "$pid" 2>/dev/null || true
start
wait_for "/v1/sessions/$sid/events" 'node restarted'
api POST "/v1/sessions/$sid/inputs" '{"key":"i3","text":"three"}' >/dev/null
wait_for "/v1/sessions/$sid/events" 'turn\\":3'
echo "smoke: ok ($sid)"

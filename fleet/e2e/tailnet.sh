#!/usr/bin/env bash
# fleetd on a private tailnet (Headscale in Docker; no Tailscale account).
# Checks WhoIs identity, policy capability ceilings, per-session shares, and a
# laptop -> server handoff where the nodes reach each other only over tsnet.
# Every tailnet node runs in its own container, as on separate machines.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); HS=fleet-hs; CTRL=http://172.17.0.1:8080; IMG=alpine:3.20
cleanup() { docker rm -f $HS fleet-laptop fleet-server >/dev/null 2>&1 || true; sudo rm -rf "$T"; }
trap cleanup EXIT
CGO_ENABLED=0 go build -o "$T/fleetd" ./cmd/fleetd
CGO_ENABLED=0 go build -o "$T/tsclient" ./e2e/tsclient
cp e2e/hs/policy.hujson "$T/"
docker run -d --name $HS -p 8080:8080 -p 3478:3478/udp -v "$PWD/e2e/hs/config.yaml:/etc/headscale/config.yaml:ro" \
  -v "$T/policy.hujson:/etc/headscale/policy.hujson:ro" headscale/headscale:v0.29.7 serve >/dev/null
for _ in $(seq 50); do curl -sf $CTRL/health >/dev/null && break; sleep 0.2; done
hs() { docker exec $HS headscale "$@"; }
uid() { hs users list -o json | python3 -c "import json,sys;print([u['id'] for u in json.load(sys.stdin) if u['name']==sys.argv[1]][0])" "$1"; }
key() { hs preauthkeys create --user "$(uid "$1")" ${2:+--tags "$2"} --reusable -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['key'])"; }
tsip() { hs nodes list -o json | python3 -c "import json,sys;print([n['ip_addresses'][0] for n in json.load(sys.stdin) if n['given_name']==sys.argv[1]][0])" "$1"; }
for u in tan bob carol; do hs users create $u >/dev/null; done

node() { # name [fleetd flags]
  local n=$1; shift
  docker run -d --name "fleet-$n" -v "$T:/w" -e TS_AUTHKEY="$(key tan tag:fleet)" $IMG /w/fleetd -name "$n" \
    -data "/w/$n" -tsnet "$n" -listen :7433 -control-url $CTRL "$@" >/dev/null
  for _ in $(seq 150); do docker logs "fleet-$n" 2>&1 | grep -q "fleetd $n on" && break; sleep 0.2; done
  docker logs "fleet-$n" 2>&1 | grep -q "fleetd $n on" || { echo "fleetd $n did not join"; docker logs "fleet-$n" 2>&1 | tail; exit 1; }
}
node laptop
LAPTOP=http://$(tsip laptop):7433
as() { local who=$1; shift; docker run --rm -v "$T:/w" -e TS_AUTHKEY="$(key "$who")" $IMG /w/tsclient \
  -hostname "phone-$who" -dir "/w/c-$who" -control $CTRL -target "${TARGET:-$LAPTOP}" "$@"; }
logs() { for c in fleet-laptop fleet-server; do docker logs $c 2>&1 | tail -10; done; }
expect() { [ "$1" = "$2" ] || { echo "FAIL $3: got $1, want $2"; logs; exit 1; }; echo "ok - $3"; }
field() { sed 's/^200 //' | python3 -c "import json,sys;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }

bob=$(as bob "GET /v1/node" | field "d['you']['login']")
out=$(as tan "GET /v1/node" 'POST /v1/sessions {"harness":"fake","title":"t","key":"k1","prompt":"hi TOOL"}')
expect "$(sed -n 1p <<<"$out" | field "d['you']['display']+' '+d['you']['cap']['role']")" "tan owner" \
  "tan's phone is identified by WhoIs with the owner grant"
sid=$(sed -n 2p <<<"$out" | field "d['session']['sid']")

expect "$(as bob "GET /v1/sessions/$sid" | cut -d' ' -f1)" 403 "friend cannot read an unshared session"
expect "$(as bob 'POST /v1/sessions {"harness":"pi","key":"b1"}' | cut -d' ' -f1)" 403 "friend cannot spawn a runner outside the grant"
expect "$(as carol 'POST /v1/sessions {"harness":"fake","key":"c1"}' | cut -d' ' -f1)" 403 "viewer cannot spawn"
expect "$(as tan "POST /v1/sessions/$sid/share {\"user\":\"$bob\",\"level\":\"steer\"}" | cut -d' ' -f1)" 200 "owner shares with bob"
expect "$(as bob "GET /v1/sessions/$sid" "POST /v1/sessions/$sid/inputs {\"key\":\"b2\",\"text\":\"from bob\"}" | cut -d' ' -f1 | tr '\n' ' ')" \
  "200 200 " "friend reads and steers the shared session"
for _ in $(seq 50); do
  last=$(as tan "GET /v1/sessions/$sid" | field "d['last']")
  [ "$last" = "turn 2: from bob" ] && break; sleep 0.2
done
expect "$last" "turn 2: from bob" "bob's input ran"
lan=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' fleet-laptop)
expect "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$lan:7433/v1/node" || true)" 000 \
  "fleetd is not reachable on the LAN, only the tailnet"

node server -peer "$LAPTOP"
SERVER=http://$(tsip server):7433
out=$(TARGET=$SERVER as tan "POST /v1/sessions/$sid/resume" "POST /v1/sessions/$sid/inputs {\"key\":\"t3\",\"text\":\"on server\"}")
expect "$(cut -d' ' -f1 <<<"$out" | tr '\n' ' ')" "200 200 " "server takes over the session from the laptop over tsnet"
for _ in $(seq 50); do
  m=$(TARGET=$SERVER as tan "GET /v1/sessions/$sid" | field "d['node']+' '+d['last']")
  [ "$m" = "server turn 3: on server" ] && break; sleep 0.2
done
expect "$m" "server turn 3: on server" "the session continues on the server with its history"
expect "$(as tan "GET /v1/sessions/$sid" | field "d['state']+' '+d['sealed_to']")" "sealed server" \
  "the laptop sealed its run to the server"
echo PASS

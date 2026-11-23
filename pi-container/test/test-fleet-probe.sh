#!/usr/bin/env bash
# fleet-probe.sh against local listeners: the proxy check, connected,
# refused and blocked, and which of them count as failures. Needs python3
# for the listeners; skips without it.
set -uo pipefail
here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "test-fleet-probe.sh: python3 not found; skipped"; exit 0; }
bash -n "$here/fleet-probe.sh" && bash -n "$here/fleet-isolation.sh" && pass || fail "probe scripts parse"

tmp=$(mktemp -d)
pids=""
trap 'for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$tmp"' EXIT
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
listen() { # port
  python3 -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16)
while True: s.accept()' "$1" &
  pids="$pids $!"
  for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return; sleep 0.1; done
}
proxy=$(free_port) open=$(free_port) closed=$(free_port)
listen "$proxy"
listen "$open"
# Neither connects nor refuses anywhere: a name under .invalid never
# resolves. (TEST-NET addresses are refused by some sandboxes.)
blackhole=blocked.invalid

# probe EXPECTED-EXIT LABEL ARGS...: sets $out; runs in this shell so the
# exit assertion counts.
probe() {
  local want=$1 label=$2
  shift 2
  PROBE_TIMEOUT=1 PROBE_INTERNET=$blackhole PROBE_RESOLVER=$blackhole HTTPS_PROXY="http://127.0.0.1:$proxy" \
    bash "$here/fleet-probe.sh" "$@" > "$tmp/out" 2>&1
  eq "$want" "$?" "$label: exit"
  out=$(cat "$tmp/out")
}

# All blocked: the gateway answers "refused" on fleetd's port (the Mac's own
# kernel), which is fine; everything else times out.
probe 0 "isolated" "$blackhole" "$blackhole" 127.0.0.1 "$closed"
contains "ok    proxy" "$out" "proxy connects first"
contains "fleetd via the gateway" "$out" "fleetd checked"
contains "127.0.0.1:$closed refused" "$out" "refused reported"
contains "isolation: ok" "$out" "summary"

# fleetd reachable through the gateway fails.
probe 1 "fleetd open" "$blackhole" "$blackhole" 127.0.0.1 "$open"
contains "FAIL  fleetd via the gateway" "$out" "an open fleetd port fails"
contains "isolation: FAIL" "$out" "summary says FAIL"

# A peer that refuses was still reached: fails, though nothing listens.
probe 1 "peer reached" "$blackhole" 127.0.0.1 "$blackhole" "$closed"
contains "FAIL  tailnet peer, https" "$out" "refused from a peer counts as reached"

# The Mac's tailnet IP refusing is the Mac's kernel: not a failure.
probe 0 "mac refuses" 127.0.0.1 "$blackhole" "$blackhole" "$closed"
contains "ok    Mac tailnet, serve" "$out" "refused on the Mac's tailnet IP is fine"

# Mac services: reported, not failed.
probe 0 "mac service" "$blackhole" "$blackhole" 127.0.0.1 "$closed" "$open" "$closed"
contains "REACHABLE  Mac service 127.0.0.1:$open" "$out" "reachable Mac service listed"
not_contains "REACHABLE  Mac service 127.0.0.1:$closed" "$out" "closed port not listed"

# No peer online: skipped, not failed.
probe 0 "no peer" "$blackhole" "" "$blackhole" "$closed"
contains "skip  tailnet peer" "$out" "missing peer skipped"

# The proxy unreachable: the probe proves nothing and says so.
out=$(PROBE_TIMEOUT=1 HTTPS_PROXY="http://127.0.0.1:$closed" bash "$here/fleet-probe.sh" x x x 1 2>&1)
eq 3 "$?" "no proxy: exit"
contains "BROKEN" "$out" "no proxy is BROKEN, not ok"
out=$(env -u HTTPS_PROXY bash "$here/fleet-probe.sh" x x x 1 2>&1)
eq 3 "$?" "HTTPS_PROXY unset: exit"

# fleet-isolation.sh end to end on fakes: tailscale, lsof and a container CLI
# that runs the VM's command here. Proves the wiring: the session's state
# folder, the gateway from `container network inspect`, ports from lsof, and
# the probe's verdict and exit code coming back through run.sh.
iso() { # expected-exit, label
  local h=$tmp/iso w=$tmp/iso/world bin=$tmp/iso/bin
  rm -rf "$h"
  mkdir -p "$h/home/.fleet/sessions/s1/state" "$h/home/.config/pi-container/certs" "$h/home/.config/pi-container/private" \
    "$w/images" "$w/networks" "$w/containers" "$h/disk" "$bin"
  : > "$h/home/.config/pi-container/certs/ca.pem"
  printf 'OPENROUTER_API_KEY=sk-or-v1-real\nGITHUB_TOKEN=t\n' > "$h/home/.config/pi-container/env"
  chmod 600 "$h/home/.config/pi-container/env"
  img='[{"id":"sha256:t","configuration":{"descriptor":{"digest":"sha256:t"},"name":"pi-agent:local"},"variants":[{"config":{"config":{"Env":["PI_CONTAINER_PI_VERSION=1.6.0","PI_CONTAINER_CAPABILITIES=pi"]},"history":[]}}]}]'
  printf '%s' "$img" > "$w/images/pi-agent_local.json"
  printf '%s' "$img" > "$w/images/pi-proxy_local.json"
  printf '[{"configuration":{"name":"pi-locked","mode":"hostOnly","ipv4Subnet":"172.30.240.0/24"},"id":"pi-locked","status":{"ipv4Gateway":"127.0.0.1","ipv4Subnet":"172.30.240.0/24"}}]' > "$w/networks/pi-locked.json"
  printf 'pi-locked\n' > "$w/networks.list"
  printf '[{"id":"pi-proxy","configuration":{"name":"pi-proxy"},"status":{"state":"running"}}]' > "$w/containers/pi-proxy.json"
  printf '127.0.0.1\n' > "$h/home/.config/pi-container/private/proxy.addr"
  printf '#!/bin/sh\ncase "$*" in "ip -4") echo %s ;; "status --json") echo '"'"'{"Peer":{"a":{"Online":true,"TailscaleIPs":["%s"]}}}'"'"' ;; *) exit 1 ;; esac\n' \
    "$blackhole" "$blackhole" > "$bin/tailscale"
  printf '#!/bin/sh\necho "COMMAND PID USER FD TYPE DEVICE SIZE NODE NAME"\necho "web 1 u 3u IPv4 0 0t0 TCP *:%s (LISTEN)"\necho "fleetd 2 u 3u IPv4 0 0t0 TCP 127.0.0.1:7433 (LISTEN)"\n' "$open" > "$bin/lsof"
  printf '#!/usr/bin/env bash\nexport FAKE_CONTAINER_WORLD=%q FAKE_CONTAINER_EXEC=%q\nexec %q "$@"\n' "$w" "$h/disk" "$here/fake-container.sh" > "$bin/container"
  chmod +x "$bin"/*
  env -u PI_CONFIG_DIR -u PI_ENV_FILE -u PI_INSTANCE -u PI_CLONE -u PI_IMAGE HOME="$h/home" PATH="$bin:$PATH" \
    PI_PROXY_PORT="$proxy" FLEET_PORT="$fleetd_port" PROBE_TIMEOUT=1 PROBE_INTERNET=$blackhole PROBE_RESOLVER=$blackhole \
    bash "$here/fleet-isolation.sh" s1 > "$tmp/out" 2>&1
  eq "$1" "$?" "$2: exit"
  out=$(cat "$tmp/out")
}
fleetd_port=$closed
iso 0 "isolation helper"
contains "gateway 127.0.0.1 (this Mac)" "$out" "gateway read from the network"
contains "ok    fleetd via the gateway" "$out" "probe ran in the turn VM"
contains "REACHABLE  Mac service 127.0.0.1:$open" "$out" "lsof ports probed"
contains "isolation: ok" "$out" "verdict"
contains "web *:$open" "$out" "listening processes listed"
not_contains "127.0.0.1:7433" "$(printf '%s' "$out" | sed -n '/Your processes/,$p')" "loopback listeners not listed"
fleetd_port=$open
iso 1 "isolation helper, fleetd reachable"
contains "isolation: FAIL" "$out" "failure comes back through run.sh"

finish

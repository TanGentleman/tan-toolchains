#!/usr/bin/env bash
# fleet-probe.sh against local listeners: the proxy check, connected,
# refused and blocked, and which of them count as failures. Needs python3
# for the listeners; skips without it.
set -uo pipefail
here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "test-fleet-probe.sh: python3 not found; skipped"; exit 0; }
bash -n "$here/fleet-probe.sh" && bash -n "$here/fleet-isolation.sh" && pass || fail "probe scripts parse"

tmp=$(cd "$(mktemp -d)" && pwd -P) # macOS: /var is a symlink, and the fleet-state guard refuses symlinks
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

# A DNS server on UDP and TCP that answers NXDOMAIN to every query.
dnsport=$(free_port)
python3 -c 'import socket,sys,threading
port=int(sys.argv[1])
def reply(d): return d[:2]+b"\x81\x83"+d[4:6]+b"\x00"*6+d[12:]
def udp():
    s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", port))
    while True:
        d,a=s.recvfrom(512); s.sendto(reply(d), a)
threading.Thread(target=udp, daemon=True).start()
t=socket.socket(); t.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); t.bind(("127.0.0.1", port)); t.listen(4)
while True:
    c,_=t.accept(); n=int.from_bytes(c.recv(2), "big"); d=c.recv(n); r=reply(d); c.sendall(len(r).to_bytes(2, "big")+r); c.close()' "$dnsport" &
pids="$pids $!"
for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>"/dev/tcp/127.0.0.1/$dnsport") 2>/dev/null && break; sleep 0.1; done

# probe EXPECTED-EXIT LABEL ARGS...: sets $out; runs in this shell so the
# exit assertion counts. RESOLVER and DNS_PORT override the resolver.
probe() {
  local want=$1 label=$2
  shift 2
  PROBE_TIMEOUT=1 PROBE_INTERNET=$blackhole PROBE_RESOLVER=${RESOLVER:-$blackhole} PROBE_DNS_PORT=${DNS_PORT:-53} \
    HTTPS_PROXY="http://127.0.0.1:$proxy" bash "$here/fleet-probe.sh" "$@" > "$tmp/out" 2>&1
  eq "$want" "$?" "$label: exit"
  out=$(cat "$tmp/out")
}

# Everything blocked, as the egress lock makes it.
probe 0 "isolated" "$blackhole" "$blackhole" "$blackhole" "$closed" 22
contains "ok    proxy" "$out" "proxy connects first"
contains "ok    fleetd via the gateway" "$out" "fleetd checked"
contains "ok    Tailscale DNS" "$out" "Tailscale DNS queried"
contains "ok    gateway DNS" "$out" "gateway DNS queried"
contains "ok    Mac service" "$out" "Mac ports probed"
contains "isolation: ok" "$out" "summary"

# The gateway refusing is the Mac answering: with the lock, a FAIL.
probe 1 "gateway refuses" "$blackhole" "$blackhole" 127.0.0.1 "$closed"
contains "FAIL  fleetd via the gateway     127.0.0.1:$closed refused" "$out" "refused on the gateway fails"
contains "isolation: FAIL" "$out" "summary says FAIL"

# fleetd reachable through the gateway fails.
probe 1 "fleetd open" "$blackhole" "$blackhole" 127.0.0.1 "$open"
contains "FAIL  fleetd via the gateway     127.0.0.1:$open connected" "$out" "an open fleetd port fails"

# A peer that refuses was still reached.
probe 1 "peer reached" "$blackhole" 127.0.0.1 "$blackhole" "$closed"
contains "FAIL  tailnet peer, https" "$out" "refused from a peer counts as reached"

# The Mac's tailnet IP refusing: reached, so a FAIL.
probe 1 "mac refuses" 127.0.0.1 "$blackhole" "$blackhole" "$closed"
contains "FAIL  Mac tailnet, serve" "$out" "refused on the Mac's tailnet IP fails"

# A Mac service port that connects or refuses fails; a blocked one is ok.
probe 1 "mac service" "$blackhole" "$blackhole" 127.0.0.1 "$closed" "$open"
contains "FAIL  Mac service                127.0.0.1:$open connected" "$out" "reachable Mac service fails"

# A resolver that answers fails over UDP and TCP, NXDOMAIN included.
RESOLVER=127.0.0.1 DNS_PORT=$dnsport probe 1 "resolver answers" "$blackhole" "$blackhole" "$blackhole" "$closed"
contains "FAIL  Tailscale DNS              127.0.0.1:$dnsport/udp answered" "$out" "UDP DNS answer fails"
contains "FAIL  Tailscale DNS              127.0.0.1:$dnsport/tcp answered" "$out" "TCP DNS answer fails"
contains "ok    gateway DNS" "$out" "a silent gateway is ok"
# A closed DNS port gets no answer.
RESOLVER=127.0.0.1 DNS_PORT=$closed probe 1 "resolver closed" "$blackhole" "$blackhole" "$blackhole" "$closed"
contains "ok    Tailscale DNS              127.0.0.1:$closed/udp no answer" "$out" "closed resolver port: no UDP answer"

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
iso() { # expected-exit, label, gateway
  local h=$tmp/iso w=$tmp/iso/world bin=$tmp/iso/bin
  rm -rf "$h"
  mkdir -p "$h/home/.fleet/sessions/s1/state" "$h/home/.config/pi-container/certs" "$h/home/.config/pi-container/private" \
    "$w/images" "$w/networks" "$w/containers" "$h/disk" "$bin"
  : > "$h/home/.config/pi-container/certs/ca.pem"
  printf 'OPENROUTER_API_KEY=sk-or-v1-real\nGITHUB_TOKEN=t\n' > "$h/home/.config/pi-container/env"
  chmod 600 "$h/home/.config/pi-container/env"
  img='[{"id":"sha256:t","configuration":{"descriptor":{"digest":"sha256:t"},"name":"pi-agent:local"},"variants":[{"config":{"config":{"Env":["PI_CONTAINER_PI_VERSION=1.6.0","PI_CONTAINER_CAPABILITIES=pi,netlock"]},"history":[]}}]}]'
  printf '%s' "$img" > "$w/images/pi-full_local.json"
  printf '%s' "$img" > "$w/images/pi-proxy_local.json"
  printf '[{"configuration":{"name":"pi-locked","mode":"hostOnly","ipv4Subnet":"172.30.240.0/24"},"id":"pi-locked","status":{"ipv4Gateway":"%s","ipv4Subnet":"172.30.240.0/24"}}]' "$3" > "$w/networks/pi-locked.json"
  printf 'pi-locked\n' > "$w/networks.list"
  printf '[{"id":"pi-proxy","configuration":{"name":"pi-proxy"},"status":{"state":"running"}}]' > "$w/containers/pi-proxy.json"
  printf '127.0.0.1\n' > "$h/home/.config/pi-container/private/proxy.addr"
  printf '#!/bin/sh\ncase "$*" in "ip -4") echo %s ;; "status --json") echo '"'"'{"Peer":{"a":{"Online":true,"TailscaleIPs":["%s"]}}}'"'"' ;; *) exit 1 ;; esac\n' \
    "$blackhole" "$blackhole" > "$bin/tailscale"
  printf '#!/bin/sh\necho "COMMAND PID USER FD TYPE DEVICE SIZE NODE NAME"\necho "web 1 u 3u IPv4 0 0t0 TCP *:%s (LISTEN)"\necho "fleetd 2 u 3u IPv4 0 0t0 TCP 127.0.0.1:7433 (LISTEN)"\n' "$open" > "$bin/lsof"
  printf '#!/usr/bin/env bash\nexport FAKE_CONTAINER_WORLD=%q FAKE_CONTAINER_EXEC=%q\nexec %q "$@"\n' "$w" "$h/disk" "$here/fake-container.sh" > "$bin/container"
  chmod +x "$bin"/*
  env -u PI_CONFIG_DIR -u PI_ENV_FILE -u PI_INSTANCE -u PI_CLONE HOME="$h/home" PATH="$bin:$PATH" \
    PI_PROXY_PORT="$proxy" FLEET_PORT="$fleetd_port" PROBE_TIMEOUT=1 PROBE_INTERNET=$blackhole PROBE_RESOLVER=$blackhole \
    bash "$here/fleet-isolation.sh" s1 > "$tmp/out" 2>&1
  eq "$1" "$?" "$2: exit"
  out=$(cat "$tmp/out")
}
fleetd_port=$closed
iso 0 "isolation helper" "$blackhole"
contains "gateway $blackhole (this Mac)" "$out" "gateway read from the network"
contains "ok    fleetd via the gateway" "$out" "probe ran in the turn VM"
contains "ok    Mac service                $blackhole:$open blocked" "$out" "lsof ports probed"
contains "isolation: ok" "$out" "verdict"
contains "web *:$open" "$out" "listening processes listed"
not_contains "127.0.0.1:7433" "$(printf '%s' "$out" | sed -n '/Your processes/,$p')" "loopback listeners not listed"
iso 1 "isolation helper, Mac reachable" 127.0.0.1
contains "FAIL  Mac service                127.0.0.1:$open connected" "$out" "a reachable Mac service fails"
contains "isolation: FAIL" "$out" "failure comes back through run.sh"

finish

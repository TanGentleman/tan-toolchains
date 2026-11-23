#!/usr/bin/env bash
# What can this machine reach? Runs inside a fleet turn's VM, started by
# test/fleet-isolation.sh; test/test-fleet-probe.sh runs it locally.
#
#   fleet-probe.sh MAC_TAILNET_IP PEER_IP GATEWAY_IP FLEETD_PORT [MAC_PORT...]
#
# Every probe is a TCP connect by IP, so DNS and TLS can't make one pass by
# accident. The proxy in $HTTPS_PROXY must connect, or the probe itself is
# broken. For the Mac (the gateway and its tailnet IP) only a completed
# connection counts: "refused" means the Mac's own kernel answered, which a
# turn can reach anyway. For a tailnet peer, Tailscale's resolver and the
# internet, "refused" counts too: the packet got there.
#
# Exit 0: nothing it must not reach. 1: something it must not reach. 3: the
# probe could not reach the proxy, so it proves nothing.
#
#   PROBE_TIMEOUT   seconds per probe (default 4)
#   PROBE_INTERNET  internet address to try (default 1.1.1.1)
#   PROBE_RESOLVER  Tailscale's resolver (default 100.100.100.100)
set -u

mac=${1:-} peer=${2:-} gw=${3:-} fleetd_port=${4:-7433}
shift 4 2>/dev/null || shift $#
limit=${PROBE_TIMEOUT:-4}
bad=0

# reach HOST PORT: prints connected, refused or blocked (timeout, no route).
reach() {
  local err p i=0
  err=$(mktemp)
  (exec 3<>"/dev/tcp/$1/$2") 2>"$err" &
  p=$!
  while kill -0 "$p" 2>/dev/null && [ "$i" -lt $((limit * 10)) ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$p" 2>/dev/null; then
    kill "$p" 2>/dev/null
    wait "$p" 2>/dev/null
    echo blocked
  elif wait "$p"; then
    echo connected
  elif grep -qi refused "$err"; then
    echo refused
  else
    echo blocked
  fi
  rm -f "$err"
}

# check LABEL HOST PORT STRICT: STRICT=1 also fails on refused.
check() {
  local r
  if [ -z "$2" ]; then
    printf 'skip  %-26s no address\n' "$1"
    return
  fi
  r=$(reach "$2" "$3")
  if [ "$r" = connected ] || { [ "$4" = 1 ] && [ "$r" = refused ]; }; then
    printf 'FAIL  %-26s %s:%s %s\n' "$1" "$2" "$3" "$r"
    bad=1
  else
    printf 'ok    %-26s %s:%s %s\n' "$1" "$2" "$3" "$r"
  fi
}

proxy=${HTTPS_PROXY:-}
proxy=${proxy#http://}
proxy=${proxy%/}
if [ -z "$proxy" ] || [ "$(reach "${proxy%:*}" "${proxy##*:}")" != connected ]; then
  echo "BROKEN: cannot connect to the proxy (${proxy:-HTTPS_PROXY unset}); these probes prove nothing"
  exit 3
fi
printf 'ok    %-26s %s connected (the probe works)\n' "proxy" "$proxy"

check "fleetd via the gateway" "$gw" "$fleetd_port" 0
check "Mac tailnet, serve" "$mac" 443 0
check "Mac tailnet, fleetd" "$mac" "$fleetd_port" 0
check "Tailscale resolver" "${PROBE_RESOLVER:-100.100.100.100}" 53 1
check "tailnet peer, https" "$peer" 443 1
check "tailnet peer, ssh" "$peer" 22 1
check "internet, direct" "${PROBE_INTERNET:-1.1.1.1}" 443 1

# Mac services a turn can reach on the gateway. Not failures by themselves:
# decide whether each should be reachable from an agent.
for port in "$@"; do
  [ "$(reach "$gw" "$port")" = connected ] && printf 'REACHABLE  Mac service %s:%s\n' "$gw" "$port"
done

[ "$bad" = 0 ] && echo "isolation: ok" || echo "isolation: FAIL"
exit "$bad"

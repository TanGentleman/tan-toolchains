#!/usr/bin/env bash
# What can this machine reach? Runs inside a fleet turn's VM, started by
# test/fleet-isolation.sh; test/test-fleet-probe.sh runs it locally.
#
#   fleet-probe.sh MAC_TAILNET_IP PEER_IP GATEWAY_IP FLEETD_PORT [MAC_PORT...]
#
# Every probe is by IP, so DNS and TLS can't make one pass by accident. The
# proxy in $HTTPS_PROXY must connect, or the probe itself is broken. The
# VM's egress lock (lib/netlock.sh) lets it send only to the proxy, so every
# other probe must be "blocked": "connected" or "refused" both mean a packet
# got there, and either is a FAIL. That includes the gateway (this Mac) and
# each MAC_PORT. Tailscale's resolver and the gateway also get a real DNS
# query over UDP and TCP; any reply is a FAIL.
#
# Exit 0: nothing it must not reach. 1: something it must not reach. 3: the
# probe could not reach the proxy, so it proves nothing.
#
#   PROBE_TIMEOUT   seconds per probe (default 4)
#   PROBE_INTERNET  internet address to try (default 1.1.1.1)
#   PROBE_RESOLVER  Tailscale's resolver (default 100.100.100.100)
#   PROBE_DNS_PORT  DNS port to query (default 53)
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

# dns HOST PROTO: prints answered or silent. One A query for openrouter.ai.
dns() {
  local out p i=0
  out=$(mktemp)
  (
    q='\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x0aopenrouter\x02ai\x00\x00\x01\x00\x01'
    if [ "$2" = tcp ]; then
      exec 3<>"/dev/tcp/$1/${PROBE_DNS_PORT:-53}" || exit 1
      printf "\x00\x1f$q" >&3
    else
      exec 3<>"/dev/udp/$1/${PROBE_DNS_PORT:-53}" || exit 1
      printf "$q" >&3
    fi
    head -c 4 <&3 >"$out"
  ) 2>/dev/null &
  p=$!
  while kill -0 "$p" 2>/dev/null && [ "$i" -lt $((limit * 10)) ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill "$p" 2>/dev/null
  wait "$p" 2>/dev/null
  if [ -s "$out" ]; then echo answered; else echo silent; fi
  rm -f "$out"
}

# check_dns LABEL HOST: FAIL on any DNS reply over UDP or TCP.
check_dns() {
  local proto r
  [ -n "$2" ] || { printf 'skip  %-26s no address\n' "$1"; return; }
  for proto in udp tcp; do
    r=$(dns "$2" "$proto")
    if [ "$r" = answered ]; then
      printf 'FAIL  %-26s %s:%s/%s answered\n' "$1" "$2" "${PROBE_DNS_PORT:-53}" "$proto"
      bad=1
    else
      printf 'ok    %-26s %s:%s/%s no answer\n' "$1" "$2" "${PROBE_DNS_PORT:-53}" "$proto"
    fi
  done
}

# check LABEL HOST PORT: anything but blocked is a FAIL.
check() {
  local r
  if [ -z "$2" ]; then
    printf 'skip  %-26s no address\n' "$1"
    return
  fi
  r=$(reach "$2" "$3")
  if [ "$r" != blocked ]; then
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

check "fleetd via the gateway" "$gw" "$fleetd_port"
check "Mac tailnet, serve" "$mac" 443
check "Mac tailnet, fleetd" "$mac" "$fleetd_port"
check "Tailscale resolver" "${PROBE_RESOLVER:-100.100.100.100}" 53
check_dns "Tailscale DNS" "${PROBE_RESOLVER:-100.100.100.100}"
check_dns "gateway DNS" "$gw"
check "tailnet peer, https" "$peer" 443
check "tailnet peer, ssh" "$peer" 22
check "internet, direct" "${PROBE_INTERNET:-1.1.1.1}" 443
for port in "$@"; do
  check "Mac service" "$gw" "$port"
done

[ "$bad" = 0 ] && echo "isolation: ok" || echo "isolation: FAIL"
exit "$bad"

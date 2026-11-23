#!/usr/bin/env bash
# On a Mac running `pic serve`: check what a fleet turn's VM can reach.
#
#   test/fleet-isolation.sh SID
#
# SID is a session that has finished at least one turn. This starts a VM the
# way pi-ctr does (run.sh --fleet-state on that session's state folder, so
# pi-locked, the proxy and the placeholder key) and runs fleet-probe.sh in
# it against this Mac's tailnet IP, an online tailnet peer, the network's
# gateway (this Mac) and the Mac's listening ports. Ends with
# "isolation: ok" or "isolation: FAIL"; exits non-zero on FAIL or BROKEN.
# PROBE_TIMEOUT, PROBE_INTERNET and PROBE_RESOLVER (see fleet-probe.sh) are
# passed into the VM.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(CDPATH= cd -- "$here/.." && pwd -P)
. "$root/names.sh"
die() { echo "fleet-isolation.sh: $*" >&2; exit 2; }

sid=${1:-}
case $sid in
  '' | *[!a-z0-9-]*) die "usage: test/fleet-isolation.sh SID (a session id from the phone URL, after #)" ;;
esac
state="$HOME/.fleet/sessions/$sid/state"
[ -d "$state" ] || die "no $state; spawn a session and let one turn finish"
for c in tailscale jq container lsof; do
  command -v "$c" >/dev/null 2>&1 || die "$c not found"
done

cfg="${PI_CONFIG_DIR:-$(pi_default_config_dir)}"
net="${PI_NETWORK_NAME:-$(pi_network_name "$cfg")}"
mac=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
[ -n "$mac" ] || die "tailscale ip -4 printed nothing; is Tailscale up?"
peer=$(tailscale status --json | jq -r '[.Peer[]? | select(.Online) | .TailscaleIPs[0]] | first // empty')
gw=$(container network inspect "$net" | jq -r '.[0].status.ipv4Gateway // empty')
[ -n "$gw" ] || die "no gateway for network $net; has pic run on this Mac?"

# TCP ports this Mac listens on beyond loopback, plus common macOS services.
listening=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $1, $9 }' |
  grep -v -E ' (127\.[0-9.]+|\[::1\]|localhost):' || true)
ports=$({ printf '%s\n' "$listening" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p'; printf '%s\n' 22 445 548 5000 5900 7000; } | sort -un)

# The VM gets only what run.sh passes, so settings travel in the script.
settings=""
for v in PROBE_TIMEOUT PROBE_INTERNET PROBE_RESOLVER; do
  if [ -n "${!v:-}" ]; then settings="$settings$v=$(printf '%q' "${!v}"); "; fi
done

echo "Mac tailnet $mac; peer ${peer:-(none online)}; gateway $gw (this Mac)"
code=0
# shellcheck disable=SC2086
"$root/run.sh" --fleet-state "$state" bash -c "$settings$(cat "$here/fleet-probe.sh")" fleet-probe \
  "$mac" "$peer" "$gw" "${FLEET_PORT:-7433}" $ports || code=$?

if [ -n "$listening" ]; then
  echo
  echo "Your processes listening beyond loopback (each REACHABLE port above is one a turn can use):"
  printf '  %s\n' "$listening"
fi
exit "$code"

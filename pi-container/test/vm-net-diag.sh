#!/usr/bin/env bash
# On a Mac: confirm the egress lock, in more detail than `run.sh check`.
# Changes nothing.
#
#   test/vm-net-diag.sh
#
# Runs a VM the way `pic` and fleet turns do (run.sh normal mode: pi-locked,
# proxy, placeholder key, egress lock) and reports its resolver, routes,
# netfilter and capabilities, and asks each DNS server for a few names. With
# the lock, every DNS line says "no answer"; any other result is a way around
# the proxy. Then, from the host, it records what ASSUMPTIONS.md relies on:
# `container run` takes --cap-add/--cap-drop, and the default capability set.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(CDPATH= cd -- "$here/.." && pwd -P)
. "$root/names.sh"
cli=${CONTAINER_CLI:-container}
cfg="${PI_CONFIG_DIR:-$(pi_default_config_dir)}"
net="${PI_NETWORK_NAME:-$(pi_network_name "$cfg")}"
image=${PI_IMAGE:-pi-agent:local}
for c in "$cli" jq tailscale; do
  command -v "$c" >/dev/null 2>&1 || { echo "vm-net-diag.sh: $c not found" >&2; exit 2; }
done
gw=$("$cli" network inspect "$net" | jq -r '.[0].status.ipv4Gateway // empty')
tsname=$(tailscale status --json | jq -r '.Self.DNSName // empty | rtrimstr(".")')
nonce=fleetdiag$RANDOM$RANDOM

echo "== host"
echo "container: $("$cli" --version 2>&1 | head -n 1)"
echo "network $net gateway: ${gw:-?}"
echo "ip forwarding: $(sysctl -n net.inet.ip.forwarding 2>/dev/null)"
echo "tailscale accept-dns (CorpDNS): $(tailscale debug prefs 2>/dev/null | jq -r '.CorpDNS // "?"')"
echo "container run cap flags: $("$cli" run --help 2>&1 | grep -oE -- '--cap-(add|drop)' | sort -u | tr '\n' ' ')"

# Everything below runs inside the VM. Only bash, node and /proc are used.
read -r -d '' inside <<'EOF' || true
gw=$1 tsname=$2 nonce=$3
echo "== VM"
echo "--- /etc/resolv.conf"; grep -v '^#' /etc/resolv.conf
echo "--- routes (/proc/net/route: Iface Destination Gateway, hex)"; awk 'NR > 1 { print $1, $2, $3 }' /proc/net/route
echo "--- capabilities"; grep -E '^Cap(Eff|Bnd)' /proc/self/status
echo "--- netfilter in this kernel"
for p in /proc/sys/net/netfilter /proc/net/ip_tables_names /proc/net/nf_conntrack; do
  [ -e "$p" ] && echo "present: $p" || echo "absent:  $p"
done
for b in ip iptables nft setpriv capsh; do printf '%s: %s\n' "$b" "$(command -v "$b" || echo missing)"; done
echo "--- DNS (UDP), each server x each name"
servers="100.100.100.100 $gw $(awk '/^nameserver/ { print $2 }' /etc/resolv.conf)"
node - "$nonce" "$tsname" $servers <<'JS'
const dns = require("dns").promises;
const [nonce, tsname, ...servers] = process.argv.slice(2);
const names = ["openrouter.ai", "example.com", `${nonce}.example.com`, tsname].filter(Boolean);
(async () => {
  for (const s of [...new Set(servers)]) {
    for (const n of names) {
      const r = new dns.Resolver({ timeout: 3000, tries: 1 });
      r.setServers([s]);
      let out;
      try { out = "ANSWERED " + (await r.resolve4(n)).join(","); }
      catch (e) {
        out = { ENOTFOUND: "NXDOMAIN (a resolver answered)", EREFUSED: "REFUSED (answered, did not resolve)",
                ESERVFAIL: "SERVFAIL (answered)", ETIMEOUT: "no answer", ECONNREFUSED: "no answer (port closed)" }[e.code] || e.code;
      }
      console.log(`${s.padEnd(16)} ${n.padEnd(44)} ${out}`);
    }
  }
})();
JS
echo "(A random ${nonce}.example.com that gets NXDOMAIN or an answer means that server forwards to the internet: a channel around the proxy.)"
EOF

echo
"$root/run.sh" bash -c "$inside" diag "${gw:-}" "${tsname:-}" "$nonce"

echo
echo "== can a VM start with capabilities dropped or added?"
for flags in "--cap-drop ALL" "--cap-add NET_ADMIN"; do
  # shellcheck disable=SC2086
  out=$("$cli" run --rm --network "$net" $flags "$image" sh -c 'grep -E "^Cap(Eff|Bnd)" /proc/self/status' 2>&1)
  printf '%s -> %s\n' "$flags" "$(printf '%s' "$out" | tr '\n' ' ')"
done

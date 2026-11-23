# The VM's egress lock: the first command a locked VM runs.
#
# Sourced, never executed. pi_netlock_script prints a bash script that run.sh
# passes as the container's outer command in normal mode, fleet turns, and
# check:
#
#   bash -c "$(pi_netlock_script)" netlock PROXY_IP PROXY_PORT COMMAND [ARG...]
#
# The container starts as root with NET_ADMIN. The script lets the VM send
# only to loopback and to the proxy's TCP port, then drops every other
# outbound packet (IPv4 and IPv6). It then runs COMMAND without NET_ADMIN and
# NET_RAW in the bounding set, so nothing COMMAND starts can change the rules.
# It uses iptables-legacy because the VM kernel has ip_tables but not
# nf_tables, and no nf_conntrack, so the rules are stateless: replies arrive
# on INPUT, which stays open. If any step fails, the script says why and
# exits 1 without running COMMAND.

pi_netlock_script() {
  cat <<'EOF'
die() { echo "netlock: $*; the command did not run" >&2; exit 1; }
[ $# -ge 3 ] || die "usage: netlock PROXY_IP PROXY_PORT COMMAND [ARG...]"
ip=$1 port=$2
shift 2
case $ip in *[!0-9.]* | '') die "bad proxy address '$ip'" ;; esac
case $port in *[!0-9]* | '') die "bad proxy port '$port'" ;; esac
for b in iptables-legacy setpriv; do
  command -v "$b" >/dev/null 2>&1 || die "$b is missing from the image; rebuild it: ./build.sh"
done
v4() { iptables-legacy -w "$@" || die "iptables-legacy $* failed"; }
v4 -P OUTPUT DROP
v4 -F OUTPUT
v4 -A OUTPUT -o lo -j ACCEPT
v4 -A OUTPUT -d "$ip" -p tcp --dport "$port" -j ACCEPT
# IPv6: the proxy is IPv4 only, so allow loopback and drop the rest. A kernel
# without ip6_tables gets IPv6 switched off instead; a kernel without IPv6
# has no IPv6 to lock.
if command -v ip6tables-legacy >/dev/null 2>&1 && ip6tables-legacy -w -L OUTPUT -n >/dev/null 2>&1; then
  v6() { ip6tables-legacy -w "$@" || die "ip6tables-legacy $* failed"; }
  v6 -P OUTPUT DROP
  v6 -F OUTPUT
  v6 -A OUTPUT -o lo -j ACCEPT
elif [ -e "${NETLOCK_PROC:-/proc}/net/if_inet6" ]; then
  for f in "${NETLOCK_PROC:-/proc}"/sys/net/ipv6/conf/*/disable_ipv6; do
    [ -e "$f" ] || die "IPv6 is on but cannot be locked or disabled"
    echo 1 >"$f" 2>/dev/null || die "cannot write $f"
  done
fi
exec setpriv --bounding-set=-net_admin,-net_raw --inh-caps=-net_admin,-net_raw -- "$@"
EOF
}

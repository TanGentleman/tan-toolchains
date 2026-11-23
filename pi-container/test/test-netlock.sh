#!/usr/bin/env bash
# Unit tests for lib/netlock.sh: the lock script runs here against stub
# iptables-legacy, ip6tables-legacy and setpriv. PATH holds only the stubs
# and bash, so a real tool on a CI host cannot stand in for a missing one.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
. "$root/lib/netlock.sh"

tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
script=$(pi_netlock_script)
bash -n <(printf '%s\n' "$script") && pass || fail "lock script parses"

# A stub logs "NAME ARGS" and fails when its args equal $FAIL_ON.
stub() { # dir name
  printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >> "$NETLOCK_LOG"\n[ "$*" != "${FAIL_ON:-}" ] || exit 1\n' "$2" > "$1/$2"
  chmod +x "$1/$2"
}
# setpriv logs its args, then runs what follows "--".
setpriv_stub() { # dir
  printf '#!/bin/sh\nprintf "setpriv %%s\\n" "$*" >> "$NETLOCK_LOG"\nwhile [ "$1" != -- ]; do shift; done\nshift\nexec "$@"\n' > "$1/setpriv"
  chmod +x "$1/setpriv"
}

# new_world NAME [tools...]: a bin dir with bash and the named tools.
new_world() {
  w=$tmp/$1
  shift
  mkdir -p "$w/bin" "$w/proc"
  ln -s "$(command -v bash)" "$w/bin/bash"
  for tool in "$@"; do
    case $tool in
      setpriv) setpriv_stub "$w/bin" ;;
      *) stub "$w/bin" "$tool" ;;
    esac
  done
  : > "$w/log"
}

# lock [ENV=VALUE...] -- ARGS: run the script in $w; commands write $w/ran.
lock() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  code=0
  (cd "$w" && env -i PATH="$w/bin" NETLOCK_LOG="$w/log" NETLOCK_PROC="$w/proc" ${envs[@]+"${envs[@]}"} \
    "$w/bin/bash" -c "$script" netlock "$@") >"$w/out" 2>"$w/err" || code=$?
  log=$(cat "$w/log")
  err=$(cat "$w/err")
}
ran() { [ -f "$w/ran" ]; }

# --- IPv4 and IPv6 tables present: rules in order, then setpriv, then the command.
new_world full iptables-legacy ip6tables-legacy setpriv
lock -- 172.30.240.2 8888 bash -c 'printf "%s|" "$@" > ran' cmd "a b" c
eq 0 "$code" "full lock: exit"
eq "iptables-legacy -w -P OUTPUT DROP
iptables-legacy -w -F OUTPUT
iptables-legacy -w -A OUTPUT -o lo -j ACCEPT
iptables-legacy -w -A OUTPUT -d 172.30.240.2 -p tcp --dport 8888 -j ACCEPT
ip6tables-legacy -w -L OUTPUT -n
ip6tables-legacy -w -P OUTPUT DROP
ip6tables-legacy -w -F OUTPUT
ip6tables-legacy -w -A OUTPUT -o lo -j ACCEPT
setpriv --bounding-set=-net_admin,-net_raw --inh-caps=-net_admin,-net_raw -- bash -c printf \"%s|\" \"\$@\" > ran cmd a b c" "$log" "full lock: rules, then setpriv"
eq "a b|c|" "$(cat "$w/ran" 2>/dev/null)" "full lock: the command runs with its arguments intact"

# --- Each rule failing stops before the command.
for rule in "-w -P OUTPUT DROP" "-w -F OUTPUT" "-w -A OUTPUT -o lo -j ACCEPT" \
            "-w -A OUTPUT -d 172.30.240.2 -p tcp --dport 8888 -j ACCEPT"; do
  new_world "v4fail$RANDOM" iptables-legacy ip6tables-legacy setpriv
  lock FAIL_ON="$rule" -- 172.30.240.2 8888 bash -c ': > "$0"' "$w/ran"
  eq 1 "$code" "v4 rule [$rule] fails: exit"
  ran && fail "v4 rule [$rule] fails: the command ran" || pass
  not_contains setpriv "$log" "v4 rule [$rule] fails: setpriv not reached"
  contains "netlock: iptables-legacy ${rule#-w } failed" "$err" "v4 rule [$rule] fails: says why"
done
for rule in "-w -P OUTPUT DROP" "-w -A OUTPUT -o lo -j ACCEPT"; do
  new_world "v6fail$RANDOM" iptables-legacy ip6tables-legacy setpriv
  lock FAIL_ON="$rule" -- 172.30.240.2 8888 bash -c ': > "$0"' "$w/ran"
  # The same args fail the v4 stub first, which is also fail-closed.
  eq 1 "$code" "rule [$rule] fails: exit"
  ran && fail "rule [$rule] fails: the command ran" || pass
done
# ip6tables-legacy alone failing a rule.
new_world v6only iptables-legacy setpriv
printf '#!/bin/sh\nprintf "ip6tables-legacy %%s\\n" "$*" >> "$NETLOCK_LOG"\ncase "$*" in *"-P OUTPUT DROP"*) exit 1 ;; esac\n' > "$w/bin/ip6tables-legacy"
chmod +x "$w/bin/ip6tables-legacy"
lock -- 172.30.240.2 8888 bash -c ': > "$0"' "$w/ran"
eq 1 "$code" "v6 policy fails: exit"
ran && fail "v6 policy fails: the command ran" || pass
contains "netlock: ip6tables-legacy -P OUTPUT DROP failed" "$err" "v6 policy fails: says why"

# --- Missing tools.
for missing in iptables-legacy setpriv; do
  case $missing in
    iptables-legacy) new_world "miss-$missing" ip6tables-legacy setpriv ;;
    setpriv) new_world "miss-$missing" iptables-legacy ip6tables-legacy ;;
  esac
  lock -- 172.30.240.2 8888 bash -c ': > "$0"' "$w/ran"
  eq 1 "$code" "$missing missing: exit"
  ran && fail "$missing missing: the command ran" || pass
  contains "$missing is missing from the image; rebuild it: ./build.sh" "$err" "$missing missing: says how to fix"
  eq "" "$log" "$missing missing: no rule issued"
done

# --- No ip6_tables: IPv6 switched off when the kernel has it.
new_world noip6 iptables-legacy setpriv
mkdir -p "$w/proc/net" "$w/proc/sys/net/ipv6/conf/all" "$w/proc/sys/net/ipv6/conf/eth0"
: > "$w/proc/net/if_inet6"
printf '0\n' > "$w/proc/sys/net/ipv6/conf/all/disable_ipv6"
printf '0\n' > "$w/proc/sys/net/ipv6/conf/eth0/disable_ipv6"
lock -- 172.30.240.2 8888 bash -c ': > "$0"' "$w/ran"
eq 0 "$code" "no ip6tables: exit"
ran && pass || fail "no ip6tables: the command did not run"
eq 1 "$(cat "$w/proc/sys/net/ipv6/conf/all/disable_ipv6")" "no ip6tables: IPv6 off for all"
eq 1 "$(cat "$w/proc/sys/net/ipv6/conf/eth0/disable_ipv6")" "no ip6tables: IPv6 off for eth0"

chmod 444 "$w/proc/sys/net/ipv6/conf/eth0/disable_ipv6"
rm -f "$w/ran"
lock -- 172.30.240.2 8888 bash -c ': > "$0"' "$w/ran"
if [ "$(id -u)" = 0 ]; then
  pass # root ignores the mode; nothing to check
else
  eq 1 "$code" "IPv6 cannot be disabled: exit"
  ran && fail "IPv6 cannot be disabled: the command ran" || pass
  contains "cannot write" "$err" "IPv6 cannot be disabled: says why"
fi

new_world noip6conf iptables-legacy setpriv
mkdir -p "$w/proc/net"
: > "$w/proc/net/if_inet6"
lock -- 172.30.240.2 8888 bash -c ': > "$0"' "$w/ran"
eq 1 "$code" "IPv6 on with no conf dir: exit"
ran && fail "IPv6 on with no conf dir: the command ran" || pass

new_world nov6kernel iptables-legacy setpriv
lock -- 172.30.240.2 8888 bash -c ': > "$0"' "$w/ran"
eq 0 "$code" "kernel without IPv6: exit"
ran && pass || fail "kernel without IPv6: the command did not run"

# --- Bad arguments.
bad_args() { # label, args...
  local label=$1
  shift
  new_world "args$RANDOM" iptables-legacy ip6tables-legacy setpriv
  lock -- "$@"
  eq 1 "$code" "bad args [$label]: exit"
  eq "" "$log" "bad args [$label]: no rule issued"
  ran && fail "bad args [$label]: the command ran" || pass
}
bad_args "port x" 172.30.240.2 x bash -c ': > "$0"' ran
bad_args "ip with ;" "172.30.240.2;" 8888 bash -c ': > "$0"' ran
bad_args "empty ip" "" 8888 bash -c ': > "$0"' ran
bad_args "no command" 172.30.240.2 8888

finish

#!/usr/bin/env bash
# Unit checks for instance and volume naming. Runs without Apple container.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/names.sh"

fail() { printf 'test-names.sh: %s\n' "$*" >&2; exit 1; }

expect() { # expected, actual, label
  [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

for name in default work a w1 my-work v2; do
  pi_instance_valid "$name" || fail "expected instance '$name' to be valid"
done

for name in '' home Home -work work_ work/foo 'work foo'; do
  if pi_instance_valid "$name"; then fail "expected instance '$name' to be invalid"; fi
done

long=abcdefghijklmnopqrstuvwx
pi_instance_valid "$long" || fail "expected 24-character instance to be valid"
if pi_instance_valid "${long}x"; then fail "expected 25-character instance to be invalid"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

default_cfg=$(pi_default_config_dir)
custom_cfg="$tmp/profile"
mkdir -p "$custom_cfg"
profile_id=$(printf '%s' "$custom_cfg" | pi_sha256 | cut -c1-8)

expect "" "$(pi_profile_id "$default_cfg")" "default profile id"
expect default "$(pi_profile_label "$default_cfg")" "default profile label"
expect "pi-proxy" "$(pi_proxy_name "$default_cfg")" "default proxy name"
expect "pi-proxy:local" "$(pi_proxy_image "$default_cfg")" "default proxy image"
expect "pi-locked" "$(pi_network_name "$default_cfg")" "default network name"
expect "172.30.240.0/24" "$(pi_locked_subnet "$default_cfg")" "default subnet"

expect "$profile_id" "$(pi_profile_id "$custom_cfg")" "custom profile id"
expect "$profile_id" "$(pi_profile_label "$custom_cfg")" "custom profile label"
expect "pi-proxy-$profile_id" "$(pi_proxy_name "$custom_cfg")" "custom proxy name"
expect "pi-proxy-$profile_id:local" "$(pi_proxy_image "$custom_cfg")" "custom proxy image"
expect "pi-locked-$profile_id" "$(pi_network_name "$custom_cfg")" "custom network name"
case $(pi_locked_subnet "$custom_cfg") in
  172.30.*.0/24) ;;
  *) fail "custom profile subnet is malformed" ;;
esac
[ "$(pi_locked_subnet "$custom_cfg")" != "172.30.240.0/24" ] ||
  fail "custom profile reused the default subnet"

expect pi-agent-home "$(pi_agent_volume default "$default_cfg")" "default agent volume"
expect pi-agent-work "$(pi_agent_volume work "$default_cfg")" "named agent volume"
expect "pi-agent-$profile_id-home" "$(pi_agent_volume default "$custom_cfg")" "custom default agent volume"
expect "pi-agent-$profile_id-work" "$(pi_agent_volume work "$custom_cfg")" "custom named agent volume"
expect "$default_cfg/settings.json" \
  "$(pi_settings_file "$default_cfg")" "profile settings file"
expect "$default_cfg/private/host-setup.lock" "$(pi_lock_dir)" "global lock path"

work_clone=$(pi_clone_volume work owner/repo "$default_cfg")
default_clone=$(pi_clone_volume default owner/repo "$default_cfg")
custom_clone=$(pi_clone_volume work owner/repo "$custom_cfg")
case $work_clone in
  pi-clone_work_owner-repo-????????) ;;
  *) fail "unexpected work clone volume: $work_clone" ;;
esac
case $default_clone in
  pi-clone_default_owner-repo-????????) ;;
  *) fail "unexpected default clone volume: $default_clone" ;;
esac
case $custom_clone in
  "pi-clone_${profile_id}_work_owner-repo-"????????) ;;
  *) fail "unexpected custom clone volume: $custom_clone" ;;
esac
[ "$work_clone" != "$default_clone" ] || fail "instances must not share a clone volume"
[ "$work_clone" != "$custom_clone" ] || fail "profiles must not share a clone volume"

# Generated clone volumes use one unambiguous namespace.
case $work_clone in
  pi-clone_*) ;;
  *) fail "clone volume lacks the pi-clone_ namespace: $work_clone" ;;
esac

# pi_sha256 must forward file arguments: run.sh hashes files through it, and a
# helper that always reads stdin blocks when run from a terminal.
printf 'alpha\n' > "$tmp/a"
printf 'beta\n' > "$tmp/b"
expected=$(printf 'alpha\n' | pi_sha256 | awk '{print $1}')
actual=$(pi_sha256 "$tmp/a" < /dev/null | awk '{print $1}')
expect "$expected" "$actual" "pi_sha256 hashes a file argument"
if [ "$(pi_sha256 "$tmp/a" < /dev/null)" = "$(pi_sha256 "$tmp/b" < /dev/null)" ]; then
  fail "pi_sha256 ignored distinct file arguments"
fi

printf 'test-names.sh: ok\n'

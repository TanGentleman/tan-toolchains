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

expect pi-agent-home "$(pi_agent_volume default)" "default agent volume"
expect pi-agent-work "$(pi_agent_volume work)" "named agent volume"
expect "$HOME/.config/pi-container/settings.json" \
  "$(pi_settings_file "$HOME/.config/pi-container")" "shared settings file"

work_clone=$(pi_clone_volume work owner/repo)
default_clone=$(pi_clone_volume default owner/repo)
case $work_clone in
  pi-clone_work_owner-repo-????????) ;;
  *) fail "unexpected work clone volume: $work_clone" ;;
esac
case $default_clone in
  pi-clone_default_owner-repo-????????) ;;
  *) fail "unexpected default clone volume: $default_clone" ;;
esac
[ "$work_clone" != "$default_clone" ] || fail "instances must not share a clone volume"

# New clone names cannot collide with legacy pi-clone-<slug>-<hash> names.
case $work_clone in
  pi-clone_*) ;;
  *) fail "new clone volume lacks the pi-clone_ namespace: $work_clone" ;;
esac

# pi_sha256 must forward file arguments: run.sh hashes files through it, and a
# helper that always reads stdin blocks when run from a terminal.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'alpha\n' > "$tmp/a"
printf 'beta\n' > "$tmp/b"
expected=$(printf 'alpha\n' | pi_sha256 | awk '{print $1}')
actual=$(pi_sha256 "$tmp/a" < /dev/null | awk '{print $1}')
expect "$expected" "$actual" "pi_sha256 hashes a file argument"
if [ "$(pi_sha256 "$tmp/a" < /dev/null)" = "$(pi_sha256 "$tmp/b" < /dev/null)" ]; then
  fail "pi_sha256 ignored distinct file arguments"
fi

printf 'test-names.sh: ok\n'

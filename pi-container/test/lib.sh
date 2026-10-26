# Assertion helpers for pi-container tests. Sourced, never executed.
#
# Deliberately does not use `set -e`: a failed assertion must keep the script
# running so one run reports every failure.

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(CDPATH= cd -- "$here/.." && pwd -P)
fixtures="$here/fixtures/container"

t_pass=0
t_fail=0

pass() { t_pass=$((t_pass + 1)); }
fail() { t_fail=$((t_fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

eq() { # expected, actual, [label]
  if [ "$1" = "$2" ]; then pass; else fail "${3:-value}: expected [$1], got [$2]"; fi
}

neq() { # unexpected, actual, [label]
  if [ "$1" != "$2" ]; then pass; else fail "${3:-value}: expected not [$1]"; fi
}

contains() { # needle, haystack, [label]
  case $2 in
    *"$1"*) pass ;;
    *) fail "${3:-output}: missing [$1] in [$2]" ;;
  esac
}

not_contains() { # needle, haystack, [label]
  case $2 in
    *"$1"*) fail "${3:-output}: unexpected [$1] in [$2]" ;;
    *) pass ;;
  esac
}

# rc <expected status> <label> <command...>
rc() {
  local want=$1 label=$2
  shift 2
  local out status
  out=$("$@" 2>&1)
  status=$?
  if [ "$status" = "$want" ]; then
    pass
  else
    fail "$label: expected status $want, got $status: $out"
  fi
}

finish() {
  printf '%s: %d passed, %d failed\n' "${0##*/}" "$t_pass" "$t_fail"
  [ "$t_fail" -eq 0 ]
}

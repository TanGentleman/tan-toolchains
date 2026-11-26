# Input validation shared by run.sh and the test suite. Sourced, never executed.
#
# These return a status; they never print or exit. run.sh owns the messages so
# its CLI stays consistent.

# Decimal port in 1..65535. Leading zeros are accepted ("080" is 80), matching
# the `[ ... -ge 1 ]` test run.sh used before this moved here.
pi_port_valid() { # port
  case ${1:-} in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Strip a single trailing .git so owner/repo.git and owner/repo name the same
# clone volume. Prints the normalised value.
pi_repo_normalize() { # owner/repo
  case ${1:-} in
    *.git) printf '%s' "${1%.git}" ;;
    *) printf '%s' "${1:-}" ;;
  esac
}

# owner/repo must be exactly one slash. The owner starts with an alphanumeric;
# the repo may not be . or .. and may not start with a hyphen (argument
# injection into git). Prints nothing.
pi_repo_valid() { # owner/repo
  local clone=${1:-} owner repo
  owner=${clone%%/*}
  repo=${clone#*/}
  [ "$owner" != "$clone" ] || return 1
  [ -n "$owner" ] || return 1
  [ -n "$repo" ] || return 1
  [[ $owner =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 1
  [[ $repo =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [ "$repo" != . ] || return 1
  [ "$repo" != .. ] || return 1
  [ "${repo#-}" = "$repo" ] || return 1
  return 0
}

# PI_EGRESS: the proxy's egress profile. Empty means normal.
pi_egress_valid() { # mode
  case ${1:-} in
    normal|offline) return 0 ;;
  esac
  return 1
}

# The only upstream offline mode allows: a dotted-quad IPv4 address in
# 10/8, 172.16/12, 192.168/16 or 169.254/16. proxy.py enforces the same list.
pi_offline_upstream_valid() { # host
  local ip=${1:-} a b o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    [ "$((10#$o))" -le 255 ] || return 1
  done
  a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
  [ "$a" = 10 ] && return 0
  [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
  [ "$a" = 192 ] && [ "$b" = 168 ] && return 0
  [ "$a" = 169 ] && [ "$b" = 254 ] && return 0
  return 1
}

# Path and permission helpers shared by run.sh and the test suite.
#
# Sourced, never executed: these functions must not change shell options or
# exit. Callers own error handling and messages.
#
# The mount guard is security-sensitive: a project mount must never expose the
# host config directory or a secrets directory. Keeping the comparison logic
# here means tests can exercise it without a live container runtime.

# Mode of the symlink target, not the link itself. GNU stat first (Linux/CI),
# BSD stat second (macOS).
pi_file_mode() { # path
  if stat -Lc %a "$1" >/dev/null 2>&1; then
    stat -Lc %a "$1"
  else
    stat -Lf %Lp "$1"
  fi
}

pi_physical_dir() { # path
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

# Resolve symlinks first, then use realpath when available. Resolving first
# keeps dangling links consistent across GNU and BSD realpath, and the depth cap
# stops a symlink loop from hanging a guard check. Missing paths are returned
# unchanged so callers can still compare them (the guard must fail closed).
pi_physical_path() { # path
  local p=$1 d t depth=0
  [ -e "$p" ] || [ -L "$p" ] || { printf '%s\n' "$p"; return 0; }
  while [ -L "$p" ]; do
    depth=$((depth + 1))
    [ "$depth" -le 40 ] || { printf '%s\n' "$p"; return 0; }
    t=$(readlink "$p") || break
    case $t in
      /*) p=$t ;;
      *) p=$(dirname "$p")/$t ;;
    esac
  done
  [ -e "$p" ] || { printf '%s\n' "$p"; return 0; }
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p" 2>/dev/null || printf '%s\n' "$p"
    return 0
  fi
  d=$(pi_physical_dir "$(dirname "$p")") || { printf '%s\n' "$p"; return 0; }
  printf '%s/%s\n' "${d%/}" "$(basename "$p")"
}

# Exit 0 when child is parent or below it. Compare case-folded: macOS volumes
# are usually case-insensitive, and the guard should fail closed if the user
# types a different case.
pi_path_within() { # parent, child
  local parent child
  parent=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  child=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  [ "$parent" = / ] && return 0
  case $child in "$parent"|"$parent"/*) return 0 ;; esac
  return 1
}

# Host lock shared by run.sh and clear.sh. Sourced, never executed.
#
# The lock directory is a single mkdir: the first process wins, and a pid file
# lets a later process clear a stale lock. Both scripts touch the same machine-
# wide resources (images, builder cache), so they must serialize.

pi_acquire_lock() { # lock_dir, label
  local lock_dir=$1 label=$2 pid waited=0 limit=${PI_LOCK_WAIT:-120} lock_parent
  lock_parent=$(dirname "$lock_dir")
  mkdir -p "$lock_parent"
  chmod 700 "$lock_parent" 2>/dev/null || true
  while ! mkdir "$lock_dir" 2>/dev/null; do
    pid=""
    [ -f "$lock_dir/pid" ] && pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$lock_dir"
      continue
    fi
    if [ -z "$pid" ] && [ "$waited" -ge 5 ]; then
      rm -rf "$lock_dir"
      continue
    fi
    if [ "$waited" -ge "$limit" ]; then
      printf '%s: timed out waiting for another pi-container start; remove %s if it is stale\n' "$label" "$lock_dir" >&2
      return 1
    fi
    [ "$waited" -eq 0 ] && printf '%s: waiting for another pi-container start to finish\n' "$label" >&2
    sleep 1
    waited=$((waited + 1))
  done
  if ! printf '%s\n' "$$" > "$lock_dir/pid"; then
    rm -rf "$lock_dir"
    printf '%s: cannot write %s/pid\n' "$label" "$lock_dir" >&2
    return 1
  fi
}

pi_release_lock() { # lock_dir
  local pid
  [ -f "$1/pid" ] || return 0
  pid=$(cat "$1/pid" 2>/dev/null || true)
  [ "$pid" = "$$" ] && rm -rf "$1"
  return 0
}

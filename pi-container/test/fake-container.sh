#!/usr/bin/env bash
# Stand-in for Apple's `container` CLI. Never talks to a runtime.
#
# Point CONTAINER_CLI here and set FAKE_CONTAINER_WORLD to a directory laid out
# as below. Every invocation appends one CALL line to FAKE_CONTAINER_LOG so a
# test can assert the exact argv run.sh/clear.sh built.
#
# World layout ($FAKE_CONTAINER_WORLD):
#   images/<sanitized-image>.json   image inspect payload; file presence = exists
#   networks.list                   network list -q output
#   networks/<name>.json            network inspect payload; presence = exists
#   containers/<name>.json          inspect payload; presence = exists
#   volumes.list                    volume list -q output
#   volumes/<name>.json             volume inspect payload; presence = exists
#   run.stdout                      optional stdout for `run`
#   fail/<key>                      presence forces exit 1 for that key
#
# Sanitising an image name replaces / and : with _ (pi-agent:local ->
# pi-agent_local). Unknown commands exit 1 so a new CLI call cannot silently
# pass tests.
set -uo pipefail

world=${FAKE_CONTAINER_WORLD:-}
log=${FAKE_CONTAINER_LOG:-}

if [ -n "$log" ]; then
  { printf 'CALL'; printf ' %q' "$@"; printf '\n'; } >> "$log"
fi

sanitize() { printf '%s' "$1" | tr '/:' '__'; }

fail_if() { # key
  [ -n "$world" ] && [ -e "$world/fail/$1" ] || return 0
  printf 'fake-container: forced failure: %s\n' "$1" >&2
  exit 1
}

need_world() {
  [ -n "$world" ] || { printf 'fake-container: FAKE_CONTAINER_WORLD is unset\n' >&2; exit 1; }
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case $cmd in
  image)
    sub=${1:-}; [ $# -gt 0 ] && shift
    case $sub in
      inspect)
        need_world; fail_if image.inspect
        f="$world/images/$(sanitize "${1:-}").json"
        [ -f "$f" ] || { printf 'fake-container: no image %s\n' "${1:-}" >&2; exit 1; }
        cat "$f"
        ;;
      delete) fail_if image.delete ;;
      *) printf 'fake-container: unhandled image subcommand: %s\n' "$sub" >&2; exit 1 ;;
    esac
    ;;
  network)
    sub=${1:-}; [ $# -gt 0 ] && shift
    case $sub in
      list)
        need_world; fail_if network.list
        if [ -f "$world/networks.list" ]; then cat "$world/networks.list"; fi
        ;;
      inspect)
        need_world; fail_if network.inspect
        f="$world/networks/${1:-}.json"
        [ -f "$f" ] || { printf 'fake-container: no network %s\n' "${1:-}" >&2; exit 1; }
        cat "$f"
        ;;
      create) fail_if network.create ;;
      delete) fail_if network.delete ;;
      *) printf 'fake-container: unhandled network subcommand: %s\n' "$sub" >&2; exit 1 ;;
    esac
    ;;
  volume)
    sub=${1:-}; [ $# -gt 0 ] && shift
    case $sub in
      list)
        need_world; fail_if volume.list
        if [ -f "$world/volumes.list" ]; then cat "$world/volumes.list"; fi
        ;;
      inspect)
        need_world; fail_if volume.inspect
        f="$world/volumes/${1:-}.json"
        [ -f "$f" ] || { printf 'fake-container: no volume %s\n' "${1:-}" >&2; exit 1; }
        cat "$f"
        ;;
      create) fail_if volume.create ;;
      delete) fail_if volume.delete ;;
      *) printf 'fake-container: unhandled volume subcommand: %s\n' "$sub" >&2; exit 1 ;;
    esac
    ;;
  inspect)
    need_world; fail_if inspect
    f="$world/containers/${1:-}.json"
    [ -f "$f" ] || { printf 'fake-container: no container %s\n' "${1:-}" >&2; exit 1; }
    cat "$f"
    ;;
  run)
    fail_if run
    if [ -n "$world" ] && [ -f "$world/run.stdout" ]; then cat "$world/run.stdout"; fi
    ;;
  exec) fail_if exec ;;
  start|stop|delete|build|builder|logs) fail_if "$cmd" ;;
  *)
    printf 'fake-container: unhandled command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac

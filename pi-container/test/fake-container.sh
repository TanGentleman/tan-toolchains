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
# With FAKE_CONTAINER_DELETE_REMOVES=1, `delete NAME` removes
# containers/NAME.json, as the real CLI removes the container. Off by
# default: run.sh's proxy recreation would then wait for an address the fake
# never writes.
#
# FAKE_CONTAINER_EXEC=DIR makes `run` execute its command on this machine
# instead: each run gets a fresh DIR/run.N standing in for the container's
# disk, a "/work" path in the command and -w is rewritten to DIR/run.N/work, HOME is
# DIR/run.N/home (seeded from DIR/gitconfig), only -e/--env-file variables
# and PATH (FAKE_CONTAINER_PATH first) are set, and the environment is
# appended to DIR/env.log. -v mounts are ignored, so a same-path mount works.
# fake-vm-bin/ comes next on PATH: stubs for the image's iptables-legacy,
# ip6tables-legacy and setpriv, so run.sh's egress lock runs and passes.
#
# Sanitising an image name replaces / and : with _ (pi-full:local ->
# pi-full_local). Unknown commands exit 1 so a new CLI call cannot silently
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
    if [ -n "${FAKE_CONTAINER_EXEC:-}" ]; then
      envs=() wd=/
      while [ $# -gt 0 ]; do
        case $1 in
          --rm|-i|--init|-t) shift ;;
          -e) envs+=("$2"); shift 2 ;;
          --env-file) while IFS= read -r l || [ -n "$l" ]; do [ -z "$l" ] || envs+=("$l"); done < "$2"; shift 2 ;;
          -w) wd=$2; shift 2 ;;
          -v|--network|--cpus|--memory|--name|--label|--cap-add|--cap-drop) shift 2 ;;
          -*) printf 'fake-container: unhandled run option: %s\n' "$1" >&2; exit 1 ;;
          *) break ;;
        esac
      done
      shift # image
      disk=$(mktemp -d "$FAKE_CONTAINER_EXEC/run.XXXXXX")
      mkdir -p "$disk/work" "$disk/home"
      [ ! -f "$FAKE_CONTAINER_EXEC/gitconfig" ] || cp "$FAKE_CONTAINER_EXEC/gitconfig" "$disk/home/.gitconfig"
      argv=()
      for a in "$@"; do
        argv+=("$(printf '%s\n' "$a" | sed -E "s#(^|[^A-Za-z0-9._-])/work(\$|[/\"[:space:]])#\\1$disk/work\\2#g"; printf x)")
        argv[${#argv[@]}-1]=${argv[${#argv[@]}-1]%$'\nx'}
      done
      wd=${wd/#\/work/$disk/work}
      printf '%s\n' "${envs[@]}" "--" >> "$FAKE_CONTAINER_EXEC/env.log"
      mkdir -p "$wd"
      cd "$wd" || exit 1
      vmbin=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/fake-vm-bin
      exec env -i PATH="${FAKE_CONTAINER_PATH:+$FAKE_CONTAINER_PATH:}$vmbin:$PATH" HOME="$disk/home" "${envs[@]}" "${argv[@]}"
    fi
    if [ -n "$world" ] && [ -f "$world/run.stdout" ]; then cat "$world/run.stdout"; fi
    ;;
  exec) fail_if exec ;;
  system) fail_if system ;;
  delete)
    fail_if delete
    for a in "$@"; do
      case $a in -*) ;; *) [ "${FAKE_CONTAINER_DELETE_REMOVES:-}" != 1 ] || [ -z "$world" ] || rm -f "$world/containers/$a.json" ;; esac
    done
    ;;
  start|stop|build|builder|logs) fail_if "$cmd" ;;
  *)
    printf 'fake-container: unhandled command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac

#!/usr/bin/env bash
# Back up sessions and reset pi-container state.
#
#   clear.sh save
#   clear.sh nuke agent [--yes]
#   clear.sh nuke all [--yes] [--clones]
#   clear.sh help
set -euo pipefail

cli="${CONTAINER_CLI:-container}"
agent_volume="${PI_AGENT_VOLUME:-pi-agent-home}"
pi_image="${PI_IMAGE:-pi-agent:local}"
proxy_name="pi-proxy"
proxy_image="${PI_PROXY_IMAGE:-pi-proxy:local}"
network="pi-locked"
cfg="${PI_CONFIG_DIR:-$HOME/.config/pi-container}"
backup_root="${PI_BACKUP_DIR:-$HOME/pi-backups}"
stamp=$(date +%Y%m%d-%H%M%S)

die() { printf 'clear.sh: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

usage() {
  cat <<EOF
Back up sessions and reset pi-container state. Backups go to $backup_root.

  clear.sh save
      Save session JSONL files as $backup_root/sessions-<time>/.

  clear.sh nuke agent [--yes]
      Save sessions, then delete $agent_volume.

  clear.sh nuke all [--yes] [--clones]
      Save sessions, then delete $agent_volume, $proxy_name, $network,
      $pi_image, $proxy_image, and the builder cache.
      --clones also deletes pi-clone-* volumes.

Host config stays at $cfg.
EOF
}

volume_exists() { "$cli" volume list -q 2>/dev/null | grep -qx "$1"; }
image_exists() { "$cli" image inspect "$1" >/dev/null 2>&1; }
container_exists() { "$cli" inspect "$1" >/dev/null 2>&1; }
network_exists() { "$cli" network list -q 2>/dev/null | grep -qx "$1"; }

require_image() {
  image_exists "$pi_image" || die "missing image $pi_image; build it with: container build -t $pi_image ."
}
require_agent_volume() { volume_exists "$agent_volume" || die "missing volume $agent_volume"; }

clone_volumes() {
  "$cli" volume list -q 2>/dev/null | grep '^pi-clone-' || true
}

new_backup_dir() {
  local dest="$backup_root/sessions-$stamp" n=1
  while [ -e "$dest" ]; do
    dest="$backup_root/sessions-$stamp-$n"
    n=$((n + 1))
  done
  (umask 077; mkdir -p "$dest")
  printf '%s\n' "$dest"
}

save_sessions() {
  local dest=$1
  (umask 077; mkdir -p "$dest")
  if "$cli" run --rm -v "$agent_volume:/agent:ro" "$pi_image" test -d /agent/sessions >/dev/null 2>&1; then
    "$cli" run --rm -v "$agent_volume:/agent:ro" "$pi_image" tar -C /agent -cf - sessions |
      tar -C "$dest" -xf -
  else
    say "no sessions in $agent_volume"
  fi
}

confirm() {
  local answer
  [ "${yes:-0}" = 1 ] && return
  [ -t 0 ] || die "refusing without --yes"
  say "$1"
  printf 'Type yes to continue: '
  read -r answer
  [ "$answer" = yes ] || die "aborted"
}

cmd_save() {
  [ $# -eq 0 ] || die "save takes no options"
  require_image
  require_agent_volume
  dest=$(new_backup_dir)
  save_sessions "$dest"
  say "saved: $dest"
}

cmd_nuke_agent() {
  local dest yes=0
  while [ $# -gt 0 ]; do
    case $1 in
      --yes) yes=1; shift ;;
      *) die "unknown nuke agent option: $1" ;;
    esac
  done
  volume_exists "$agent_volume" || { say "no volume $agent_volume"; return; }
  require_image
  confirm "Delete $agent_volume after saving its sessions?"
  dest=$(new_backup_dir)
  save_sessions "$dest"
  say "saved: $dest"
  "$cli" volume delete "$agent_volume" || die "cannot delete $agent_volume; quit Pi first"
  say "deleted: $agent_volume"
}

cmd_nuke_all() {
  local dest clones=0 yes=0 vol img
  while [ $# -gt 0 ]; do
    case $1 in
      --yes) yes=1; shift ;;
      --clones) clones=1; shift ;;
      *) die "unknown nuke all option: $1" ;;
    esac
  done
  if [ "$clones" = 1 ]; then
    say "clone volumes:"
    clone_volumes
    confirm "Delete agent volume, proxy, network, images, builder cache, and all pi-clone-* volumes?"
  else
    confirm "Delete agent volume, proxy, network, images, and builder cache? Clone volumes stay."
  fi

  if volume_exists "$agent_volume"; then
    require_image
    dest=$(new_backup_dir)
    save_sessions "$dest"
    say "saved: $dest"
    "$cli" volume delete "$agent_volume" || die "cannot delete $agent_volume; quit Pi first"
    say "deleted: $agent_volume"
  else
    say "no volume $agent_volume"
  fi

  if [ "$clones" = 1 ]; then
    for vol in $(clone_volumes); do
      "$cli" volume delete "$vol" || die "cannot delete $vol"
      say "deleted: $vol"
    done
  else
    for vol in $(clone_volumes); do
      say "kept: $vol"
    done
  fi

  if container_exists "$proxy_name"; then
    "$cli" delete --force "$proxy_name" >/dev/null 2>&1 || die "cannot delete $proxy_name"
    say "deleted: $proxy_name"
  else
    say "no container: $proxy_name"
  fi

  if network_exists "$network"; then
    "$cli" network delete "$network" >/dev/null 2>&1 || die "cannot delete $network"
    say "deleted: $network"
  else
    say "no network: $network"
  fi

  for img in "$pi_image" "$proxy_image"; do
    if image_exists "$img"; then
      "$cli" image delete "$img" >/dev/null 2>&1 || die "cannot delete $img"
      say "deleted: $img"
    else
      say "no image: $img"
    fi
  done

  "$cli" builder delete --force >/dev/null 2>&1 || true
  say "deleted: builder cache"
  say "kept: $cfg"
}

cmd_nuke() {
  local target=${1:-}
  shift || true
  case $target in
    agent) cmd_nuke_agent "$@" ;;
    all) cmd_nuke_all "$@" ;;
    *) die "nuke needs 'agent' or 'all'" ;;
  esac
}

cmd=${1:-help}
shift || true
case $cmd in
  save) cmd_save "$@" ;;
  nuke) cmd_nuke "$@" ;;
  help | -h | --help) usage ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac

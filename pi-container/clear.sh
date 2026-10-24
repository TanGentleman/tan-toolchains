#!/usr/bin/env bash
# Manage pi-container state and session backups.
#
#   clear.sh save [sessions|agent] [--out DIR] [--tar]
#   clear.sh nuke agent [--yes]
#   clear.sh nuke all [--yes] [--clones]
#   clear.sh status
#   clear.sh shell [agent|proxy|clone VOLUME]
#   clear.sh logs
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
Manage pi-container state and session backups.

  clear.sh save [sessions|agent] [--out DIR] [--tar]
      Save sessions (default) or the whole agent directory.
      --out DIR   write to DIR instead of $backup_root/sessions-<time>
      --tar       also create DIR.tar

  clear.sh nuke agent [--yes]
      Save sessions, then delete the $agent_volume volume.
      Host config and the proxy stay.

  clear.sh nuke all [--yes] [--clones]
      Save sessions, then delete the agent volume, proxy container,
      network, pi images, and builder cache. Add --clones to delete
      pi-clone-* volumes too.

  clear.sh status
      Show containers, volumes, images, networks, and recent backups.

  clear.sh shell [agent|proxy|clone VOLUME]
      Open a helper shell in the agent volume, proxy, or a clone volume.

  clear.sh logs
      Follow the proxy log.

Set PI_BACKUP_DIR to change the backup root.
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

write_manifest() {
  local dest=$1 kind=$2 count
  count=$(find "$dest" -name '*.jsonl' 2>/dev/null | wc -l | awk '{print $1}')
  {
    printf 'saved=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'kind=%s\n' "$kind"
    printf 'volume=%s\n' "$agent_volume"
    printf 'image=%s\n' "$pi_image"
    printf 'session_files=%s\n' "$count"
  } >"$dest/MANIFEST"
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
  write_manifest "$dest" sessions
}

save_agent() {
  local dest=$1
  (umask 077; mkdir -p "$dest")
  "$cli" run --rm -v "$agent_volume:/agent:ro" "$pi_image" tar -C /agent -cf - . |
    tar -C "$dest" -xf -
  write_manifest "$dest" agent
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
  local what=sessions out="" make_tar=0 dest
  while [ $# -gt 0 ]; do
    case $1 in
      sessions|agent) what=$1; shift ;;
      --out) [ $# -ge 2 ] || die "--out needs DIR"; out=$2; shift 2 ;;
      --tar) make_tar=1; shift ;;
      *) die "unknown save option: $1" ;;
    esac
  done
  require_image
  require_agent_volume
  if [ -n "$out" ]; then
    [ -e "$out" ] && die "$out already exists"
    dest=$out
  else
    dest=$(new_backup_dir)
  fi
  if [ "$what" = sessions ]; then
    save_sessions "$dest"
  else
    save_agent "$dest"
  fi
  say "saved: $dest"
  if [ "$make_tar" = 1 ]; then
    tar -C "$dest" -cf "$dest.tar" .
    say "archive: $dest.tar"
  fi
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

cmd_status() {
  say "== containers"
  "$cli" list -a || true
  say "== volumes"
  "$cli" volume list || true
  say "== images"
  "$cli" image list || true
  say "== networks"
  "$cli" network list || true
  say "== backups"
  if [ -d "$backup_root" ]; then
    find "$backup_root" -mindepth 1 -maxdepth 1 -print | sort | tail -20
  else
    say "none"
  fi
  say "== config"
  say "$cfg"
}

cmd_shell() {
  local target=${1:-agent} vol tflag=-i
  shift || true
  if [ -t 0 ] && [ -t 1 ]; then tflag=-it; fi
  case $target in
    agent)
      require_image
      require_agent_volume
      set -- run --rm "$tflag" -v "$agent_volume:/agent" -w /agent "$pi_image" bash
      ;;
    proxy)
      "$cli" exec -it "$proxy_name" bash
      return
      ;;
    clone)
      vol=${1:-}
      [ -n "$vol" ] || { say "clone volumes:"; clone_volumes; exit 2; }
      volume_exists "$vol" || die "missing volume $vol"
      require_image
      set -- run --rm "$tflag" -v "$vol:/work" -w /work "$pi_image" bash
      ;;
    *)
      die "shell needs agent, proxy, or clone VOLUME"
      ;;
  esac
  exec "$cli" "$@"
}

cmd_logs() {
  container_exists "$proxy_name" || die "no $proxy_name container; start it with ./run.sh"
  exec "$cli" logs -f "$proxy_name"
}

cmd=${1:-help}
shift || true
case $cmd in
  save) cmd_save "$@" ;;
  nuke) cmd_nuke "$@" ;;
  status) cmd_status "$@" ;;
  shell) cmd_shell "$@" ;;
  logs) cmd_logs "$@" ;;
  help | -h | --help) usage ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac

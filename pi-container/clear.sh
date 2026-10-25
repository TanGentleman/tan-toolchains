#!/usr/bin/env bash
# Back up sessions and reset pi-container state.
#
#   clear.sh list
#   clear.sh save [--instance NAME]
#   clear.sh nuke agent [--instance NAME] [--yes]
#   clear.sh nuke clones [--instance NAME | --legacy] [--yes]
#   clear.sh nuke all [--instance NAME] [--yes]
#   clear.sh help
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/names.sh"
cli="${CONTAINER_CLI:-container}"
pi_image="${PI_IMAGE:-pi-agent:local}"
proxy_name="pi-proxy"
proxy_image="${PI_PROXY_IMAGE:-pi-proxy:local}"
network="pi-locked"
cfg="${PI_CONFIG_DIR:-$HOME/.config/pi-container}"
backup_root="${PI_BACKUP_DIR:-$HOME/pi-backups}"
stamp=$(date +%Y%m%d-%H%M%S)

die() { printf 'clear.sh: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

instance=${PI_INSTANCE:-$pi_default_instance}
instance_explicit=0
args=()
while [ $# -gt 0 ]; do
  case $1 in
    --instance)
      [ $# -ge 2 ] || die '--instance needs a name'
      instance=$2
      instance_explicit=1
      shift 2
      ;;
    --instance=*)
      instance=${1#*=}
      instance_explicit=1
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ ${#args[@]} -eq 0 ]; then set --; else set -- "${args[@]}"; fi
pi_instance_valid "$instance" || die "invalid instance '$instance'"
agent_volume="${PI_AGENT_VOLUME:-$(pi_agent_volume "$instance")}"
settings_file=$(pi_settings_file "$cfg")

usage() {
  cat <<EOF
Back up sessions and reset pi-container state. Backups go to $backup_root.
save and nuke accept --instance NAME or PI_INSTANCE=NAME; the default is
'$pi_default_instance'. list always shows every instance. Settings at
$settings_file are shared by all instances.

  clear.sh list
      Show every instance, its agent volume, session size, and clone volumes.

  clear.sh save [--instance NAME]
      Save session JSONL files as $backup_root/sessions-<time>/.

  clear.sh nuke agent [--instance NAME] [--yes]
      Save sessions, then delete the selected instance's agent volume.

  clear.sh nuke clones [--instance NAME | --legacy] [--yes]
      Delete clone volumes for one instance by label. --legacy selects
      unlabelled pi-clone-* volumes left by older versions.

  clear.sh nuke all [--instance NAME] [--yes]
      Save sessions, then delete the selected instance's agent volume,
      $proxy_name, $network, $pi_image, $proxy_image, and the builder cache.
      Other agent volumes and all clone volumes stay. This command is
      machine-wide: it deletes shared proxy infrastructure used by every
      instance.

Host config stays at $cfg.
EOF
}

volume_exists() { "$cli" volume list -q 2>/dev/null | grep -qx "$1"; }
image_exists() { "$cli" image inspect "$1" >/dev/null 2>&1; }
container_exists() { "$cli" inspect "$1" >/dev/null 2>&1; }
network_exists() { "$cli" network list -q 2>/dev/null | grep -qx "$1"; }

require_cli() {
  command -v "$cli" >/dev/null 2>&1 && return 0
  die "'$cli' not found; install Apple container and run 'container system start'"
}

build_hint() {
  # The image compiles ../zigpeek, so the context is the repo root.
  printf '%s build -t %s -f %s/Dockerfile %s/..' "$cli" "$pi_image" "$here" "$here"
}

require_image() {
  image_exists "$pi_image" || die "missing image $pi_image; build it with: $(build_hint)"
}
require_agent_volume() { volume_exists "$agent_volume" || die "missing volume $agent_volume"; }

all_volumes() {
  "$cli" volume list -q 2>/dev/null || true
}

# Labels live on the volume, so no separate manifest can go stale.
volume_label() { # volume, key
  "$cli" volume inspect "$1" 2>/dev/null |
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

volume_kind() {
  local kind
  kind=$(volume_label "$1" pi.kind)
  if [ -n "$kind" ]; then
    printf '%s\n' "$kind"
    return
  fi
  case $1 in
    pi-agent-home|pi-agent-*) printf 'agent\n' ;;
    pi-clone-*|pi-clone_*) printf 'clone\n' ;;
  esac
}

volume_instance() {
  local inst rest
  inst=$(volume_label "$1" pi.instance)
  if [ -n "$inst" ]; then
    printf '%s\n' "$inst"
    return
  fi
  case $1 in
    pi-agent-home) printf '%s\n' "$pi_default_instance" ;;
    pi-agent-*) printf '%s\n' "${1#pi-agent-}" ;;
    pi-clone_*)
      rest=${1#pi-clone_}
      printf '%s\n' "${rest%%_*}"
      ;;
    *) printf 'legacy\n' ;;
  esac
}

agent_volumes() {
  local vol
  for vol in $(all_volumes); do
    [ "$(volume_kind "$vol")" = agent ] && printf '%s\n' "$vol"
  done
  return 0
}

clone_volumes() {
  local vol
  for vol in $(all_volumes); do
    [ "$(volume_kind "$vol")" = clone ] && printf '%s\n' "$vol"
  done
  return 0
}

scoped_clone_volumes() { # [legacy]
  local vol
  for vol in $(clone_volumes); do
    if [ "${1:-0}" = 1 ]; then
      [ -z "$(volume_label "$vol" pi.managed)" ] && printf '%s\n' "$vol"
    elif [ "$(volume_label "$vol" pi.instance)" = "$instance" ]; then
      printf '%s\n' "$vol"
    fi
  done
  return 0
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
  local vol=$1 dest=$2
  (umask 077; mkdir -p "$dest")
  if "$cli" run --rm -v "$vol:/agent:ro" "$pi_image" test -d /agent/sessions >/dev/null 2>&1; then
    "$cli" run --rm -v "$vol:/agent:ro" "$pi_image" tar -C /agent -cf - sessions |
      tar -C "$dest" -xf -
  else
    say "no sessions in $vol"
  fi
}

session_size() {
  local out=""
  if image_exists "$pi_image"; then
    out=$("$cli" run --rm -v "$1:/agent:ro" "$pi_image" \
      sh -c 'if [ -d /agent/sessions ]; then du -sh /agent/sessions | cut -f1; else echo -; fi' \
      2>/dev/null || true)
  fi
  printf '%s\n' "${out:--}"
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

cmd_list() {
  local vol inst size status repo
  [ $# -eq 0 ] || die "list takes no options"
  require_cli
  say "settings (shared): $settings_file"
  say ""
  printf '%-12s %-28s %-10s %-8s %s\n' INSTANCE AGENT-VOLUME SESSIONS STATUS SETTINGS
  for vol in $(agent_volumes); do
    inst=$(volume_instance "$vol")
    size=$(session_size "$vol")
    if [ -n "$(volume_label "$vol" pi.managed)" ]; then status=managed; else status=legacy; fi
    printf '%-12s %-28s %-10s %-8s %s\n' "$inst" "$vol" "$size" "$status" "$settings_file"
  done
  say ""
  printf '%-12s %-42s %-8s %s\n' INSTANCE CLONE-VOLUME STATUS REPO
  for vol in $(clone_volumes); do
    inst=$(volume_instance "$vol")
    repo=$(volume_label "$vol" pi.repo)
    [ -n "$repo" ] || repo=-
    if [ -n "$(volume_label "$vol" pi.managed)" ]; then status=managed; else status=legacy; fi
    printf '%-12s %-42s %-8s %s\n' "$inst" "$vol" "$status" "$repo"
  done
  say ""
  say "Use 'clear.sh nuke agent --instance NAME' or 'clear.sh nuke clones --instance NAME'."
}

cmd_save() {
  local dest
  [ $# -eq 0 ] || die "save takes no options"
  require_image
  require_agent_volume
  dest=$(new_backup_dir)
  save_sessions "$agent_volume" "$dest"
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
  save_sessions "$agent_volume" "$dest"
  say "saved: $dest"
  "$cli" volume delete "$agent_volume" || die "cannot delete $agent_volume; quit Pi first"
  say "deleted: $agent_volume"
}

cmd_nuke_clones() {
  local legacy=0 yes=0 vol vols
  while [ $# -gt 0 ]; do
    case $1 in
      --legacy) legacy=1; shift ;;
      --yes) yes=1; shift ;;
      *) die "unknown nuke clones option: $1" ;;
    esac
  done
  [ "$legacy" = 0 ] || [ "$instance_explicit" = 0 ] ||
    die "use either --instance or --legacy, not both"
  vols=$(scoped_clone_volumes "$legacy")
  [ -n "$vols" ] || { say "no matching clone volumes"; return; }
  say "clone volumes:"
  printf '  %s\n' $vols
  confirm "Delete these clone volumes? Unpushed work in them is lost."
  for vol in $vols; do
    "$cli" volume delete "$vol" || die "cannot delete $vol"
    say "deleted: $vol"
  done
}

cmd_nuke_all() {
  local dest yes=0 vol
  while [ $# -gt 0 ]; do
    case $1 in
      --yes) yes=1; shift ;;
      *) die "unknown nuke all option: $1" ;;
    esac
  done
  confirm "Delete $agent_volume, the shared proxy, network, images, and builder cache? Clone volumes and other agent volumes stay."

  if volume_exists "$agent_volume"; then
    require_image
    dest=$(new_backup_dir)
    save_sessions "$agent_volume" "$dest"
    say "saved: $dest"
    "$cli" volume delete "$agent_volume" || die "cannot delete $agent_volume; quit Pi first"
    say "deleted: $agent_volume"
  else
    say "no volume $agent_volume"
  fi

  for vol in $(agent_volumes); do
    say "kept: $vol (use nuke agent --instance $(volume_instance "$vol"))"
  done
  for vol in $(clone_volumes); do
    say "kept: $vol (use nuke clones --instance $(volume_instance "$vol"))"
  done

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
  say "rebuild the agent image before ./run.sh: $(build_hint)"
}

cmd_nuke() {
  local target=${1:-}
  shift || true
  case $target in
    agent) cmd_nuke_agent "$@" ;;
    clones) cmd_nuke_clones "$@" ;;
    all) cmd_nuke_all "$@" ;;
    *) die "nuke needs 'agent', 'clones', or 'all'" ;;
  esac
}

cmd=${1:-help}
shift || true
case $cmd in
  list) require_cli; cmd_list "$@" ;;
  save) require_cli; cmd_save "$@" ;;
  nuke) require_cli; cmd_nuke "$@" ;;
  help | -h | --help) usage ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac

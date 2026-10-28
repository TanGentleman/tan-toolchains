#!/usr/bin/env bash
# Back up sessions and reset pi-container state.
#
#   clear.sh list
#   clear.sh save [--instance NAME]
#   clear.sh nuke agent [--instance NAME] [--yes]
#   clear.sh nuke clones [--instance NAME] [--yes]
#   clear.sh nuke all [--instance NAME] [--yes]
#   clear.sh help
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/names.sh"
. "$here/images.sh"
. "$here/lib/inspect.sh"
. "$here/lib/lock.sh"
cli="${CONTAINER_CLI:-container}"
pi_image="${PI_IMAGE:-pi-agent:local}"
cfg="${PI_CONFIG_DIR:-$(pi_default_config_dir)}"
proxy_name="${PI_PROXY_NAME:-$(pi_proxy_name "$cfg")}"
proxy_image="${PI_PROXY_IMAGE:-$(pi_proxy_image "$cfg")}"
network_name="${PI_NETWORK_NAME:-$(pi_network_name "$cfg")}"
profile=$(pi_profile_label "$cfg")
settings_file="${PI_SETTINGS_FILE:-$(pi_settings_file "$cfg")}"
backup_root="${PI_BACKUP_DIR:-$HOME/pi-backups}"
lock_dir="$(pi_lock_dir)"
stamp=$(date +%Y%m%d-%H%M%S)

die() { printf 'clear.sh: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

instance=${PI_INSTANCE:-$pi_default_instance}
args=()
while [ $# -gt 0 ]; do
  case $1 in
    --instance)
      [ $# -ge 2 ] || die '--instance needs a name'
      instance=$2
      shift 2
      ;;
    --instance=*)
      instance=${1#*=}
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
set -- "${args[@]}"
pi_instance_valid "$instance" || die "invalid instance '$instance'"
agent_volume="${PI_AGENT_VOLUME:-$(pi_agent_volume "$instance" "$cfg")}"

usage() {
  cat <<EOF
Back up sessions and reset pi-container state. Backups go to $backup_root.
save and nuke accept --instance NAME or PI_INSTANCE=NAME; the default is
'$pi_default_instance'. list shows every profile and instance.

  clear.sh list
      Show every profile, its instances, agent volumes, session sizes, and
      clone volumes. Settings are shown for each profile.

  clear.sh save [--instance NAME]
      Save session JSONL files as $backup_root/sessions-<time>/.

  clear.sh nuke agent [--instance NAME] [--yes]
      Save sessions, then delete the selected instance's agent volume.

  clear.sh nuke clones [--instance NAME] [--yes]
      Delete the selected instance's clone volumes in this profile.

  clear.sh nuke all [--instance NAME] [--yes]
      Save sessions, then delete the selected instance's agent volume, this
      profile's proxy ($proxy_name) and network ($network_name), this profile's
      proxy image, the shared agent image, and the builder cache. Other
      profiles' proxy/network, other agent volumes, and all clone volumes stay.
      The agent image is global, so other profiles still need to rebuild it.

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

require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  die "jq not found; install it (brew install jq)"
}

# A command on PATH is not a running runtime. `volume list` proves it answered,
# because every list/nuke path reads volumes and an unanswered call would
# otherwise look like an empty result.
require_runtime() {
  "$cli" volume list -q >/dev/null 2>&1 && return 0
  die "'$cli' is not responding; start the container system with 'container system start'"
}

acquire_lock() { pi_acquire_lock "$lock_dir" clear.sh; }
release_lock() { pi_release_lock "$lock_dir"; }

build_hint() {
  # The image compiles ../zigpeek, so the context is the repo root.
  pi_build_hint "$cli" "$pi_image" "$here"
}

require_image() {
  if image_exists "$pi_image"; then return 0; fi
  # Image inspect fails both when the image is missing and when the container
  # system is not running. Mention both instead of claiming the image is absent.
  die "cannot inspect image $pi_image; start the container system with 'container system start' or build it with: $(build_hint)"
}
require_agent_volume() { volume_exists "$agent_volume" || die "missing volume $agent_volume"; }

all_volumes() {
  "$cli" volume list -q 2>/dev/null || true
}

# Labels live on the volume, so no separate manifest can go stale. The parser
# (including Apple's \/ escaping) lives in lib/inspect.sh and is unit-tested.
volume_label() { # volume, key
  "$cli" volume inspect "$1" 2>/dev/null | pi_volume_label_from_json "$2"
}

volume_kind() {
  volume_label "$1" pi.kind
}

volume_instance() {
  volume_label "$1" pi.instance
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

scoped_clone_volumes() {
  local vol
  for vol in $(clone_volumes); do
    [ "$(volume_label "$vol" pi.managed)" = true ] &&
      [ "$(volume_label "$vol" pi.profile)" = "$profile" ] &&
      [ "$(volume_label "$vol" pi.instance)" = "$instance" ] &&
      printf '%s\n' "$vol"
  done
  return 0
}

# Set yes=1 in the caller's scope when --yes is present.
parse_yes() {
  while [ $# -gt 0 ]; do
    case $1 in
      --yes) yes=1; shift ;;
      *) die "unknown nuke option: $1" ;;
    esac
  done
}

# Caller has already checked volume_exists and require_image.
backup_and_delete_agent_volume() { # volume
  local vol=$1 dest
  dest=$(new_backup_dir)
  save_sessions "$vol" "$dest"
  say "saved: $dest"
  "$cli" volume delete "$vol" || die "cannot delete $vol; quit Pi first"
  say "deleted: $vol"
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
    # Archive only regular session files. This keeps symlinks, device nodes, and
    # unrelated volume contents out of the host backup.
    "$cli" run --rm -v "$vol:/agent:ro" "$pi_image" sh -c '
      cd /agent || exit 1
      find sessions -type f -name "*.jsonl" -print0 | tar --null -T - -cf -
    ' | tar -C "$dest" --no-same-owner --no-same-permissions -xf -
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
  local vol inst size repo vol_profile config settings
  [ $# -eq 0 ] || die "list takes no options"
  require_cli
  say "current profile: $profile ($cfg)"
  say "settings (current profile): $settings_file"
  say ""
  printf '%-10s %-12s %-42s %-10s %s\n' PROFILE INSTANCE AGENT-VOLUME SESSIONS SETTINGS
  for vol in $(agent_volumes); do
    inst=$(volume_instance "$vol")
    vol_profile=$(volume_label "$vol" pi.profile)
    [ -n "$vol_profile" ] || vol_profile=-
    size=$(session_size "$vol")
    config=$(volume_label "$vol" pi.config)
    if [ "$config" = "$cfg" ]; then
      settings=$settings_file
    else
      settings=$(volume_label "$vol" pi.settings)
    fi
    if [ -z "$settings" ]; then
      if [ -n "$config" ]; then
        settings=$(pi_settings_file "$config")
      else
        settings=$settings_file
      fi
    fi
    printf '%-10s %-12s %-42s %-10s %s\n' "$vol_profile" "$inst" "$vol" "$size" "$settings"
  done
  say ""
  printf '%-10s %-12s %-42s %s\n' PROFILE INSTANCE CLONE-VOLUME REPO
  for vol in $(clone_volumes); do
    inst=$(volume_instance "$vol")
    vol_profile=$(volume_label "$vol" pi.profile)
    [ -n "$vol_profile" ] || vol_profile=-
    repo=$(volume_label "$vol" pi.repo)
    [ -n "$repo" ] || repo=-
    printf '%-10s %-12s %-42s %s\n' "$vol_profile" "$inst" "$vol" "$repo"
  done
  say ""
  say "Use 'clear.sh nuke agent --instance NAME' or 'clear.sh nuke clones --instance NAME'; set PI_CONFIG_DIR to manage another profile."
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
  local yes=0
  parse_yes "$@"
  volume_exists "$agent_volume" || { say "no volume $agent_volume"; return; }
  require_image
  confirm "Delete $agent_volume after saving its sessions?"
  backup_and_delete_agent_volume "$agent_volume"
}

cmd_nuke_clones() {
  local yes=0 vol vols
  parse_yes "$@"
  vols=$(scoped_clone_volumes)
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
  local yes=0 vol
  parse_yes "$@"
  confirm "Delete $agent_volume, proxy $proxy_name, network $network_name, this profile's proxy image, the shared agent image, and builder cache? Other profiles' proxy/network, clone volumes, and other agent volumes stay; other profiles will need an agent image rebuild."

  if volume_exists "$agent_volume"; then
    require_image
    backup_and_delete_agent_volume "$agent_volume"
  else
    say "no volume $agent_volume"
  fi

  for vol in $(agent_volumes); do
    say "kept: $vol (profile $(volume_label "$vol" pi.profile); use nuke agent --instance $(volume_instance "$vol") with PI_CONFIG_DIR=$(volume_label "$vol" pi.config))"
  done
  for vol in $(clone_volumes); do
    say "kept: $vol (profile $(volume_label "$vol" pi.profile); use nuke clones --instance $(volume_instance "$vol") with PI_CONFIG_DIR=$(volume_label "$vol" pi.config))"
  done

  if container_exists "$proxy_name"; then
    "$cli" delete --force "$proxy_name" >/dev/null 2>&1 || die "cannot delete $proxy_name"
    say "deleted: $proxy_name"
  else
    say "no container: $proxy_name"
  fi

  if network_exists "$network_name"; then
    "$cli" network delete "$network_name" >/dev/null 2>&1 || die "cannot delete $network_name"
    say "deleted: $network_name"
  else
    say "no network: $network_name"
  fi

  for img in "$pi_image" "$proxy_image"; do
    if image_exists "$img"; then
      "$cli" image delete "$img" >/dev/null 2>&1 || die "cannot delete $img"
      say "deleted: $img"
    else
      say "no image: $img"
    fi
  done

  if "$cli" builder delete --force >/dev/null 2>&1; then
    say "deleted: builder cache"
  else
    say "builder cache: delete failed (continuing)"
  fi
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
trap release_lock EXIT
case $cmd in
  list) require_cli; require_jq; require_runtime; cmd_list "$@" ;;
  save) require_cli; acquire_lock; cmd_save "$@" ;;
  nuke) require_cli; require_jq; acquire_lock; cmd_nuke "$@" ;;
  help | -h | --help) usage ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac

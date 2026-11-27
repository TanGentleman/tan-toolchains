# Shared instance and volume naming for run.sh and clear.sh.
#
# An instance isolates Pi's agent volume within a profile. A profile is a
# PI_CONFIG_DIR: the default profile keeps the original names, while another
# config directory gets its own proxy, network, subnet, agent volumes, and
# clone volumes. The agent image and builder cache stay shared; each profile has
# its own proxy image.

pi_default_instance=default

# Everything pi-container and fleetd write lives below one root: the default
# profile in config/, other profiles in profiles/<name>, clear.sh backups in
# backups/, fleetd data in fleet/, the lock, and overrides.env.
pi_pic_home() {
  local h=${PIC_HOME:-${HOME%/}/.pic}
  printf '%s\n' "${h%/}"
}

pi_default_config_dir() {
  printf '%s/config\n' "$(pi_pic_home)"
}

pi_backup_dir() {
  printf '%s/backups\n' "$(pi_pic_home)"
}

pi_fleet_dir() {
  printf '%s/fleet\n' "$(pi_pic_home)"
}

# One lock serializes proxy/image/network changes across profiles because the
# agent image and builder cache are machine-wide. Profiles under another
# PIC_HOME use that root's lock.
pi_lock_dir() {
  printf '%s/lock\n' "$(pi_pic_home)"
}

# Lowercase letters, digits, and hyphens. "home" is reserved because the
# default instance keeps the original pi-agent-home volume name.
pi_instance_valid() {
  local name=${1:-}
  case $name in
    default) return 0 ;;
    home) return 1 ;;
  esac
  [[ $name =~ ^[a-z0-9][a-z0-9-]{0,23}$ ]]
}

# Empty for the default profile, otherwise an 8-character path hash. Only
# ~/.pic/config is the default: another PIC_HOME's config gets its own names.
pi_profile_id() { # cfg
  local cfg=${1%/}
  [ "$cfg" = "${HOME%/}/.pic/config" ] && return 0
  printf '%s\n' "$(printf '%s' "$cfg" | pi_sha256 | cut -c1-8)"
}

pi_profile_label() { # cfg
  local id
  id=$(pi_profile_id "$1")
  printf '%s\n' "${id:-default}"
}

pi_proxy_name() { # cfg
  local id
  id=$(pi_profile_id "$1")
  printf 'pi-proxy%s\n' "${id:+-$id}"
}

pi_network_name() { # cfg
  local id
  id=$(pi_profile_id "$1")
  printf 'pi-locked%s\n' "${id:+-$id}"
}

pi_proxy_image() { # cfg
  local id
  id=$(pi_profile_id "$1")
  printf 'pi-proxy%s:local\n' "${id:+-$id}"
}

pi_locked_subnet() { # cfg
  local id hash octet
  id=$(pi_profile_id "$1")
  if [ -z "$id" ]; then
    printf '172.30.240.0/24\n'
    return 0
  fi
  hash=$(printf '%s' "${1%/}" | pi_sha256 | cut -c1-8)
  octet=$((16#${hash:0:2}))
  octet=$((octet % 239 + 1))
  printf '172.30.%d.0/24\n' "$octet"
}

pi_agent_volume() { # instance, [cfg]
  local instance=$1 cfg=${2:-$(pi_default_config_dir)} id
  id=$(pi_profile_id "$cfg")
  if [ -n "$id" ]; then
    case $instance in
      default) printf 'pi-agent-%s-home\n' "$id" ;;
      *) printf 'pi-agent-%s-%s\n' "$id" "$instance" ;;
    esac
    return 0
  fi
  case $instance in
    default) printf 'pi-agent-home\n' ;;
    *) printf 'pi-agent-%s\n' "$instance" ;;
  esac
}

# One settings file is shared by every instance in a profile.
pi_settings_file() {
  printf '%s/settings.json\n' "$1"
}

pi_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
  else
    sha256sum "$@"
  fi
}

# The underscore keeps generated names unambiguous. The profile id is present
# only for non-default config directories.
pi_clone_volume() { # instance, owner/repo, [cfg]
  local instance=$1 repo=$2 cfg=${3:-$(pi_default_config_dir)} id slug hash
  id=$(pi_profile_id "$cfg")
  slug=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | cut -c1-40)
  hash=$(printf '%s' "$repo" | pi_sha256 | cut -c1-8)
  if [ -n "$id" ]; then
    printf 'pi-clone_%s_%s_%s-%s\n' "$id" "$instance" "$slug" "$hash"
  else
    printf 'pi-clone_%s_%s-%s\n' "$instance" "$slug" "$hash"
  fi
}

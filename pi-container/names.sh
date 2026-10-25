# Shared instance and volume naming for run.sh and clear.sh.
#
# An instance isolates Pi's agent volume only. The settings file, proxy,
# network, port, and OpenRouter key stay shared.

pi_default_instance=default

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

pi_agent_volume() {
  case $1 in
    default) printf 'pi-agent-home\n' ;;
    *) printf 'pi-agent-%s\n' "$1" ;;
  esac
}

# One settings file is shared by every instance.
pi_settings_file() {
  printf '%s/settings.json\n' "$1"
}

pi_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  else
    sha256sum
  fi
}

# New clone volumes use an underscore after pi-clone so they cannot collide
# with legacy pi-clone-<slug>-<hash> volumes, which only use letters, digits,
# and hyphens.
pi_clone_volume() { # instance, owner/repo
  local instance=$1 repo=$2 slug hash
  slug=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | cut -c1-40)
  hash=$(printf '%s' "$repo" | pi_sha256 | cut -c1-8)
  printf 'pi-clone_%s_%s-%s\n' "$instance" "$slug" "$hash"
}

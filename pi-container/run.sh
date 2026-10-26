#!/usr/bin/env bash
# Run Pi inside Apple's container, on a host-only network.
#   run.sh [--instance NAME]                Pi on the current folder (trusted repos only)
#   run.sh [--instance NAME] --clone O/R    Pi on a clone kept in a volume
#   run.sh [--instance NAME] [--clone O/R] --manual [CMD]
#                                              shell without Pi or proxy
#   run.sh [--instance NAME] check [O/R]    keys, GitHub, and the network lock
#   run.sh proxy                            follow the proxy container's logs
#   run.sh proxy-stop                       stop the proxy container
#   run.sh --help                           show this text
#   PI_INSTANCE=NAME                        default for --instance
#   PI_CLONE=O/R                            default for --clone
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/names.sh"
. "$here/lib/paths.sh"
. "$here/lib/inspect.sh"
. "$here/lib/validate.sh"
. "$here/lib/lock.sh"
cfg="${PI_CONFIG_DIR:-$(pi_default_config_dir)}"
env_file="${PI_ENV_FILE:-$cfg/env}"
settings_file="${PI_SETTINGS_FILE:-$cfg/settings.json}"
nvim_config="${PI_NVIM_CONFIG:-$cfg/nvim}"
nvim_data="${PI_NVIM_DATA:-$cfg/nvim-data}"
nvim_state="${PI_NVIM_STATE:-$cfg/nvim-state}"
nvim_cache="${PI_NVIM_CACHE:-$cfg/nvim-cache}"
ca_file="$cfg/certs/ca.pem"
proxy_env="$cfg/private/proxy.env"
port="${PI_PROXY_PORT:-8888}"
placeholder="sk-or-v1-placeholder"
cli="${CONTAINER_CLI:-container}"
proxy_name="${PI_PROXY_NAME:-$(pi_proxy_name "$cfg")}"
network_name="${PI_NETWORK_NAME:-$(pi_network_name "$cfg")}"
locked_subnet="${PI_LOCKED_SUBNET:-$(pi_locked_subnet "$cfg")}"
proxy_image="${PI_PROXY_IMAGE:-$(pi_proxy_image "$cfg")}"
lock_dir="$(pi_lock_dir)"

usage() {
  cat <<'EOF'
Run Pi inside Apple's container, on a host-only network.
  run.sh [--instance NAME]                Pi on the current folder (trusted repos only)
  run.sh [--instance NAME] --clone O/R    Pi on a clone kept in a volume
  run.sh [--instance NAME] [--clone O/R] --manual [CMD]
                                             shell without Pi or proxy
  run.sh [--instance NAME] check [O/R]    keys, GitHub, and the network lock
  run.sh proxy                            follow the proxy container's logs
  run.sh proxy-stop                       stop the proxy container
  run.sh --help                           show this text
  PI_INSTANCE=NAME                        default for --instance
  PI_CLONE=O/R                            default for --clone
EOF
}

instance=${PI_INSTANCE:-$pi_default_instance}
manual=0
clone="${PI_CLONE:-}"
while [ $# -gt 0 ]; do
  case $1 in
    --instance)
      [ $# -ge 2 ] || { echo "run.sh: --instance needs a name" >&2; exit 2; }
      instance=$2
      shift 2
      ;;
    --instance=*)
      instance=${1#*=}
      shift
      ;;
    --manual)
      manual=1
      shift
      ;;
    --clone)
      [ $# -ge 2 ] || { echo "run.sh: --clone needs OWNER/REPO" >&2; exit 2; }
      clone=$2
      shift 2
      ;;
    --clone=*)
      clone=${1#*=}
      shift
      ;;
    *) break ;;
  esac
done
case "${1:-}" in
  --help|-h|help) usage; exit 0 ;;
  -*) echo "run.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
esac
if ! pi_instance_valid "$instance"; then
  echo "run.sh: invalid instance '$instance'; use lowercase letters, digits, and hyphens (max 24; not 'home')" >&2
  exit 2
fi
agent_volume="${PI_AGENT_VOLUME:-$(pi_agent_volume "$instance" "$cfg")}"
if [ -n "$clone" ]; then
  clone=$(pi_repo_normalize "$clone")
  if ! pi_repo_valid "$clone"; then
    echo "run.sh: bad repo '$clone'" >&2
    exit 2
  fi
fi

if ! pi_port_valid "$port"; then
  case $port in
    ''|*[!0-9]*) echo "run.sh: PI_PROXY_PORT must be a number" >&2 ;;
    *) echo "run.sh: PI_PROXY_PORT must be between 1 and 65535" >&2 ;;
  esac
  exit 2
fi

# Path and permission helpers live in lib/paths.sh so the mount guard can be
# tested without a container runtime.

require_cli() {
  command -v "$cli" >/dev/null 2>&1 && return 0
  echo "run.sh: '$cli' not found; install Apple container and run 'container system start' (see README)" >&2
  exit 1
}

require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "run.sh: jq not found; install it (brew install jq)" >&2
  exit 1
}

require_agent_image() {
  local image=${PI_IMAGE:-pi-agent:local}
  "$cli" image inspect "$image" >/dev/null 2>&1 && return 0
  # Image inspect fails both when the image is missing and when the container
  # system is not running. Mention both instead of claiming the image is absent.
  echo "run.sh: cannot inspect image $image" >&2
  echo "run.sh: if 'container system start' has not run yet, start it first" >&2
  echo "run.sh: otherwise build it from the repo root context, because the image compiles ../zigpeek:" >&2
  echo "  $cli build -t $image -f $here/Dockerfile $here/.." >&2
  exit 1
}

volume_exists() { "$cli" volume list -q 2>/dev/null | grep -qx "$1"; }

# Create volumes explicitly so they carry the labels clear.sh uses for scoping.
# `container run -v name:/path` would create them without labels.
ensure_volume() { # name, kind, [repo]
  local name=$1 kind=$2 repo=${3:-} profile
  volume_exists "$name" && return 0
  profile=$(pi_profile_label "$cfg")
  local labels=(--label pi.managed=true --label "pi.profile=$profile"
    --label "pi.config=$cfg" --label "pi.settings=$settings_file"
    --label "pi.instance=$instance" --label "pi.kind=$kind")
  [ -z "$repo" ] || labels+=(--label "pi.repo=$repo")
  if ! "$cli" volume create "${labels[@]}" "$name" >/dev/null 2>&1; then
    volume_exists "$name" && return 0
    echo "run.sh: cannot create volume $name" >&2
    exit 1
  fi
}

clone_boot_script() {
  cat <<'EOF'
d="/work/${PI_CLONE#*/}"
if [ -e "$d" ] && [ ! -d "$d/.git" ]; then
  echo "run.sh: $d exists but is not a git clone; delete the clone volume and retry" >&2
  exit 1
fi
[ -d "$d/.git" ] || git clone "https://github.com/$PI_CLONE.git" "$d" || exit 1
cd "$d" && exec "$@"
EOF
}

acquire_host_lock() { pi_acquire_lock "$lock_dir" run.sh; }
release_host_lock() { pi_release_lock "$lock_dir"; }

require_env() {
  [ -f "$env_file" ] || { echo "run.sh: missing $env_file (see README)" >&2; exit 1; }
  [ -r "$env_file" ] || { echo "run.sh: cannot read $env_file" >&2; exit 1; }
  case $(pi_file_mode "$env_file") in
    600|400) ;;
    *) echo "run.sh: $env_file must be mode 600 (chmod 600)" >&2; exit 1 ;;
  esac
  if ! grep -q '^OPENROUTER_API_KEY=.' "$env_file" || ! grep -q '^GITHUB_TOKEN=.' "$env_file"; then
    echo "run.sh: set OPENROUTER_API_KEY and GITHUB_TOKEN in $env_file" >&2
    exit 1
  fi
  if grep -q '^OPENROUTER_API_KEY=sk-or-v1-placeholder[[:space:]]*$' "$env_file"; then
    echo "run.sh: OPENROUTER_API_KEY is still the placeholder" >&2
    exit 1
  fi
}

# Refuse a project directory that contains the current config, the default
# config (which holds the global lock), the env file, or either config's
# parent. Used for project mounts.
refuse_config_overlap() { # $1 project dir, physical
  local cfg_phys env_phys default_phys settings_phys
  cfg_phys=$(pi_physical_path "$cfg")
  env_phys=$(pi_physical_path "$env_file")
  default_phys=$(pi_physical_path "$(pi_default_config_dir)")
  settings_phys=$(pi_physical_path "$settings_file")
  if pi_path_within "$1" "$cfg_phys" || pi_path_within "$cfg_phys" "$1" || \
     pi_path_within "$1" "$default_phys" || pi_path_within "$default_phys" "$1" || \
     pi_path_within "$1" "$env_phys" || pi_path_within "$1" "$settings_phys" || \
     pi_path_within "$settings_phys" "$1"; then
    echo "run.sh: $1 must not overlap $cfg, $(pi_default_config_dir), $env_file, or $settings_file" >&2
    exit 1
  fi
}

ensure_network() {
  local names inspect
  names=$("$cli" network list -q) || { echo "run.sh: container network list failed" >&2; exit 1; }
  if printf '%s\n' "$names" | grep -qx "$network_name"; then
    if ! inspect=$("$cli" network inspect "$network_name" 2>/dev/null); then
      echo "run.sh: cannot inspect $network_name; refusing to assume it is host-only" >&2
      exit 1
    fi
    # The JSON details (subnet fields, hostOnly mode, old slash escaping) live
    # in lib/inspect.sh and are pinned by fixtures; keep only the messages here.
    case $(printf '%s\n' "$inspect" | pi_network_host_only_verdict) in
      ok) ;;
      not-host-only)
        echo "run.sh: $network_name is not in host-only mode; delete it first" >&2
        exit 1
        ;;
      *)
        echo "run.sh: cannot verify that $network_name is host-only; delete it and retry" >&2
        exit 1
        ;;
    esac
    if ! printf '%s\n' "$inspect" | pi_network_has_subnet "$locked_subnet"; then
      echo "run.sh: $network_name does not use $locked_subnet; delete it or set PI_LOCKED_SUBNET to match" >&2
      exit 1
    fi
    return
  fi
  "$cli" network create --internal "$network_name" --subnet "$locked_subnet"
}

# A file keeps the key out of `container inspect pi-proxy`.
write_proxy_env() {
  local old_umask tmp
  mkdir -p "$cfg/private"
  chmod 700 "$cfg/private"
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "${proxy_env}.XXXXXX")
  umask "$old_umask"
  grep '^OPENROUTER_API_KEY=' "$env_file" | tail -n 1 | tr -d '\r' > "$tmp" || true
  if ! grep -q '^OPENROUTER_API_KEY=.' "$tmp"; then
    rm -f "$tmp"
    echo "run.sh: OPENROUTER_API_KEY is empty" >&2
    exit 1
  fi
  if grep -q '^OPENROUTER_API_KEY=sk-or-v1-placeholder[[:space:]]*$' "$tmp"; then
    rm -f "$tmp"
    echo "run.sh: OPENROUTER_API_KEY is still the placeholder" >&2
    exit 1
  fi
  if [ -f "$proxy_env" ] && cmp -s "$tmp" "$proxy_env"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$proxy_env"
  fi
  chmod 600 "$proxy_env"
  rm -f "$cfg/proxy.env" # old location
}

# Pi gets only the GitHub token and commit identity.
write_pi_env() {
  local old_umask tmp
  mkdir -p "$cfg"
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "${cfg}/pi.env.XXXXXX")
  umask "$old_umask"
  : > "$tmp"
  for name in GITHUB_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
    line=$(grep "^${name}=" "$env_file" | tail -n 1 | tr -d '\r' || true)
    value=${line#*=}
    [ -n "$value" ] && printf '%s\n' "$line" >> "$tmp"
  done
  if ! grep -q '^GITHUB_TOKEN=.' "$tmp"; then
    rm -f "$tmp"
    echo "run.sh: GITHUB_TOKEN is empty" >&2
    exit 1
  fi
  if [ -f "$cfg/pi.env" ] && cmp -s "$tmp" "$cfg/pi.env"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$cfg/pi.env"
  fi
  chmod 600 "$cfg/pi.env"
}

ensure_nvim_mounts() {
  mkdir -p "$nvim_config" "$nvim_data" "$nvim_state" "$nvim_cache"
  if [ ! -e "$nvim_config/init.lua" ] && [ ! -L "$nvim_config/init.lua" ] \
     && [ ! -e "$nvim_config/init.vim" ] && [ ! -L "$nvim_config/init.vim" ]; then
    cp "$here/nvim/init.lua" "$nvim_config/init.lua"
  fi
}

# Read the Pi version recorded at image build time. The sources and precedence
# live in lib/inspect.sh and are pinned by fixtures.
image_pi_version() {
  local image=${PI_IMAGE:-pi-agent:local} json
  json=$("$cli" image inspect "$image" 2>/dev/null) || return 1
  printf '%s\n' "$json" | pi_image_version_from_json
}

# Pi reads this file directly; edits on the Mac apply on the next launch.
# The file is mounted read-only, so Pi cannot change settings, packages, or
# resource paths. Seed lastChangelogVersion so Pi does not try to write it.
ensure_settings() {
  local pi_version
  mkdir -p "$(dirname "$settings_file")"
  [ -f "$settings_file" ] && return
  pi_version=$(image_pi_version || true)
  if [ -z "$pi_version" ]; then
    pi_version=$(sed -n 's/^ARG PI_VERSION=\(.*\)$/\1/p' "$here/Dockerfile" | head -n 1)
  fi
  [ -n "$pi_version" ] || { echo "run.sh: cannot determine the Pi version for $settings_file" >&2; exit 1; }
  (
    umask 077
    cat > "$settings_file" <<EOF
{
  "\$schema": "https://pi.dev/schemas/settings.schema.json",
  "lastChangelogVersion": "$pi_version",
  "defaultProvider": "openrouter",
  "defaultModel": "deepseek/deepseek-v4.1-flash-1017"
}
EOF
  )
}

# Refuse project mounts that expose secrets.
guard_mount() {
  local pwd_phys home_phys secret
  pwd_phys=$(pi_physical_dir "$PWD") || { echo "run.sh: cannot resolve $PWD" >&2; exit 1; }
  refuse_config_overlap "$pwd_phys"
  home_phys=$(pi_physical_dir "$HOME") || home_phys=$HOME
  if [ "$pwd_phys" = / ] || pi_path_within "$pwd_phys" "$home_phys"; then
    echo "run.sh: refusing to mount $pwd_phys; choose a project below $home_phys" >&2
    exit 1
  fi
  for secret in .ssh .aws .gnupg .kube Library/Keychains; do
    if pi_path_within "$home_phys/$secret" "$pwd_phys" || pi_path_within "$pwd_phys" "$home_phys/$secret"; then
      echo "run.sh: refusing to mount $pwd_phys; it overlaps secrets at $home_phys/$secret" >&2
      exit 1
    fi
  done
}

addr_file() { printf '%s\n' "$cfg/private/proxy.addr"; }

# Read the proxy container's state. The shape handling lives in lib/inspect.sh.
# Return "absent" only when inspect itself failed; an existing container whose
# state we cannot parse is "unknown" and must be recreated, not reused.
proxy_state() {
  local json state
  if ! json=$("$cli" inspect "$proxy_name" 2>/dev/null); then
    printf 'absent\n'
    return 0
  fi
  state=$(printf '%s\n' "$json" | pi_proxy_state_from_json)
  printf '%s\n' "${state:-unknown}"
}

valid_ip() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  [ "$ip" != 0.0.0.0 ] || return 1
  [ "$ip" != 255.255.255.255 ] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    ((10#$o <= 255)) || return 1
  done
}

hash_files() {
  pi_sha256 "$@" | pi_sha256 | awk '{print $1}'
}

add_zig_cache_args() { # project path
  local source=$1 key
  key=$(printf '%s' "$source" | pi_sha256 | cut -c1-16)
  args+=(-e "ZIG_GLOBAL_CACHE_DIR=/root/.cache/zig"
    -e "ZIG_LOCAL_CACHE_DIR=/root/.cache/zig-local/$key")
}

ensure_proxy() {
  local stamp image_hash config_hash old_image old_config image_stale config_stale state
  mkdir -p "$cfg/certs" "$cfg/private"
  chmod 700 "$cfg/private"
  write_proxy_env
  stamp="$cfg/proxy.stamp"
  image_hash=$(hash_files "$here/proxy.py" "$here/Dockerfile.proxy")
  config_hash=$( { cat "$proxy_env" 2>/dev/null || true; printf '%s\n' "$port" "$locked_subnet" "$network_name" "$proxy_image"; } | pi_sha256 | awk '{print $1}' )
  old_image=""
  old_config=""
  if [ -f "$stamp" ]; then read -r old_image old_config < "$stamp" || true; fi
  image_stale=0
  config_stale=0
  [ "$old_image" = "$image_hash" ] || image_stale=1
  [ "$old_config" = "$config_hash" ] || config_stale=1
  if ! "$cli" image inspect "$proxy_image" >/dev/null 2>&1; then
    image_stale=1
  fi
  if [ "$image_stale" = 1 ] || [ "$config_stale" = 1 ]; then
    "$cli" delete --force "$proxy_name" >/dev/null 2>&1 || true
    if [ "$image_stale" = 1 ]; then
      "$cli" build -t "$proxy_image" -f "$here/Dockerfile.proxy" "$here"
    fi
    printf '%s %s\n' "$image_hash" "$config_hash" > "$stamp"
  fi
  state=$(proxy_state || true)
  case "$state" in
    running) return ;;
    stopped|stopping)
      rm -f "$(addr_file)"
      "$cli" start "$proxy_name"
      return ;;
    absent)
      ;;
    *)
      # Unknown/unparseable state: recreate to avoid a name collision.
      "$cli" delete --force "$proxy_name" >/dev/null 2>&1 || true
      ;;
  esac
  # Drop a stale address; proxy.py publishes only after binding.
  rm -f "$(addr_file)"
  "$cli" run -d --name "$proxy_name" --init \
    --cpus 1 --memory 1G \
    --network default --network "$network_name" \
    -e "PI_PROXY_PORT=$port" \
    -e "PI_PROXY_LOCKED_CIDR=$locked_subnet" \
    -e PI_ENV_FILE=/private/proxy.env \
    -v "$cfg/private:/private" -v "$cfg/certs:/certs" \
    "$proxy_image" >/dev/null
}

# Ask from inside pi-proxy, the same path Pi uses.
proxy_answers() {
  "$cli" exec "$proxy_name" /usr/local/bin/python3 -c \
    'import sys,urllib.request
ip, port = sys.argv[1], sys.argv[2]
body = urllib.request.urlopen("http://%s:%s/health" % (ip, port), timeout=2).read()
raise SystemExit(0 if body == b"pi-container-proxy\n" else 1)' \
    "$1" "$port"
}

proxy_ip() {
  local file ip i tries
  file=$(addr_file)
  ip=""
  i=0
  tries="${PI_PROXY_WAIT:-90}"
  case $tries in ''|*[!0-9]*) tries=90 ;; esac
  while [ "$i" -lt "$tries" ]; do
    if [ -f "$file" ]; then
      ip=$(tr -d '[:space:]' < "$file" || true)
      if valid_ip "$ip" && proxy_answers "$ip" >/dev/null 2>&1; then
        printf '%s\n' "$ip"
        return
      fi
    fi
    i=$((i + 1))
    sleep 1
  done
  if valid_ip "${ip:-}"; then
    echo "run.sh: $proxy_name is listening on ${ip}:${port} but did not answer from inside the container. Run: $cli logs $proxy_name" >&2
  else
    echo "run.sh: $proxy_name did not report an address. Run: $cli logs $proxy_name" >&2
  fi
  exit 1
}

# Tests source this file without starting containers.
if [ "${PI_SOURCE_ONLY:-}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

require_cli
trap release_host_lock EXIT

if [ "${1:-}" = proxy-stop ]; then
  acquire_host_lock
  "$cli" stop "$proxy_name" >/dev/null 2>&1 || true
  release_host_lock
  exit 0
fi

# Runs before the clone boot script in normal mode and, when pi.env is
# available, in manual clone mode. Keep GIT_AUTHOR_* sufficient for both
# identities so the documented env file works for commits.
read -r -d '' prep <<'EOF' || true
if [ -n "${HTTPS_PROXY:-}" ]; then
  git config --global http.proxy "$HTTPS_PROXY"
  git config --global https.proxy "$HTTPS_PROXY"
fi
name="${GIT_AUTHOR_NAME:-${GIT_COMMITTER_NAME:-}}"
email="${GIT_AUTHOR_EMAIL:-${GIT_COMMITTER_EMAIL:-}}"
[ -z "$name" ] || git config --global user.name "$name"
[ -z "$email" ] || git config --global user.email "$email"
exec "$@"
EOF

if [ "$manual" = 1 ]; then
  [ -n "$clone" ] || guard_mount
  acquire_host_lock
  require_agent_image
  ensure_nvim_mounts
  [ $# -gt 0 ] || set -- bash
  args=(run --rm -i --init --network default
    --cpus "${PI_CPUS:-4}" --memory "${PI_MEMORY:-4G}"
    -e "TERM=${TERM:-xterm-256color}"
    -e LANG=C.UTF-8 -e LC_ALL=C.UTF-8
    -v "$nvim_config:/root/.config/nvim"
    -v "$nvim_data:/root/.local/share/nvim"
    -v "$nvim_state:/root/.local/state/nvim"
    -v "$nvim_cache:/root/.cache/nvim")
  if [ -n "$clone" ]; then
    clone_vol=$(pi_clone_volume "$instance" "$clone" "$cfg")
    ensure_volume "$clone_vol" clone "$clone"
    echo "run.sh: clone volume: $clone_vol" >&2
    boot=$(clone_boot_script)
    args+=(-v "$clone_vol:/work" -w /work -e "PI_CLONE=$clone")
    manual_pi_env=0
    if [ -f "$cfg/pi.env" ]; then
      manual_pi_env=1
      args+=(--env-file "$cfg/pi.env")
    fi
    set -- bash -c "$boot" boot "$@"
    if [ "$manual_pi_env" = 1 ]; then
      set -- bash -c "$prep" prep "$@"
    fi
  else
    args+=(-v "$PWD:$PWD" -w "$PWD")
  fi
  # Project mounts can be slow; keep Zig's local cache in the container and use
  # the image's prewarmed global cache.
  if [ -n "$clone" ]; then
    add_zig_cache_args "/work/${clone#*/}"
  else
    add_zig_cache_args "$PWD"
  fi
  if [ -n "${TZ:-}" ]; then args+=(-e "TZ=$TZ"); fi
  if [ -n "${COLORTERM:-}" ]; then args+=(-e "COLORTERM=$COLORTERM"); fi
  if [ -t 0 ] && [ -t 1 ]; then args+=(-t); fi
  release_host_lock
  exec "$cli" "${args[@]}" "${PI_IMAGE:-pi-agent:local}" "$@"
fi

require_jq

case "${1:-}" in
  check|proxy) ;;
  *) if [ -n "$clone" ]; then :; else guard_mount; fi ;;
esac
require_env
if [ "${1:-}" != proxy ]; then require_agent_image; fi
acquire_host_lock
write_pi_env
ensure_settings
if [ "${PI_SKIP_HOST_SETUP:-}" = 1 ]; then
  proxy_ip_value="${PI_SKIP_PROXY_IP:-${locked_subnet%/*}}"
  proxy_ip_value="${proxy_ip_value%.*}.2"
else
  ensure_network
  ensure_proxy
  if [ "${1:-}" = proxy ]; then
    release_host_lock
    exec "$cli" logs -f "$proxy_name"
  fi
  proxy_ip_value=$(proxy_ip)
fi
release_host_lock
proxy_url="http://${proxy_ip_value}:${port}"
if [ "${1:-}" != proxy ]; then ensure_volume "$agent_volume" agent; fi
[ -f "$ca_file" ] || { echo "run.sh: missing $ca_file; start the proxy or unset PI_SKIP_HOST_SETUP" >&2; exit 1; }

args=(run --rm -i --init --network "$network_name"
  --env-file "$cfg/pi.env"
  --cpus "${PI_CPUS:-4}" --memory "${PI_MEMORY:-4G}"
  -e "TERM=${TERM:-xterm-256color}"
  -e LANG=C.UTF-8 -e LC_ALL=C.UTF-8
  -e "OPENROUTER_API_KEY=${placeholder}"
  -e PI_TELEMETRY=0 -e GH_TELEMETRY=0
  -e PI_CODING_AGENT_DIR=/root/.pi/agent
  -e "HTTP_PROXY=${proxy_url}" -e "HTTPS_PROXY=${proxy_url}"
  -e "http_proxy=${proxy_url}" -e "https_proxy=${proxy_url}"
  -e NO_PROXY=localhost,127.0.0.1,::1 -e no_proxy=localhost,127.0.0.1,::1
  -e NODE_EXTRA_CA_CERTS=/etc/pi-proxy-ca/ca.pem
  -e SSL_CERT_FILE=/etc/pi-proxy-ca/ca.pem
  -e CURL_CA_BUNDLE=/etc/pi-proxy-ca/ca.pem
  -e REQUESTS_CA_BUNDLE=/etc/pi-proxy-ca/ca.pem
  -v "$ca_file:/etc/pi-proxy-ca/ca.pem:ro"
  -v "$agent_volume:/root/.pi/agent"
  -v "$settings_file:/root/.pi/agent/settings.json:ro")
if [ -n "$clone" ]; then
  add_zig_cache_args "/work/${clone#*/}"
else
  add_zig_cache_args "$PWD"
fi
if [ -n "${TZ:-}" ]; then args+=(-e "TZ=$TZ"); fi
if [ -n "${COLORTERM:-}" ]; then args+=(-e "COLORTERM=$COLORTERM"); fi
if [ -t 0 ] && [ -t 1 ]; then args+=(-t); fi

[ $# -gt 0 ] || set -- pi

if [ "$1" = check ]; then
  check_repo=${2:-$clone}
  case $check_repo in
    *.git) check_repo=${check_repo%.git} ;;
  esac
  read -r -d '' script <<'EOF' || true
s=0
echo "== OpenRouter key"
if [ "$OPENROUTER_API_KEY" = "sk-or-v1-placeholder" ]; then echo "Pi has the placeholder"
else echo "FAIL: the real OpenRouter key is in the Pi container"; s=1; fi
echo "== settings"
if [ -f /root/.pi/agent/settings.json ]; then
  want=$(sed -n 's/.*"lastChangelogVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /root/.pi/agent/settings.json | head -n 1)
  have=$(pi --version 2>/dev/null || true)
  if [ -z "$want" ]; then
    echo "WARN: settings.json has no lastChangelogVersion"
  elif [ "$want" != "$have" ]; then
    echo "WARN: settings lastChangelogVersion=$want but pi is ${have:-unknown}; update the host settings file"
  else
    echo "settings lastChangelogVersion is current"
  fi
else
  echo "WARN: settings.json is not mounted"
fi
echo "== OpenRouter"
if r=$(curl -fsS -m 20 --cacert /etc/pi-proxy-ca/ca.pem https://openrouter.ai/api/v1/key); then
  printf '%s\n' "$r" | jq '.data | {label: .label, limit: .limit, remaining: .limit_remaining, usage: .usage}' || s=1
  limit=$(printf '%s\n' "$r" | jq -r '.data.limit // "null"' 2>/dev/null || echo null)
  if [ "$limit" = null ]; then echo "WARN: the OpenRouter key has no credit limit"; fi
else
  echo "FAIL: OpenRouter. See: run.sh proxy"
  s=1
fi
echo "== GitHub"
gh auth status || s=1
[ -z "$1" ] || git ls-remote "https://github.com/$1.git" HEAD || s=1
if ! git var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
  echo "WARN: git author identity is unset; add GIT_AUTHOR_NAME and GIT_AUTHOR_EMAIL to the env file"
fi
echo "== Zig toolchain"
echo "zig $(zig version); $(zigpeek --version 2>/dev/null || echo 'zigpeek missing')"
info=$(zigpeek info 2>&1 || true)
case $info in
  *'(missing)'*) echo "FAIL: zigpeek cannot find the Zig docs it needs"; s=1 ;;
  *) if zigpeek builtins get @intCast >/dev/null 2>&1; then
       echo "zigpeek reads the local langref and stdlib"
     else
       echo "FAIL: zigpeek could not read the langref"; s=1
     fi ;;
esac
echo "== other sites"
if curl -fsS -m 15 -o /dev/null https://example.com; then
  echo "FAIL: example.com was reachable"; s=1
else echo "example.com blocked"; fi
echo "== no route around the proxy"
# Check an IP, not a name: a name only proves DNS is absent.
code=$(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    -u ALL_PROXY -u all_proxy \
    curl -sS --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' http://1.1.1.1/ || true)
if [ "$code" != 000 ]; then
  echo "FAIL: the container reached the internet directly (HTTP $code)"; s=1
else echo "direct connection failed"; fi
code6=$(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    -u ALL_PROXY -u all_proxy \
    curl -sS --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' 'http://[2606:4700:4700::1111]/' || true)
if [ "$code6" != 000 ]; then
  echo "FAIL: the container reached the internet directly over IPv6 (HTTP $code6)"; s=1
else echo "direct IPv6 connection failed"; fi
code443=$(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    -u ALL_PROXY -u all_proxy \
    curl -sSk --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' https://1.1.1.1/ || true)
if [ "$code443" != 000 ]; then
  echo "FAIL: the container reached the internet directly (HTTPS $code443)"; s=1
else echo "direct TLS connection failed"; fi
exit $s
EOF
  set -- bash -c "$script" check "$check_repo"
  args+=(-w /tmp)
elif [ -n "$clone" ]; then
  boot=$(clone_boot_script)
  vol=$(pi_clone_volume "$instance" "$clone" "$cfg")
  ensure_volume "$vol" clone "$clone"
  echo "run.sh: clone volume: $vol" >&2
  args+=(-v "$vol:/work" -w /work -e "PI_CLONE=$clone")
  set -- bash -c "$boot" boot "$@"
else
  args+=(-v "$PWD:$PWD" -w "$PWD")
fi

set -- bash -c "$prep" prep "$@"
exec "$cli" "${args[@]}" "${PI_IMAGE:-pi-agent:local}" "$@"

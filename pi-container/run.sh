#!/usr/bin/env bash
# Run Pi inside Apple's container, on a host-only network.
#   run.sh                         Pi on the current folder (trusted repos only)
#   run.sh --clone OWNER/REPO      Pi on a clone kept in a volume
#   run.sh check [OWNER/REPO]      keys, GitHub, and the network lock
#   run.sh proxy                   follow the proxy container's logs
#   run.sh proxy-stop              stop the proxy container
#   run.sh --help                  show this text
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
env_file="${PI_ENV_FILE:-$HOME/.config/pi-container/env}"
cfg="${PI_CONFIG_DIR:-$HOME/.config/pi-container}"
port="${PI_PROXY_PORT:-8888}"
placeholder="sk-or-v1-placeholder"
cli="${CONTAINER_CLI:-container}"
proxy_name="pi-proxy"
proxy_image="${PI_PROXY_IMAGE:-pi-proxy:local}"

case $port in
  ''|*[!0-9]*) echo "run.sh: PI_PROXY_PORT must be a number" >&2; exit 2 ;;
esac
if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
  echo "run.sh: PI_PROXY_PORT must be between 1 and 65535" >&2
  exit 2
fi

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ] || [ "${1:-}" = help ]; then
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

file_mode() {
  # Follow symlinks so a 600 target is not rejected because the link is 777.
  if stat -Lc %a "$1" >/dev/null 2>&1; then stat -Lc %a "$1"; else stat -Lf %Lp "$1"; fi
}

physical_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

# Resolve symlinks when realpath is available, otherwise resolve the parent.
physical_path() {
  local p=$1 d t
  [ -e "$p" ] || [ -L "$p" ] || { printf '%s\n' "$p"; return 0; }
  if command -v realpath >/dev/null 2>&1; then realpath "$p" 2>/dev/null || printf '%s\n' "$p"; return 0; fi
  while [ -L "$p" ]; do
    t=$(readlink "$p") || break
    case $t in
      /*) p=$t ;;
      *) p=$(dirname "$p")/$t ;;
    esac
  done
  d=$(physical_dir "$(dirname "$p")") || { printf '%s\n' "$p"; return 0; }
  printf '%s/%s\n' "${d%/}" "$(basename "$p")"
}

path_within() { # $1 parent, $2 child
  [ "$1" = / ] && return 0
  case $2 in "$1"|"$1"/*) return 0 ;; esac
  return 1
}

require_env() {
  [ -f "$env_file" ] || { echo "run.sh: missing $env_file (see README)" >&2; exit 1; }
  [ -r "$env_file" ] || { echo "run.sh: cannot read $env_file" >&2; exit 1; }
  case $(file_mode "$env_file") in
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

# Refuse to create secrets inside the project tree when the project will be
# mounted, so `proxy.env` and `pi.env` cannot end up inside Pi's view.
guard_config() {
  local pwd_phys cfg_phys env_phys
  pwd_phys=$(physical_dir "$PWD") || return 0
  cfg_phys=$(physical_path "$cfg")
  env_phys=$(physical_path "$env_file")
  if path_within "$pwd_phys" "$cfg_phys" || path_within "$cfg_phys" "$pwd_phys" || \
     path_within "$pwd_phys" "$env_phys"; then
    echo "run.sh: config and env files must not be inside $pwd_phys" >&2
    exit 1
  fi
}

ensure_network() {
  names=$("$cli" network list -q) || { echo "run.sh: container network list failed" >&2; exit 1; }
  if printf '%s\n' "$names" | grep -qx pi-locked; then
    if inspect=$("$cli" network inspect pi-locked 2>/dev/null); then
      if printf '%s\n' "$inspect" | grep -q '"internal"[[:space:]]*:[[:space:]]*false'; then
        echo "run.sh: pi-locked exists but is not internal; delete it first" >&2
        exit 1
      fi
    else
      echo "run.sh: warning: could not inspect pi-locked; assuming it is internal" >&2
    fi
    return
  fi
  "$cli" network create --internal pi-locked --subnet 172.30.240.0/24
}

# The proxy container gets the OpenRouter key and nothing else from the env file.
write_proxy_env() {
  mkdir -p "$cfg"
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "${cfg}/proxy.env.XXXXXX")
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
  if [ -f "$cfg/proxy.env" ] && cmp -s "$tmp" "$cfg/proxy.env"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$cfg/proxy.env"
    chmod 600 "$cfg/proxy.env"
  fi
}

# Pi gets only the GitHub token and commit identity. Other env-file entries stay
# on the Mac, and the real OpenRouter key is never passed to Pi.
write_pi_env() {
  mkdir -p "$cfg"
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "${cfg}/pi.env.XXXXXX")
  umask "$old_umask"
  : > "$tmp"
  for name in GITHUB_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
    grep "^${name}=" "$env_file" | tail -n 1 | tr -d '\r' >> "$tmp" || true
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
    chmod 600 "$cfg/pi.env"
  fi
}

# The default mode mounts the current directory. Refuse paths that would expose
# the config directory, the env file, or a known secrets directory to Pi.
guard_mount() {
  local pwd_phys cfg_phys env_phys home_phys
  pwd_phys=$(physical_dir "$PWD") || { echo "run.sh: cannot resolve $PWD" >&2; exit 1; }
  cfg_phys=$(physical_path "$cfg")
  env_phys=$(physical_path "$env_file")
  home_phys=$(physical_dir "$HOME") || home_phys=$HOME
  if [ "$pwd_phys" = / ] || path_within "$pwd_phys" "$home_phys"; then
    echo "run.sh: refusing to mount $pwd_phys; choose a project below $home_phys" >&2
    exit 1
  fi
  if path_within "$pwd_phys" "$cfg_phys" || path_within "$cfg_phys" "$pwd_phys" || \
     path_within "$pwd_phys" "$env_phys"; then
    echo "run.sh: refusing to mount $pwd_phys; it overlaps $cfg or $env_file" >&2
    exit 1
  fi
  for secret in .ssh .aws .gnupg .kube Library/Keychains; do
    if path_within "$home_phys/$secret" "$pwd_phys"; then
      echo "run.sh: refusing to mount $pwd_phys; it looks like a secrets directory" >&2
      exit 1
    fi
  done
}

addr_file() { printf '%s\n' "$cfg/private/proxy.addr"; }

# `container inspect` prints pretty JSON. Current releases nest the value in
# status.state. Older releases use a top-level status string. Split on "}"
# so either shape is one record.
proxy_state() {
  json=$("$cli" inspect "$proxy_name" 2>/dev/null) || { printf '\n'; return; }
  printf '%s\n' "$json" | awk '
    BEGIN { RS = "}" }
    /"state"[[:space:]]*:[[:space:]]*"/ || /"status"[[:space:]]*:[[:space:]]*"/ {
      s = $0
      sub(/.*"(state|status)"[[:space:]]*:[[:space:]]*"/, "", s)
      sub(/".*/, "", s)
      if (s ~ /^(running|stopped|stopping|exited|created|paused|unknown)$/) state = s
    }
    END { print state }
  '
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
  shasum -a 256 "$@" | shasum -a 256 | awk '{print $1}'
}

ensure_proxy() {
  mkdir -p "$cfg/certs" "$cfg/private"
  chmod 700 "$cfg/private"
  write_proxy_env
  stamp="$cfg/proxy.stamp"
  image_hash=$(hash_files "$here/proxy.py" "$here/Dockerfile.proxy")
  config_hash=$( { cat "$cfg/proxy.env" 2>/dev/null || true; printf '%s\n' "$port"; } | shasum -a 256 | awk '{print $1}' )
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
  state=$(printf '%s\n' "$state" | sed -n '1p')
  case "$state" in
    running) return ;;
    stopped|stopping)
      rm -f "$(addr_file)"
      "$cli" start "$proxy_name"
      return ;;
    '')
      # No container yet.
      ;;
    *)
      # An unrecognised state: recreate rather than collide with the name.
      "$cli" delete --force "$proxy_name" >/dev/null 2>&1 || true
      ;;
  esac
  # The address file is published only after the socket is bound. Drop a
  # stale one so a previous run cannot look ready during this boot.
  rm -f "$(addr_file)"
  "$cli" run -d --name "$proxy_name" --init \
    --cpus 1 --memory 1G \
    --network default --network pi-locked \
    --env-file "$cfg/proxy.env" \
    -e "PI_PROXY_PORT=$port" \
    -v "$cfg/private:/private" -v "$cfg/certs:/certs" \
    "$proxy_image" >/dev/null
}

# Pi reaches the proxy on the locked network. Ask from inside that container,
# which is the path Pi uses.
proxy_answers() {
  "$cli" exec "$proxy_name" /usr/local/bin/python3 -c \
    'import sys,urllib.request
ip, port = sys.argv[1], sys.argv[2]
body = urllib.request.urlopen("http://%s:%s/health" % (ip, port), timeout=2).read()
raise SystemExit(0 if body == b"pi-container-proxy\n" else 1)' \
    "$1" "$port"
}

proxy_ip() {
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
    echo "run.sh: pi-proxy is listening on ${ip}:${port} but did not answer from inside the container. Run: $cli logs $proxy_name" >&2
  else
    echo "run.sh: pi-proxy did not report an address. Run: $cli logs $proxy_name" >&2
  fi
  exit 1
}

# Tests source this file to call the functions above. They do not start a container.
if [ "${PI_SOURCE_ONLY:-}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

if [ "${1:-}" = proxy-stop ]; then
  "$cli" stop "$proxy_name" >/dev/null 2>&1 || true
  exit 0
fi

mount_project=1
case "${1:-}" in
  check|proxy|--clone) mount_project=0 ;;
esac
[ "$mount_project" = 0 ] || guard_config
require_env
write_pi_env
if [ "${PI_SKIP_HOST_SETUP:-}" = 1 ]; then
  proxy_ip_value="172.30.240.2"
else
  ensure_network
  ensure_proxy
  if [ "${1:-}" = proxy ]; then
    exec "$cli" logs -f "$proxy_name"
  fi
  proxy_ip_value=$(proxy_ip)
fi
proxy_url="http://${proxy_ip_value}:${port}"

args=(run --rm -i --init --network pi-locked
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
  -v "$cfg/certs:/etc/pi-proxy-ca:ro"
  -v pi-agent-home:/root/.pi/agent)
if [ -n "${TZ:-}" ]; then args+=(-e "TZ=$TZ"); fi
if [ -n "${COLORTERM:-}" ]; then args+=(-e "COLORTERM=$COLORTERM"); fi
if [ -t 0 ] && [ -t 1 ]; then args+=(-t); fi

clone=""
if [ "${1:-}" = --clone ]; then
  clone="${2:?--clone needs OWNER/REPO}"; shift 2
  owner=${clone%%/*}
  repo=${clone#*/}
  if [ "$owner" = "$clone" ] || [ -z "$owner" ] || [ -z "$repo" ] \
     || ! [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] \
     || ! [[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]] \
     || [ "$repo" = . ] || [ "$repo" = .. ] || [ "${repo#-}" != "$repo" ]; then
    echo "run.sh: bad repo '$clone'" >&2
    exit 2
  fi
fi
[ $# -gt 0 ] || set -- pi
case "${1:-}" in
  -*) echo "run.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
esac

read -r -d '' prep <<'EOF' || true
git config --global http.proxy "$HTTPS_PROXY"
git config --global https.proxy "$HTTPS_PROXY"
exec "$@"
EOF

if [ "$1" = check ]; then
  read -r -d '' script <<'EOF' || true
s=0
echo "== OpenRouter key"
if [ "$OPENROUTER_API_KEY" = "sk-or-v1-placeholder" ]; then echo "Pi has the placeholder"
else echo "FAIL: the real OpenRouter key is in the Pi container"; s=1; fi
echo "== OpenRouter"
if r=$(curl -fsS -m 20 --cacert /etc/pi-proxy-ca/ca.pem https://openrouter.ai/api/v1/key); then
  printf '%s\n' "$r" | jq '.data | {label: .label, limit: .limit, remaining: .limit_remaining, usage: .usage}' || s=1
  limit=$(printf '%s\n' "$r" | jq -r '.data.limit // "null"' 2>/dev/null || echo null)
  if [ "$limit" = null ]; then echo "WARN: the OpenRouter key has no credit limit"; fi
else
  echo "FAIL: OpenRouter. See: container logs pi-proxy"
  s=1
fi
echo "== GitHub"
gh auth status || s=1
[ -z "$1" ] || git ls-remote "https://github.com/$1.git" HEAD || s=1
if ! git var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
  echo "WARN: git author identity is unset; add GIT_AUTHOR_NAME and GIT_AUTHOR_EMAIL to the env file"
fi
echo "== other sites"
if curl -fsS -m 15 -o /dev/null https://example.com; then
  echo "FAIL: example.com was reachable"; s=1
else echo "example.com blocked"; fi
echo "== no route around the proxy"
# An IP, not a name. Host-only networks have no DNS, so a name failing
# only proves that, and still leaves TCP egress open when the Mac forwards.
code=$(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    -u ALL_PROXY -u all_proxy \
    curl -sS --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' http://1.1.1.1/ || true)
if [ "$code" != 000 ]; then
  echo "FAIL: the container reached the internet directly (HTTP $code)"; s=1
else echo "direct connection failed"; fi
code443=$(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    -u ALL_PROXY -u all_proxy \
    curl -sSk --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' https://1.1.1.1/ || true)
if [ "$code443" != 000 ]; then
  echo "FAIL: the container reached the internet directly (HTTPS $code443)"; s=1
else echo "direct TLS connection failed"; fi
exit $s
EOF
  set -- bash -c "$script" check "${2:-$clone}"
  args+=(-w /tmp)
elif [ -n "$clone" ]; then
  read -r -d '' boot <<'EOF' || true
d="/work/${PI_CLONE#*/}"
if [ -e "$d" ] && [ ! -d "$d/.git" ]; then
  echo "run.sh: $d exists but is not a git clone; delete the clone volume and retry" >&2
  exit 1
fi
[ -d "$d/.git" ] || git clone "https://github.com/$PI_CLONE.git" "$d" || exit 1
cd "$d" && exec "$@"
EOF
  slug=$(printf '%s' "$clone" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | cut -c1-40)
  short_hash=$(printf '%s' "$clone" | shasum -a 256 | cut -c1-8)
  vol="pi-clone-${slug}-${short_hash}"
  echo "run.sh: clone volume: $vol" >&2
  args+=(-v "$vol:/work" -w /work -e "PI_CLONE=$clone")
  set -- bash -c "$boot" boot "$@"
else
  guard_mount
  args+=(-v "$PWD:$PWD" -w "$PWD")
fi

set -- bash -c "$prep" prep "$@"
exec "$cli" "${args[@]}" "${PI_IMAGE:-pi-agent:local}" "$@"

#!/usr/bin/env bash
# Integration tests for run.sh and clear.sh against a fake container CLI.
#
# Nothing here needs Apple `container`. run.sh and clear.sh end by exec'ing the
# CLI, so a fake CLI captures the argv they build and the tests assert on it.
# This covers orchestration decisions: when a network is reused or refused,
# when a proxy is rebuilt, which volume is deleted, and which flags reach the
# final `container run`.
#
# Results are captured in files rather than shell variables so assertions still
# work when the script under test runs in a subshell.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
. "$root/lib/paths.sh"

run_sh="$root/run.sh"
clear_sh="$root/clear.sh"
fake="$here/fake-container.sh"
chmod +x "$fake" "$run_sh" "$clear_sh"

# The test runner may itself be running inside pi (PI_CLONE, PI_INSTANCE, ...),
# so clear every variable run.sh and clear.sh read before any case runs. Cases
# set what they need explicitly.
unset PI_INSTANCE PI_CLONE PI_PROXY_PORT PI_PROXY_NAME PI_NETWORK_NAME \
  PI_PROXY_IMAGE PI_LOCKED_SUBNET PI_AGENT_VOLUME PI_SETTINGS_FILE \
  PI_SKIP_HOST_SETUP PI_SKIP_PROXY_IP PI_BACKUP_DIR PI_CONFIG_DIR PI_ENV_FILE \
  PI_NVIM_CONFIG PI_NVIM_DATA PI_NVIM_STATE PI_NVIM_CACHE \
  PI_CPUS PI_MEMORY PI_PROXY_WAIT PI_LOCK_WAIT PI_SOURCE_ONLY TZ COLORTERM PIC_HOME

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

run_it() { # command...
  "$@" >"$tmp/out" 2>"$tmp/err"
  printf '%s\n' "$?" >"$tmp/status"
}

o() { cat "$tmp/out" 2>/dev/null || true; }
e() { cat "$tmp/err" 2>/dev/null || true; }
s() { cat "$tmp/status" 2>/dev/null || true; }

expect_status() { # want, label
  local got
  got=$(s)
  if [ "$got" = "$1" ]; then
    pass
  else
    fail "$2: expected status $1, got ${got:-none}; stderr: $(e)"
  fi
}

log_has() { # needle, label
  if [ -f "$logfile" ] && grep -qF -- "$1" "$logfile"; then
    pass
  else
    fail "${2:-log}: missing [$1]"
  fi
}

log_lacks() { # needle, label
  if [ -f "$logfile" ] && grep -qF -- "$1" "$logfile"; then
    fail "${2:-log}: unexpected [$1]"
  else
    pass
  fi
}

# Unlike log_lacks, this one does not match a longer name that contains the
# needle: 'pi-proxy' is a prefix of 'pi-proxy-<id>'. The fake logs one CALL line
# per invocation, so the whole line is the exact argv.
log_lacks_line() { # exact call, label
  if [ -f "$logfile" ] && grep -qxF -- "$1" "$logfile"; then
    fail "${2:-log}: unexpected [$1]"
  else
    pass
  fi
}

# Create an isolated world and config. Sets: t, home, cfg, world, logfile.
new_case() { # name
  t="$tmp/$1"
  home="$t/home"
  # Use the default profile so names stay pi-locked/pi-proxy/pi-agent-home.
  cfg="$home/.pic/config"
  world="$t/world"
  logfile="$t/log"
  case_env=""
  mkdir -p "$home" "$cfg/certs" "$cfg/private" \
    "$world/images" "$world/networks" "$world/containers" "$world/volumes" \
    "$t/project"
  : > "$cfg/certs/ca.pem"
  printf 'OPENROUTER_API_KEY=sk-or-v1-real\nGITHUB_TOKEN=ghp_test\nGIT_AUTHOR_NAME=Test\nGIT_AUTHOR_EMAIL=test@example.com\n' > "$cfg/env"
  chmod 600 "$cfg/env"
}

# Emit a volume inspect payload with slashes escaped the way Apple's CLI does.
vol_json() { # name kind instance config settings [repo] [profile] [managed]
  local name=$1 kind=$2 instance=$3 config=$4 settings=$5 repo=${6:-} profile=${7:-default} managed=${8:-true}
  local c s r repo_field
  c=${config//\//\\/}
  s=${settings//\//\\/}
  if [ -n "$repo" ]; then
    r=${repo//\//\\/}
    repo_field=",\"pi.repo\":\"$r\""
  else
    repo_field=""
  fi
  printf '[{"id":"%s","configuration":{"name":"%s","labels":{"pi.managed":"%s","pi.profile":"%s","pi.config":"%s","pi.settings":"%s","pi.instance":"%s","pi.kind":"%s"%s}}}]' \
    "$name" "$name" "$managed" "$profile" "$c" "$s" "$instance" "$kind" "$repo_field"
}

# Emit image/network/proxy inspect payloads inline. Integration tests must not
# depend on a recorded fixture's version or subnet: re-recording fixtures must
# not rewrite expectations.
image_json() { # version [capabilities]
  local env
  if [ -n "${2:-}" ]; then
    env="[\"PI_CONTAINER_PI_VERSION=$1\",\"PI_CONTAINER_CAPABILITIES=$2\"]"
  else
    env="[\"PI_CONTAINER_PI_VERSION=$1\"]"
  fi
  printf '[{"id":"sha256:test","configuration":{"descriptor":{"digest":"sha256:test"},"name":"pi-full:local"},"variants":[{"config":{"config":{"Env":%s},"history":[]}}]}]' "$env"
}

network_json() { # subnet [mode]
  local subnet=$1 mode=${2:-hostOnly}
  printf '[{"configuration":{"name":"pi-locked","mode":"%s","ipv4Subnet":"%s"},"id":"pi-locked","status":{"ipv4Gateway":"172.30.240.1","ipv4Subnet":"%s"}}]' \
    "$mode" "$subnet" "$subnet"
}

proxy_running_json() {
  printf '[{"id":"pi-proxy","configuration":{"name":"pi-proxy"},"status":{"state":"running"}}]'
}

# Run a pi-container script in the isolated world. The default profile is used,
# so PI_CONFIG_DIR stays unset and cfg resolves to $HOME/.pic/config.
# $case_env is the case's PI_IMAGE/PI_EGRESS/PI_MODEL_URL, e.g. as an alias sets them.
pi() { # script, args...
  local script=$1
  shift
  # shellcheck disable=SC2086
  run_it env HOME="$home" PI_ENV_FILE="$cfg/env" $case_env \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$script" "$@"
}

# ---------------------------------------------------------------- normal run
case_normal_run() {
  new_case normal
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy_local.json"
  network_json "172.30.240.0/24" > "$world/networks/pi-locked.json"
  printf 'pi-locked\n' > "$world/networks.list"
  proxy_running_json > "$world/containers/pi-proxy.json"
  printf '172.30.240.2\n' > "$cfg/private/proxy.addr"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" pi
  )
  expect_status 0 "normal run succeeds"
  log_has "run --rm -i --init --network pi-locked" "final run uses the locked network"
  log_has "pi-full:local" "agent image named"
  log_has "volume create" "agent volume created"
  log_has "build -t pi-proxy:local" "proxy image built on first run"
  log_has "delete --force pi-proxy" "stale proxy deleted before rebuild"
  log_has "exec pi-proxy" "proxy health checked from inside"
  log_has "/root/.pi/agent/settings.json:ro" "settings mounted read-only"
  log_lacks "network create" "existing host-only network reused"
  log_lacks "CALL start pi-proxy" "a running proxy with an address is not restarted"
  [ -f "$cfg/settings.json" ] && pass || fail "settings.json was not created"
  local settings
  settings=$(cat "$cfg/settings.json" 2>/dev/null || true)
  contains 'lastChangelogVersion' "$settings" "settings seeds lastChangelogVersion"
  contains '1.4.0' "$settings" "settings version comes from image env"
  contains 'thinkingmachines/inkling-2-small' "$settings" "default model seeded"
  [ -f "$cfg/private/proxy.env" ] && pass || fail "proxy.env was not written"
  [ -f "$cfg/pi.env" ] && pass || fail "pi.env was not written"
  eq 600 "$(stat -Lc %a "$cfg/pi.env" 2>/dev/null || stat -Lf %Lp "$cfg/pi.env")" "pi.env is mode 600"
  eq 600 "$(stat -Lc %a "$cfg/private/proxy.env" 2>/dev/null || stat -Lf %Lp "$cfg/private/proxy.env")" "proxy.env is mode 600"
  contains "OPENROUTER_API_KEY=sk-or-v1-real" "$(cat "$cfg/private/proxy.env")" "proxy.env has the real OpenRouter key"
  not_contains OPENROUTER_API_KEY "$(cat "$cfg/pi.env")" "pi.env omits the OpenRouter key"
  contains "GITHUB_TOKEN=ghp_test" "$(cat "$cfg/pi.env")" "pi.env has the GitHub token"
  log_has "pi.kind=agent" "agent volume carries the kind label"
  log_has "pi.instance=default" "agent volume carries the instance label"
  log_lacks "OPENROUTER_API_KEY=sk-or-v1-real" "real key never appears in argv"
}

# --------------------------------------------------- check includes enforcer
case_check_enforcer() {
  new_case checkenforcer
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy_local.json"
  network_json "172.30.240.0/24" > "$world/networks/pi-locked.json"
  printf 'pi-locked\n' > "$world/networks.list"
  proxy_running_json > "$world/containers/pi-proxy.json"
  printf '172.30.240.2\n' > "$cfg/private/proxy.addr"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" check owner/repo
  )
  expect_status 0 "check succeeds against the fake runtime"
  log_has 'enforcer' "check probes enforcer"
  log_has 'ghp_' "check probes the blocking rule"
  log_has 'NET_ADMIN and NET_RAW dropped' "check verifies the lock dropped NET_ADMIN"
  log_has 'no DNS answer from' "check queries the resolvers"
  log_has '100.100.100.100' "check includes Tailscale's resolver"
}

# ------------------------------------------------------- tokenless agent pack
case_tokenless_run() {
  new_case tokenless
  image_json 1.4.0 "netlock,pi" > "$world/images/pi-min_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy_local.json"
  network_json "172.30.240.0/24" > "$world/networks/pi-locked.json"
  printf 'pi-locked\n' > "$world/networks.list"
  proxy_running_json > "$world/containers/pi-proxy.json"
  printf '172.30.240.2\n' > "$cfg/private/proxy.addr"
  printf 'OPENROUTER_API_KEY=sk-or-v1-real\n' > "$cfg/env"
  chmod 600 "$cfg/env"
  printf 'GITHUB_TOKEN=stale\n' > "$cfg/pi.env"
  chmod 600 "$cfg/pi.env"
  (
    cd "$t/project" || exit 1
    run_it env HOME="$home" PI_ENV_FILE="$cfg/env" \
      CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
      bash "$run_sh" --image min pi
  )
  expect_status 0 "tokenless agent pack runs"
  contains 'instance=default image=pi-min:local pack=min' "$(e)" "normal run names the instance and pack"
  contains 'capabilities=netlock,pi egress=standard model_url=openrouter' "$(e)" "normal run names the capabilities and route"
  log_lacks "--env-file" "tokenless run does not mount pi.env"
  [ -e "$cfg/pi.env" ] && fail "stale pi.env was not removed" || pass
}

case_tokenless_check() {
  new_case tokenlesscheck
  image_json 1.4.0 "netlock,pi" > "$world/images/pi-min_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy_local.json"
  network_json "172.30.240.0/24" > "$world/networks/pi-locked.json"
  printf 'pi-locked\n' > "$world/networks.list"
  proxy_running_json > "$world/containers/pi-proxy.json"
  printf '172.30.240.2\n' > "$cfg/private/proxy.addr"
  printf 'OPENROUTER_API_KEY=sk-or-v1-real\n' > "$cfg/env"
  chmod 600 "$cfg/env"
  (
    cd "$t/project" || exit 1
    run_it env HOME="$home" PI_ENV_FILE="$cfg/env" \
      CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
      bash "$run_sh" --image min check owner/repo
  )
  expect_status 0 "tokenless check succeeds without gh or zig"
  contains 'image=pi-min:local pack=min' "$(e)" "check names the image it verifies"
  log_lacks "--env-file" "tokenless check does not mount pi.env"
  contains 'image      min (pi-min:local)' "$(o)" "check starts with the config summary"
  contains 'flag' "$(o)" "check names the image's source"
}

case_pack_missing_pi() {
  new_case packmissing
  image_json 1.4.0 "zig,zigpeek,enforcer,nvim,zls" > "$world/images/pi-editor_local.json"
  printf 'OPENROUTER_API_KEY=sk-or-v1-real\n' > "$cfg/env"
  chmod 600 "$cfg/env"
  (
    cd "$t/project" || exit 1
    run_it env HOME="$home" PI_ENV_FILE="$cfg/env" \
      CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
      bash "$run_sh" --image editor pi
  )
  expect_status 1 "normal mode refuses an image without Pi"
  contains "lacks capability 'pi'" "$(e)" "missing capability is named"
  log_lacks "run --" "missing capability never starts a container"
}

# ---------------------------------------------------------------- egress mode
# --allow-egress swaps the locked network and proxy for the container's default
# network, and passes the real OpenRouter key in a private env file. It must not
# create a network, build a proxy, or leak the key into argv.
case_egress_run() {
  new_case egress
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" --allow-egress pi
  )
  expect_status 0 "egress run succeeds without a proxy or locked network"
  log_has "run --rm -i --init --network default" "egress uses the default network"
  log_lacks "pi-locked" "egress never names the locked network"
  log_lacks "network create" "egress creates no host-only network"
  log_lacks "build -t pi-proxy:local" "egress builds no proxy image"
  log_lacks "exec pi-proxy" "egress does not ask the proxy for an address"
  log_lacks "HTTP_PROXY=" "egress sets no proxy variables"
  log_lacks "/etc/pi-proxy-ca" "egress mounts no CA"
  log_has "private/egress.env" "egress passes its private env file"
  contains 'mode=allow-egress' "$(e)" "egress announces the mode"
  contains 'the container gets the real OpenRouter key' "$(e)" "egress warns about the key"
  [ -f "$cfg/private/egress.env" ] && pass || fail "egress.env was not written"
  local mode
  mode=$(stat -Lc %a "$cfg/private/egress.env" 2>/dev/null || stat -Lf %Lp "$cfg/private/egress.env")
  eq 600 "$mode" "egress.env is mode 600"
  contains 'OPENROUTER_API_KEY=sk-or-v1-real' "$(cat "$cfg/private/egress.env")" "egress.env has the real key"
  contains 'GITHUB_TOKEN=ghp_test' "$(cat "$cfg/private/egress.env")" "egress.env has the filtered token"
  not_contains OPENROUTER_API_KEY "$(cat "$cfg/pi.env")" "pi.env still omits the key"
  log_lacks "OPENROUTER_API_KEY=sk-or-v1-real" "real key never appears in argv"
}

case_egress_clone() {
  new_case egressclone
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" --allow-egress --clone owner/repo true
  )
  expect_status 0 "egress clone succeeds"
  log_has "run --rm -i --init --network default" "egress clone keeps the default network"
  log_has "pi-clone_default_owner-repo-" "egress clone volume named"
  log_has "PI_CLONE=owner/repo" "egress clone target passed"
  log_has "-w /work" "egress clone workdir set"
}

case_egress_refusals() {
  new_case egressrefuse
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  for cmd in check proxy proxy-stop; do
    (
      cd "$t/project" || exit 1
      pi "$run_sh" --allow-egress "$cmd"
    )
    expect_status 2 "egress refuses $cmd"
    contains "has no proxy or locked network to $cmd" "$(e)" "$cmd refusal names the reason"
  done
  (
    cd "$t/project" || exit 1
    pi "$run_sh" --allow-egress --manual
  )
  expect_status 2 "egress refuses --manual"
  contains 'use --manual alone' "$(e)" "--manual conflict is explained"
  log_lacks "run --" "egress refusals start no container"
  log_lacks "volume create" "egress refusals create no volume"
}

case_egress_requires_key() {
  new_case egresskey
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  printf 'GITHUB_TOKEN=ghp_test\n' > "$cfg/env"
  chmod 600 "$cfg/env"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" --allow-egress pi
  )
  expect_status 1 "egress requires the OpenRouter key"
  contains 'set OPENROUTER_API_KEY' "$(e)" "egress names the missing key"
  log_lacks "run --" "missing key starts no container"
  [ -e "$cfg/private/egress.env" ] && fail "egress.env was written without a key" || pass
}

# ------------------------------------------------------ network shape guards
case_network_nat_refused() {
  new_case nat
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  network_json "192.168.64.0/24" nat > "$world/networks/pi-locked.json"
  printf 'pi-locked\n' > "$world/networks.list"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" pi
  )
  expect_status 1 "NAT network is refused"
  contains 'not in host-only mode' "$(e)" "refusal names the reason"
  log_lacks "run --rm" "no container run after refusal"
}

case_network_escaped_subnet() {
  new_case escaped
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy_local.json"
  network_json "172.30.240.0\/24" > "$world/networks/pi-locked.json"
  printf 'pi-locked\n' > "$world/networks.list"
  proxy_running_json > "$world/containers/pi-proxy.json"
  printf '172.30.240.2\n' > "$cfg/private/proxy.addr"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" pi
  )
  expect_status 0 "escaped subnet still matches after normalisation"
  log_has "run --rm -i --init --network pi-locked" "run reached after escaped subnet check"
  not_contains 'does not use' "$(e)" "no subnet mismatch reported"
}

# ------------------------------------------------------------- manual + clone
case_manual_clone() {
  new_case manual
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  rm -f "$cfg/env"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" --manual --clone owner/repo true
  )
  expect_status 0 "manual clone succeeds"
  contains 'image=pi-full:local pack=full capabilities=-' "$(e)" "manual run announces a legacy image without capabilities"
  log_has "pi-clone_default_owner-repo-" "clone volume named"
  log_has "PI_CLONE=owner/repo" "clone target passed"
  log_has "-w /work" "clone workdir set"
  log_has "ZIG_LOCAL_CACHE_DIR=/root/.cache/zig-local/" "zig local cache redirected"
  log_has "/root/.config/nvim" "nvim config mounted"
  log_lacks "--env-file" "no pi.env mounted when absent"
  [ -f "$cfg/nvim/init.lua" ] && pass || fail "nvim init.lua was not seeded"
}

case_manual_clone_env() {
  new_case manualenv
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" --manual --clone owner/repo true
  )
  expect_status 0 "manual clone with env succeeds"
  log_has "--env-file" "manual clone mounts filtered env when present"
  [ -f "$cfg/pi.env" ] && pass || fail "manual clone did not write pi.env"
}

case_manual_clone_env_mode() {
  new_case manualenvmode
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  chmod 644 "$cfg/env"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" --manual --clone owner/repo true
  )
  expect_status 1 "manual clone refuses an insecure env file"
  contains 'must be mode 600' "$(e)" "manual clone names the mode problem"
  log_lacks 'run --' "insecure env file never starts a container"
}

# ------------------------------------------------------------ clear.sh list
case_clear_list() {
  new_case list
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  printf 'pi-agent-home\npi-agent-work\npi-clone_work_owner-repo-abcdef12\n' > "$world/volumes.list"
  vol_json pi-agent-home agent default "$cfg" "$cfg/settings.json" \
    > "$world/volumes/pi-agent-home.json"
  vol_json pi-agent-work agent work "$cfg" "$cfg/settings.json" \
    > "$world/volumes/pi-agent-work.json"
  vol_json pi-clone_work_owner-repo-abcdef12 clone work "$cfg" "$cfg/settings.json" owner/repo \
    > "$world/volumes/pi-clone_work_owner-repo-abcdef12.json"
  run_it env -u PI_CONFIG_DIR HOME="$home" PI_CONFIG_DIR="$cfg" \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$clear_sh" list
  expect_status 0 "clear.sh list succeeds"
  contains "current profile: default ($cfg)" "$(o)" "profile header"
  contains 'pi-agent-home' "$(o)" "default agent volume listed"
  contains 'pi-agent-work' "$(o)" "named agent volume listed"
  contains 'pi-clone_work_owner-repo-abcdef12' "$(o)" "clone volume listed"
  contains 'owner/repo' "$(o)" "clone repo label shown"
  contains "$cfg/settings.json" "$(o)" "settings path shown"
}

# `container` can be on PATH while the runtime is stopped. Volume listing then
# fails, and an empty list would read as "no instances".
case_clear_list_runtime_down() {
  new_case listdown
  mkdir -p "$world/fail"
  : > "$world/fail/volume.list"
  run_it env -u PI_CONFIG_DIR HOME="$home" PI_CONFIG_DIR="$cfg" \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$clear_sh" list
  expect_status 1 "clear.sh list fails when the runtime does not answer"
  contains 'start the container system' "$(e)" "runtime failure names the fix"
  not_contains 'current profile' "$(o)" "no headers for an unanswered runtime"
}

# A volume created before profiles existed has no pi.config label. Listing it
# from another profile must not claim that profile's settings file.
case_clear_list_legacy_volume() {
  new_case legacylist
  printf 'pi-agent-home\n' > "$world/volumes.list"
  # Kind labels predate profiles, so this volume is recognisably an agent volume
  # but has no pi.profile/pi.config/pi.settings.
  printf '[{"id":"pi-agent-home","configuration":{"name":"pi-agent-home","labels":{"pi.managed":"true","pi.instance":"default","pi.kind":"agent"}}}]' \
    > "$world/volumes/pi-agent-home.json"
  run_it env -u PI_CONFIG_DIR HOME="$home" PI_CONFIG_DIR="$t/other" \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$clear_sh" list
  expect_status 0 "clear.sh list tolerates a legacy volume"
  row=$(printf '%s\n' "$(o)" | grep 'pi-agent-home' | head -n 1)
  contains 'pi-agent-home' "$row" "legacy volume listed"
  contains "$home/.pic/config/settings.json" "$row" "legacy volume uses the default profile settings"
  not_contains "$t/other/settings.json" "$row" "legacy volume does not borrow the listing profile"
}

# ---------------------------------------------------- clear.sh save + nuke agent
case_nuke_agent() {
  new_case nukeagent
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  printf 'pi-agent-home\n' > "$world/volumes.list"
  vol_json pi-agent-home agent default "$cfg" "$cfg/settings.json" \
    > "$world/volumes/pi-agent-home.json"
  mkdir -p "$t/stream/sessions"
  printf '{"session":1}\n' > "$t/stream/sessions/a.jsonl"
  tar -C "$t/stream" -cf "$t/stream.tar" sessions
  cp "$t/stream.tar" "$world/run.stdout"
  run_it env -u PI_CONFIG_DIR HOME="$home" PI_CONFIG_DIR="$cfg" PI_BACKUP_DIR="$t/backups" \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$clear_sh" nuke agent --yes
  expect_status 0 "nuke agent succeeds"
  log_has "volume delete pi-agent-home" "agent volume deleted"
  if find "$t/backups" -name a.jsonl -type f 2>/dev/null | grep -q .; then
    pass
  else
    fail "session backup was not extracted"
  fi
}

# The shared agent image can be gone -- `nuke all` deletes it -- and cleanup must
# still work. The volume goes without a backup, and the run says so.
case_nuke_agent_without_image() {
  new_case nukeagentnoimage
  printf 'pi-agent-home\n' > "$world/volumes.list"
  vol_json pi-agent-home agent default "$cfg" "$cfg/settings.json" \
    > "$world/volumes/pi-agent-home.json"
  run_it env -u PI_CONFIG_DIR HOME="$home" PI_CONFIG_DIR="$cfg" PI_BACKUP_DIR="$t/backups" \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$clear_sh" nuke agent --yes
  expect_status 0 "nuke agent succeeds without the agent image"
  log_has "volume delete pi-agent-home" "agent volume deleted without the image"
  contains 'without a session backup' "$(o)" "skipped backup is reported"
  log_lacks 'run --rm' "no backup container runs without the image"
}

# ------------------------------------------------ clear.sh nuke clones scoped
case_nuke_clones_scoped() {
  new_case nukeclones
  printf 'pi-clone_work_owner-repo-abcdef12\npi-clone_other_owner-repo-12345678\npi-clone_unmanaged_owner-repo-abcdef12\n' > "$world/volumes.list"
  vol_json pi-clone_work_owner-repo-abcdef12 clone work "$cfg" "$cfg/settings.json" owner/repo \
    > "$world/volumes/pi-clone_work_owner-repo-abcdef12.json"
  vol_json pi-clone_other_owner-repo-12345678 clone other "$cfg" "$cfg/settings.json" owner/repo \
    > "$world/volumes/pi-clone_other_owner-repo-12345678.json"
  vol_json pi-clone_unmanaged_owner-repo-abcdef12 clone work "$cfg" "$cfg/settings.json" owner/repo default false \
    > "$world/volumes/pi-clone_unmanaged_owner-repo-abcdef12.json"
  run_it env -u PI_CONFIG_DIR HOME="$home" PI_CONFIG_DIR="$cfg" \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$clear_sh" nuke clones --instance work --yes
  expect_status 0 "nuke clones succeeds"
  log_has "volume delete pi-clone_work" "work clone deleted"
  log_lacks "volume delete pi-clone_other" "other clone kept"
  log_lacks "volume delete pi-clone_unmanaged" "unmanaged clone kept"
  not_contains 'pi-clone_other' "$(o)" "other clone not listed for deletion"
  not_contains 'pi-clone_unmanaged' "$(o)" "unmanaged clone not listed for deletion"
}

# ---------------------------------------------- clear.sh list marks a dead profile
# A profile whose config dir is gone still owns a proxy, a network, an image, and
# volumes. list flags it so `nuke profile` has a visible target.
case_clear_list_dead_profile() {
  new_case listdead
  deadcfg="$t/deadcfg"
  id=$(. "$root/names.sh"; pi_profile_id "$deadcfg")
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  printf 'pi-agent-home\npi-agent-%s-work\n' "$id" > "$world/volumes.list"
  vol_json pi-agent-home agent default "$cfg" "$cfg/settings.json" \
    > "$world/volumes/pi-agent-home.json"
  vol_json "pi-agent-$id-work" agent work "$deadcfg" "$deadcfg/settings.json" "" "$id" \
    > "$world/volumes/pi-agent-$id-work.json"
  run_it env -u PI_CONFIG_DIR HOME="$home" PI_CONFIG_DIR="$cfg" \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$clear_sh" list
  expect_status 0 "list succeeds with a dead profile present"
  dead_row=$(printf '%s\n' "$(o)" | grep "pi-agent-$id-work" | head -n 1)
  live_row=$(printf '%s\n' "$(o)" | grep 'pi-agent-home' | head -n 1)
  contains '(missing)' "$dead_row" "dead profile settings are marked missing"
  not_contains '(missing)' "$live_row" "live profile is not marked missing"
}

# ---------------------------------------------------- clear.sh nuke profile
# One command retires a profile: every instance's agent volume, its clone
# volumes, its proxy, network, and proxy image. The shared agent image, the
# builder cache, and other profiles stay; the config dir stays.
case_nuke_profile() {
  new_case nukeprofile
  deadcfg="$t/deadcfg"
  id=$(. "$root/names.sh"; pi_profile_id "$deadcfg")
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy-${id}_local.json"
  network_json "172.30.240.0/24" > "$world/networks/pi-locked-$id.json"
  printf 'pi-locked-%s\n' "$id" > "$world/networks.list"
  proxy_running_json | sed "s/pi-proxy/pi-proxy-$id/g" > "$world/containers/pi-proxy-$id.json"
  printf 'pi-agent-home\npi-agent-%s-work\npi-agent-%s-other\npi-clone_%s_work_owner-repo-abcdef12\n' \
    "$id" "$id" "$id" > "$world/volumes.list"
  vol_json pi-agent-home agent default "$cfg" "$cfg/settings.json" \
    > "$world/volumes/pi-agent-home.json"
  vol_json "pi-agent-$id-work" agent work "$deadcfg" "$deadcfg/settings.json" "" "$id" \
    > "$world/volumes/pi-agent-$id-work.json"
  vol_json "pi-agent-$id-other" agent other "$deadcfg" "$deadcfg/settings.json" "" "$id" \
    > "$world/volumes/pi-agent-$id-other.json"
  vol_json "pi-clone_${id}_work_owner-repo-abcdef12" clone work "$deadcfg" "$deadcfg/settings.json" \
    owner/repo "$id" > "$world/volumes/pi-clone_${id}_work_owner-repo-abcdef12.json"
  mkdir -p "$t/stream/sessions"
  printf '{"session":1}\n' > "$t/stream/sessions/a.jsonl"
  tar -C "$t/stream" -cf "$t/stream.tar" sessions
  cp "$t/stream.tar" "$world/run.stdout"
  run_it env -u PI_CONFIG_DIR HOME="$home" PI_CONFIG_DIR="$deadcfg" PI_BACKUP_DIR="$t/backups" \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$clear_sh" nuke profile --yes
  expect_status 0 "nuke profile succeeds"
  log_has "volume delete pi-agent-$id-work" "work agent volume deleted"
  log_has "volume delete pi-agent-$id-other" "other agent volume deleted"
  log_has "volume delete pi-clone_${id}_work_owner-repo-abcdef12" "clone volume deleted"
  log_has "delete --force pi-proxy-$id" "profile proxy deleted"
  log_has "network delete pi-locked-$id" "profile network deleted"
  log_has "image delete pi-proxy-${id}:local" "profile proxy image deleted"
  log_lacks "volume delete pi-agent-home" "another profile's agent volume kept"
  log_lacks_line "CALL delete --force pi-proxy" "the default profile's proxy kept"
  log_lacks_line "CALL network delete pi-locked" "the default profile's network kept"
  log_lacks "image delete pi-full:local" "the shared agent image kept"
  log_lacks "builder delete" "the builder cache kept"
  contains "kept: $deadcfg" "$(o)" "config dir reported as kept"
  [ -d "$deadcfg" ] && fail "nuke profile must not create the config dir" || pass
  find "$t/backups" -name a.jsonl -type f 2>/dev/null | grep -q . && pass || fail "sessions were not backed up"
}

# --instance is parsed before dispatch, so `nuke profile` and `nuke all` must refuse it rather
# than silently deleting every instance in the profile.
case_nuke_profile_rejects_instance() {
  local target
  for target in profile all; do
    new_case "nuke${target}inst"
    printf 'pi-agent-home\n' > "$world/volumes.list"
    vol_json pi-agent-home agent default "$cfg" "$cfg/settings.json" \
      > "$world/volumes/pi-agent-home.json"
    run_it env -u PI_CONFIG_DIR HOME="$home" PI_CONFIG_DIR="$cfg" \
      CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
      bash "$clear_sh" nuke "$target" --instance work --yes
    expect_status 1 "nuke $target rejects --instance"
    contains 'drop --instance' "$(e)" "nuke $target: the refusal explains the flag"
    log_lacks 'volume delete' "nuke $target: nothing is deleted"
    log_lacks 'delete --force' "nuke $target: the proxy stays"
  done
}

# --------------------------------------------------------------- mount guards
case_mount_guards() {
  new_case guards
  mkdir -p "$home/.ssh" "$t/cfg2"

  (
    cd "$home" || exit 1
    run_it env HOME="$home" PI_CONFIG_DIR="$cfg" CONTAINER_CLI="$fake" \
      FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" bash "$run_sh" pi
  )
  expect_status 1 "refuses to mount home"
  contains 'must not overlap' "$(e)" "home overlaps the default config"

  (
    cd "$t" || exit 1
    run_it env HOME="$home" PI_CONFIG_DIR="$cfg" CONTAINER_CLI="$fake" \
      FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" bash "$run_sh" pi
  )
  expect_status 1 "refuses to mount an ancestor of home"
  contains 'must not overlap' "$(e)" "ancestor overlaps the default config"

  (
    cd "$home/.ssh" || exit 1
    run_it env HOME="$home" PI_CONFIG_DIR="$cfg" CONTAINER_CLI="$fake" \
      FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" bash "$run_sh" pi
  )
  expect_status 1 "refuses to mount a secrets directory"
  contains 'overlaps secrets' "$(e)" "secrets refusal message"

  (
    cd "$t/cfg2" || exit 1
    run_it env HOME="$home" PI_CONFIG_DIR="$t/cfg2" CONTAINER_CLI="$fake" \
      FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" bash "$run_sh" pi
  )
  expect_status 1 "refuses to mount the config directory"
  contains 'must not overlap' "$(e)" "config overlap message"

  mkdir -p "$t/ok"
  (
    cd "$t/ok" || exit 1
    run_it env HOME="$home" PI_CONFIG_DIR="$cfg" PI_ENV_FILE="$t/missing" \
      CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
      bash "$run_sh" pi
  )
  expect_status 1 "valid project stops at the env file"
  contains 'missing' "$(e)" "env file error proves the guard passed"
}

# proxy.py publishes proxy.addr once, at start. A running proxy without it
# (deleted by hand, or by a test that leaked into a real profile) must be
# restarted, not waited on for the full PI_PROXY_WAIT.
case_proxy_running_no_addr() {
  new_case noaddr
  fleet_world
  rm -f "$cfg/private/proxy.addr"
  (
    cd "$t/project" || exit 1
    run_it env HOME="$home" PI_ENV_FILE="$cfg/env" PI_PROXY_WAIT=1 \
      CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
      bash "$run_sh" true
  )
  contains "pi-proxy is running but published no address; restarting it" "$(e)" "missing address explained"
  log_has "CALL stop pi-proxy" "proxy stopped"
  log_has "CALL start pi-proxy" "proxy started again"
  local stop_line start_line
  stop_line=$(grep -n '^CALL stop pi-proxy$' "$logfile" | head -n 1 | cut -d: -f1)
  start_line=$(grep -n '^CALL start pi-proxy$' "$logfile" | head -n 1 | cut -d: -f1)
  [ "${stop_line:-0}" -gt 0 ] && [ "$stop_line" -lt "${start_line:-0}" ] && pass || fail "stop comes before start"
  # The fake never publishes an address, so the run then fails, saying so.
  expect_status 1 "fake proxy publishes nothing"
  contains "did not report an address" "$(e)" "a proxy that still publishes nothing is reported"
}

# ------------------------------------------------------------- egress lock
# Normal mode, check, and fleet turns start with NET_ADMIN and run
# lib/netlock.sh as the outermost command, so the lock is in place before
# prep, the clone, or the command runs. --manual and --allow-egress are
# unsandboxed and get neither.
run_line() { grep '^CALL run ' "$logfile" | tail -n 1; }
expect_locked() { # label
  local line lock_at prep_at
  line=$(run_line)
  contains "--cap-add NET_ADMIN" "$line" "$1: NET_ADMIN added"
  contains " netlock 172.30.240.2 8888 bash -c " "$line" "$1: lock gets the proxy address and port"
  contains "setpriv --bounding-set=-net_admin,-net_raw" "$line" "$1: lock drops NET_ADMIN and NET_RAW"
  lock_at=${line%%netlock 172.30.240.2*}
  prep_at=${line%% prep *}
  [ "${#lock_at}" -lt "${#prep_at}" ] && pass || fail "$1: lock is outside prep"
  contains "pi-full:local bash -c " "$line" "$1: the image's command is the lock script"
}
expect_unlocked() { # label
  local line
  line=$(run_line)
  [ -n "$line" ] && pass || fail "$1: no run"
  not_contains "NET_ADMIN" "$line" "$1: no NET_ADMIN"
  not_contains " netlock " "$line" "$1: no lock"
}

case_netlock_modes() {
  new_case netlock
  fleet_world
  local st
  mkdir -p "$home/.pic/fleet/sessions/s1/state"
  st=$(cd "$home/.pic/fleet/sessions/s1/state" && pwd -P)
  (cd "$t/project" && pi "$run_sh" pi)
  expect_status 0 "locked normal run"
  expect_locked "normal"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" check owner/repo)
  expect_status 0 "locked check"
  expect_locked "check"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --fleet-state "$st" --clone owner/repo pi --mode json)
  expect_status 0 "locked fleet turn"
  expect_locked "fleet turn"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --clone owner/repo true)
  expect_status 0 "locked clone run"
  expect_locked "clone"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --manual true)
  expect_status 0 "manual run"
  expect_unlocked "manual"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --allow-egress true)
  expect_status 0 "egress run"
  expect_unlocked "egress"
}

# An image that declares capabilities but not netlock has no iptables, so
# the locked modes refuse it before any container starts. Egress and manual
# modes have no lock and still run it.
case_netlock_capability() {
  new_case netlockcap
  fleet_world
  image_json 1.4.0 "zig,zigpeek,enforcer,pi,gh" > "$world/images/pi-full_local.json"
  local st cmd
  mkdir -p "$home/.pic/fleet/sessions/s1/state"
  st=$(cd "$home/.pic/fleet/sessions/s1/state" && pwd -P)
  for cmd in "pi" "check owner/repo" "--fleet-state $st pi"; do
    : > "$logfile"
    # shellcheck disable=SC2086
    (cd "$t/project" && pi "$run_sh" $cmd)
    expect_status 1 "no netlock: $cmd refused"
    contains "lacks capability 'netlock'" "$(e)" "no netlock: $cmd names the capability"
    log_lacks "CALL run " "no netlock: $cmd starts no container"
  done
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --allow-egress true)
  expect_status 0 "no netlock: egress still runs"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --manual true)
  expect_status 0 "no netlock: manual still runs"
}

# -------------------------------------------------------------- fleet state
fleet_world() {
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy_local.json"
  network_json "172.30.240.0/24" > "$world/networks/pi-locked.json"
  printf 'pi-locked\n' > "$world/networks.list"
  proxy_running_json > "$world/containers/pi-proxy.json"
  printf '172.30.240.2\n' > "$cfg/private/proxy.addr"
}

case_fleet_state() {
  new_case fleet
  fleet_world
  local st
  mkdir -p "$home/.pic/fleet/sessions/s1/state"
  st=$(cd "$home/.pic/fleet/sessions/s1/state" && pwd -P)
  (
    cd "$t/project" || exit 1
    pi "$run_sh" --fleet-state "$st" --clone owner/repo pi --mode json
  )
  expect_status 0 "fleet turn starts"
  log_has "run --rm -i --init --network pi-locked" "fleet turn uses the locked network"
  log_has "OPENROUTER_API_KEY=sk-or-v1-placeholder" "fleet turn gets the placeholder key"
  log_has "HTTPS_PROXY=http://172.30.240.2:" "fleet turn goes through the proxy"
  log_has "-v $st:$st " "state dir mounted read-write at the same path"
  log_has "FLEET_STATE=$st" "state dir named inside"
  log_has "PI_CODING_AGENT_DIR=/root/.pi/agent " "agent dir stays at the default path"
  log_has "$cfg/settings.json:/root/.pi/agent/settings.json:ro" "settings still read-only"
  log_has "PI_CLONE=owner/repo" "clone target passed"
  log_has "-w /work" "clone lands on the container's disk"
  log_has "pi --mode json" "command passed through"
  log_lacks "volume create" "no volume created for a fleet turn"
  log_lacks ":/root/.pi/agent " "no agent volume mounted"
  log_lacks ":/work " "no clone volume mounted"
  not_contains " -t " "$(grep '^CALL run ' "$logfile")" "no terminal for a headless turn"
  log_lacks "sk-or-v1-real" "real key never appears in argv"
  log_lacks "-v $t/project:" "current folder is not mounted"
  log_lacks "--name" "an unnamed fleet turn gets no container name"

  : > "$logfile"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" --fleet-state "$st" --fleet-name fleet-s1 pi --mode json
  )
  expect_status 0 "named fleet turn starts"
  log_has "CALL delete --force fleet-s1" "a leftover container of the name is removed first"
  log_has "--name fleet-s1 " "the turn's container is named"
  local del_line run_line
  del_line=$(grep -n 'CALL delete --force fleet-s1' "$logfile" | head -n 1 | cut -d: -f1)
  run_line=$(grep -n '^CALL run ' "$logfile" | head -n 1 | cut -d: -f1)
  [ "${del_line:-0}" -gt 0 ] && [ "$del_line" -lt "${run_line:-0}" ] && pass || fail "delete comes before run"

  : > "$logfile"
  mkdir -p "$t/outside" "$home/.pic/fleet/sessions/s2"
  ln -s "$t/outside" "$home/.pic/fleet/sessions/s2/state"
  ln -s "$t/outside" "$t/link"
  local bad
  for bad in "$t/outside" "$home/.pic/fleet/sessions" "$home/.pic/fleet/sessions/s2/state" "$home/.pic/fleet/sessions/../../outside" \
             "$home/.pic/fleet/sessions/missing" "relative/path"; do
    (
      cd "$t/project" || exit 1
      pi "$run_sh" --fleet-state "$bad" pi
    )
    expect_status 1 "refuses --fleet-state $bad"
  done
  for bad in "--allow-egress --fleet-state $st pi" "--manual --fleet-state $st bash" "--fleet-state $st check" "--fleet-state $st" \
             "--fleet-name fleet-s1 pi" "--fleet-state $st --fleet-name Bad pi" "--fleet-state $st --fleet-name s1 pi"; do
    (
      cd "$t/project" || exit 1
      # shellcheck disable=SC2086
      pi "$run_sh" $bad
    )
    expect_status 2 "refuses run.sh $bad"
  done
  log_lacks "run --" "refused fleet turns start no container"
}

# ------------------------------------------------------------- pi-ctr --stop
# fleetd runs `pi-ctr --stop` for a turn whose fleetd died. It must succeed
# only when the container is confirmed gone.
case_pi_ctr_stop() {
  new_case pictrstop
  stop() { run_it env FLEET_SID="$1" CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" FAKE_CONTAINER_DELETE_REMOVES=1 \
    bash "$root/pi-ctr" --stop; }
  printf '[{"id":"fleet-s1","status":{"state":"running"}}]' > "$world/containers/fleet-s1.json"
  stop s1
  expect_status 0 "stops a leftover turn container"
  [ ! -e "$world/containers/fleet-s1.json" ] && pass || fail "the container is gone"
  log_has "CALL delete --force fleet-s1" "deleted by name"
  stop s1
  expect_status 0 "nothing to stop is success"
  printf '[{"id":"fleet-s2","status":{"state":"running"}}]' > "$world/containers/fleet-s2.json"
  mkdir -p "$world/fail" && touch "$world/fail/delete"
  stop s2
  expect_status 1 "a delete that leaves the container fails"
  rm "$world/fail/delete"
  touch "$world/fail/system"
  rm -f "$world/containers/fleet-s2.json"
  stop s2
  expect_status 1 "a container system that does not answer fails, not success"
  rm "$world/fail/system"
  stop ''
  expect_status 2 "needs FLEET_SID"
  stop 'BAD;x'
  expect_status 2 "refuses a bad FLEET_SID"
}

# --------------------------------------------- proxy container unknown state
case_proxy_unknown_state() {
  new_case proxyunknown
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy_local.json"
  network_json "172.30.240.0/24" > "$world/networks/pi-locked.json"
  printf 'pi-locked\n' > "$world/networks.list"
  proxy_running_json > "$world/containers/pi-proxy.json"
  printf '172.30.240.2\n' > "$cfg/private/proxy.addr"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" pi
  )
  expect_status 0 "first run establishes the proxy stamp"

  # The container still exists, but inspect no longer exposes a state. That is
  # "unknown", not "absent": run.sh must delete it before creating a new one.
  printf '[{"id":"pi-proxy","configuration":{"name":"pi-proxy"}}]' \
    > "$world/containers/pi-proxy.json"
  : > "$logfile"
  export PI_PROXY_WAIT=0
  (
    cd "$t/project" || exit 1
    pi "$run_sh" pi
  )
  unset PI_PROXY_WAIT
  expect_status 1 "unknown proxy state does not reuse the container"
  log_has "delete --force pi-proxy" "unknown proxy state is recreated"
  contains 'did not report an address' "$(e)" "failure is the address wait, not a name collision"
}

# ------------------------------------------------ option and help guards
case_option_guards() {
  new_case optionguards
  (
    cd "$t/project" || exit 1
    pi "$run_sh" --bogus
  )
  expect_status 2 "unknown option rejected"
  contains 'unknown option' "$(e)" "unknown option message"
  log_lacks "network create" "unknown option has no side effects"
  log_lacks "run --" "unknown option does not start a container"

  (
    cd "$t/project" || exit 1
    pi "$run_sh" --manual --bogus
  )
  expect_status 2 "manual unknown option rejected"
  log_lacks "run --" "manual unknown option does not start a container"

  run_it env HOME="$home" PI_ENV_FILE="$cfg/env" PI_PROXY_PORT=abc PI_INSTANCE='Bad Name' \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$run_sh" --help
  expect_status 0 "help works before validation"
  contains 'Run Pi inside' "$(o)" "help text shown"
  contains '[COMMAND [ARG...]]' "$(o)" "help documents normal-mode commands"
  contains '--image PACK' "$(o)" "help documents the image flag"
  contains 'PI_IMAGE, PI_EGRESS, PI_MODEL_URL' "$(o)" "help documents the config env vars"
  log_lacks "network create" "help has no side effects"
}

# ------------------------------------------------------- clear.sh nuke all
# nuke all is nuke profile plus the shared agent image and the builder cache;
# a failed builder delete is reported and does not stop it.
case_nuke_all() {
  new_case nukeall
  local work clone
  work=$(. "$root/names.sh"; pi_agent_volume work "$cfg")
  clone=$(. "$root/names.sh"; pi_clone_volume work owner/repo "$cfg")
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy_local.json"
  network_json "172.30.240.0/24" > "$world/networks/pi-locked.json"
  printf 'pi-locked\n' > "$world/networks.list"
  proxy_running_json > "$world/containers/pi-proxy.json"
  printf 'pi-agent-home\n%s\n%s\npi-agent-x1-home\n' "$work" "$clone" > "$world/volumes.list"
  vol_json pi-agent-home agent default "$cfg" "$cfg/settings.json" \
    > "$world/volumes/pi-agent-home.json"
  vol_json "$work" agent work "$cfg" "$cfg/settings.json" > "$world/volumes/$work.json"
  vol_json "$clone" clone work "$cfg" "$cfg/settings.json" owner/repo > "$world/volumes/$clone.json"
  vol_json pi-agent-x1-home agent default "$t/othercfg" "$t/othercfg/settings.json" "" x1 \
    > "$world/volumes/pi-agent-x1-home.json"
  mkdir -p "$world/fail"; : > "$world/fail/builder"
  mkdir -p "$t/stream/sessions"
  printf '{"session":1}\n' > "$t/stream/sessions/a.jsonl"
  tar -C "$t/stream" -cf "$t/stream.tar" sessions
  cp "$t/stream.tar" "$world/run.stdout"
  run_it env -u PI_CONFIG_DIR HOME="$home" PI_CONFIG_DIR="$cfg" PI_BACKUP_DIR="$t/backups" \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$clear_sh" nuke all --yes
  expect_status 0 "nuke all continues when builder delete fails"
  contains 'builder cache: delete failed' "$(o)" "builder failure reported"
  not_contains 'deleted: builder cache' "$(o)" "builder failure is not reported as deleted"
  log_has "volume delete pi-agent-home" "default agent volume deleted"
  log_has "volume delete $work" "every instance's agent volume deleted"
  log_has "volume delete $clone" "the profile's clone volumes deleted"
  log_lacks "volume delete pi-agent-x1-home" "another profile's agent volume kept"
  log_has "delete --force pi-proxy" "profile proxy deleted"
  log_has "network delete pi-locked" "profile network deleted"
  log_has "image delete pi-proxy:local" "profile proxy image deleted"
  log_has "image delete pi-full:local" "the agent image deleted"
  contains "rebuild the agent image" "$(o)" "rebuild hint printed"
  find "$t/backups" -name a.jsonl -type f 2>/dev/null | grep -q . && pass || fail "sessions were not backed up"
}

# ------------------------------------------------ model_url (local model)
# Host side of the default container network, which model_url's gateway names.
default_network_json() {
  printf '[{"configuration":{"name":"default","mode":"nat"},"id":"default","status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24"}}]'
}

case_model_url() {
  new_case modelurl
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy_local.json"
  network_json "172.30.240.0/24" > "$world/networks/pi-locked.json"
  default_network_json > "$world/networks/default.json"
  printf 'pi-locked\n' > "$world/networks.list"
  proxy_running_json > "$world/containers/pi-proxy.json"
  printf '172.30.240.2\n' > "$cfg/private/proxy.addr"
  (cd "$t/project" && pi "$run_sh" pi)
  expect_status 0 "run with the default model_url"
  contains 'egress=standard model_url=openrouter' "$(e)" "default route announced"
  : > "$logfile"
  case_env="PI_MODEL_URL=http://gateway:8090"
  (cd "$t/project" && pi "$run_sh" pi)
  expect_status 0 "run with model_url from PI_MODEL_URL"
  contains 'egress=standard model_url=http://gateway:8090' "$(e)" "env model_url announced"
  log_has "network inspect default" "gateway is read from the default network"
  log_has "delete --force pi-proxy" "changing model_url recreates the proxy"
  log_lacks "build -t pi-proxy" "changing model_url does not rebuild the image"
  log_has "run --rm -i --init --network pi-locked" "Pi still runs on the locked network"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" pi)
  log_lacks "delete --force pi-proxy" "same model_url keeps the proxy"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --model-url openrouter pi)
  expect_status 0 "flag overrides PI_MODEL_URL"
  contains 'model_url=openrouter' "$(e)" "flag model_url announced"
  log_has "delete --force pi-proxy" "flag model_url recreates the proxy"
  # Absent proxy: the new one gets the route. The fake publishes no
  # address, so the run then fails on the address wait.
  rm -f "$world/containers/pi-proxy.json"
  : > "$logfile"
  (cd "$t/project" && export PI_PROXY_WAIT=0 && pi "$run_sh" --model-url http://10.0.0.5:8000 pi)
  log_has "-e PI_PROXY_MODEL_HOST=10.0.0.5 -e PI_PROXY_MODEL_PORT=8000 -v" "an IPv4 model_url reaches the proxy"
  log_has '-e PI_PROXY_EGRESS=standard -e PI_PROXY_TUNNEL=github.com\,api.github.com\,' "standard egress passes its profile"
  log_has "-e PI_PROXY_MODEL_RULE=any -e PI_PROXY_MODEL_HOST=10.0.0.5" "standard egress allows any model_url"
  : > "$logfile"
  (cd "$t/project" && export PI_PROXY_WAIT=0 && pi "$run_sh" pi)
  log_has "-e PI_PROXY_MODEL_HOST=192.168.64.1 -e PI_PROXY_MODEL_PORT=8090 -v" "gateway resolves to the default network's gateway"
  rm -f "$world/networks/default.json"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" pi)
  expect_status 1 "gateway without a default network refused"
  contains "cannot resolve gateway in http://gateway:8090" "$(e)" "unresolved gateway named"
  log_lacks "CALL run" "unresolved gateway starts nothing"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --allow-egress pi)
  expect_status 2 "--allow-egress refuses an http model_url"
  contains "needs pi-proxy (pass --model-url openrouter)" "$(e)" "--allow-egress model_url message"
  log_lacks "CALL run" "--allow-egress with model_url starts nothing"
}

# ------------------------------------------------- config file and commands
case_config_command() {
  new_case configcmd
  local json
  run_it env HOME="$home" CONTAINER_CLI=/nonexistent bash "$run_sh" config
  expect_status 0 "config needs no container runtime"
  not_contains "config.json" "$(o)" "config names no file"
  contains "image      full (pi-full:local)" "$(o)" "default image"
  contains "egress     standard" "$(o)" "default egress"
  contains "model_url  openrouter" "$(o)" "default model_url"
  contains "default" "$(o)" "default source"
  run_it env HOME="$home" CONTAINER_CLI=/nonexistent PI_IMAGE=min PI_EGRESS=offline PI_MODEL_URL=http://gateway:8090 \
    bash "$run_sh" --image zig config --json
  expect_status 0 "config --json"
  json=$(o)
  eq 1 "$(jq -r .v <<<"$json")" "json v"
  eq "zig pi-zig:local flag" "$(jq -r '"\(.image) \(.tag) \(.source.image)"' <<<"$json")" "flag image in json"
  eq "offline env http://gateway:8090 env" "$(jq -r '"\(.egress) \(.source.egress) \(.model_url) \(.source.model_url)"' <<<"$json")" "env egress and model_url in json"
  eq "false" "$(jq 'has("config")' <<<"$json")" "json names no file"
  run_it env HOME="$home" bash "$run_sh" config --yaml
  expect_status 2 "config refuses other arguments"
  run_it env HOME="$home" bash "$run_sh" --manual config
  expect_status 2 "config refuses run modes"
  local bad
  for bad in PI_IMAGE=agent PI_EGRESS=normal PI_MODEL_URL=https://gateway:8090 PI_EGRESS=offline; do
    run_it env HOME="$home" "$bad" CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" bash "$run_sh" config
    expect_status 2 "config refuses [$bad]"
    contains "run.sh: " "$(e)" "config refusal is named [$bad]"
    : > "$logfile"
    (cd "$t/project" && env "$bad" pi "$run_sh" pi)
    expect_status 2 "a run refuses [$bad]"
    log_lacks "CALL" "a bad config [$bad] touches no container"
  done
  contains "openrouter is refused offline" "$(e)" "offline with the default model_url names why"
  # A config.json from before the env vars is refused, so an offline one
  # cannot silently turn into a standard-egress run.
  printf '{"v":1,"egress":"offline","model_url":"http://gateway:8090"}\n' > "$cfg/config.json"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" pi)
  expect_status 2 "a run refuses a leftover config.json"
  contains "$cfg/config.json is no longer read; set PI_EGRESS='offline' PI_MODEL_URL='http://gateway:8090'" "$(e)" "the refusal names the env vars"
  log_lacks "CALL" "a leftover config.json touches no container"
  run_it env HOME="$home" bash "$run_sh" config --json
  expect_status 2 "config refuses a leftover config.json"
  run_it env HOME="$home" bash "$clear_sh" list
  expect_status 1 "clear.sh refuses a leftover config.json"
  contains "no longer read" "$(e)" "clear.sh names the leftover config.json"
  rm -f "$cfg/config.json"
  for bad in "--image agent" "--image agent-min" "--egress normal" "--model-url https://gateway:8090" "--model-url http://gateway"; do
    # shellcheck disable=SC2086
    run_it env HOME="$home" bash "$run_sh" $bad config
    expect_status 2 "flag refused [$bad]"
  done
  run_it env HOME="$home" bash "$run_sh" --image
  expect_status 2 "--image needs a value"
}

case_images_command() {
  new_case imagescmd
  image_json 1.4.0 "netlock,pi" > "$world/images/pi-min_local.json"
  PI_IMAGE=min pi "$run_sh" images
  expect_status 0 "images"
  local out
  out=$(o)
  contains "* min     pi-min:local     yes    netlock,pi" "$out" "min is built and effective"
  contains "  full    pi-full:local    no     enforcer,netlock,pi,gh" "$out" "full is not built"
  contains "  zig     pi-zig:local     no     zig,zigpeek,enforcer,netlock,pi,gh,nvim,zls" "$out" "zig listed"
  contains "  tools   pi-tools:local" "$out" "tools listed"
  contains "  editor  pi-editor:local" "$out" "editor listed"
  not_contains "agent" "$out" "no agent pack"
  contains "the effective image (env)" "$out" "the effective image's source"
  mkdir -p "$world/fail"
  : > "$world/fail/system"
  pi "$run_sh" images
  expect_status 0 "images with the runtime down"
  contains "pi-min:local     ?" "$(o)" "built is unknown when the runtime is down"
  contains "not answering" "$(e)" "runtime down is named"
}

# ------------------------------------------------------- min: no enforcer
# min records netlock and pi but not enforcer. Every locked mode still
# runs it; check gates its enforcer probe on the capability instead of
# refusing the image.
case_min() {
  new_case min
  fleet_world
  image_json 1.4.0 "netlock,pi" > "$world/images/pi-min_local.json"
  local st cmd
  mkdir -p "$home/.pic/fleet/sessions/s1/state"
  st=$(cd "$home/.pic/fleet/sessions/s1/state" && pwd -P)
  for cmd in "pi" "check owner/repo" "--fleet-state $st --clone owner/repo pi --mode json"; do
    : > "$logfile"
    # shellcheck disable=SC2086
    (cd "$t/project" && run_it env HOME="$home" PI_ENV_FILE="$cfg/env" PI_IMAGE=min \
      CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" bash "$run_sh" $cmd)
    expect_status 0 "min: $cmd runs"
    contains 'image=pi-min:local pack=min capabilities=netlock,pi' "$(e)" "min: $cmd announces the pack"
    not_contains "lacks capability" "$(e)" "min: $cmd refuses nothing"
    log_has "--cap-add NET_ADMIN" "min: $cmd runs behind the egress lock"
  done
}

# check's enforcer probe, run here: it trusts the image's capabilities, and an
# image without them is legacy and must have enforcer.
case_enforcer_check_script() {
  new_case enforcercheck
  local script bin code out
  script=$(HOME="$home" PI_SOURCE_ONLY=1 bash -c '. "$1" && enforcer_check_script' _ "$run_sh")
  bash -n <(printf 's=0\n%s\n' "$script") && pass || fail "enforcer check script parses"
  bin="$t/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\n[ "$1" = hook ] || exit 1\ngrep -q ghp_ && exit 2\nexit 0\n' > "$bin/enforcer"
  chmod +x "$bin/enforcer"
  probe() { # PATH, [capabilities]
    code=0
    if [ $# -gt 1 ]; then
      out=$(env -i PATH="$1" PI_CONTAINER_CAPABILITIES="$2" bash -c "s=0
$script
exit \$s" 2>&1) || code=$?
    else
      out=$(env -i PATH="$1" bash -c "s=0
$script
exit \$s" 2>&1) || code=$?
    fi
  }
  probe "/usr/bin:/bin" "netlock,pi"
  eq 0 "$code" "no enforcer capability: no failure"
  contains "not in this pack" "$out" "no enforcer capability: reported as not in this pack"
  probe "$bin:/usr/bin:/bin" "enforcer,netlock,pi"
  eq 0 "$code" "enforcer capability: probe passes"
  contains "blocks ghp_" "$out" "enforcer capability: blocking rule checked"
  probe "/usr/bin:/bin" "enforcer,netlock,pi"
  eq 1 "$code" "enforcer listed but missing fails"
  contains "FAIL: enforcer is missing" "$out" "listed but missing is named"
  probe "/usr/bin:/bin"
  eq 1 "$code" "legacy image without enforcer fails"
  probe "$bin:/usr/bin:/bin"
  eq 0 "$code" "legacy image with enforcer passes"
}

# ----------------------------------------------------------- offline egress
offline_world() { # name
  new_case "$1"
  image_json 1.4.0 > "$world/images/pi-full_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy_local.json"
  network_json "172.30.240.0/24" > "$world/networks/pi-locked.json"
  default_network_json > "$world/networks/default.json"
  printf 'pi-locked\n' > "$world/networks.list"
  proxy_running_json > "$world/containers/pi-proxy.json"
  printf '172.30.240.2\n' > "$cfg/private/proxy.addr"
  printf 'GH_TOKEN=ghp_other\nGITHUB_PAT=ghp_pat\n' >> "$cfg/env"
  case_env="PI_MODEL_URL=http://gateway:8090"
}

offline_pi() { # args...
  (cd "$t/project" && pi "$run_sh" --egress offline "$@")
}

case_offline_run() {
  offline_world offline
  (cd "$t/project" && pi "$run_sh" pi)
  expect_status 0 "local model_url run without offline"
  contains "GITHUB_TOKEN=ghp_test" "$(cat "$cfg/pi.env")" "standard pi.env has the GitHub token"
  : > "$logfile"
  offline_pi pi
  expect_status 0 "offline run succeeds"
  contains 'egress=offline model_url=http://gateway:8090' "$(e)" "offline run announces the route"
  log_has "delete --force pi-proxy" "turning offline on recreates the proxy"
  log_lacks "build -t pi-proxy" "turning offline on does not rebuild the proxy image"
  log_lacks "build -t pi-full" "turning offline on does not build the agent image"
  log_has "run --rm -i --init --network pi-locked" "offline Pi runs on the locked network"
  log_has "--cap-add NET_ADMIN" "offline Pi still sets up the egress lock"
  log_has "OPENROUTER_API_KEY=sk-or-v1-placeholder" "offline Pi gets the placeholder key"
  log_lacks "sk-or-v1-real" "real key never appears in argv offline"
  log_lacks "ghp_" "no GitHub token in argv offline"
  [ -f "$cfg/pi.env" ] && pass || fail "offline pi.env was not written"
  eq 600 "$(stat -Lc %a "$cfg/pi.env" 2>/dev/null || stat -Lf %Lp "$cfg/pi.env")" "offline pi.env is mode 600"
  not_contains "ghp_" "$(cat "$cfg/pi.env")" "offline pi.env has no GitHub credential"
  not_contains "TOKEN" "$(cat "$cfg/pi.env")" "offline pi.env has no token variable"
  contains "GIT_AUTHOR_NAME=Test" "$(cat "$cfg/pi.env")" "offline pi.env keeps the commit identity"
  : > "$logfile"
  case_env="PI_EGRESS=offline PI_MODEL_URL=http://gateway:8090"
  (cd "$t/project" && pi "$run_sh" pi)
  expect_status 0 "offline from PI_EGRESS"
  contains 'egress=offline' "$(e)" "env egress announced"
  log_lacks "delete --force pi-proxy" "same offline settings keep the proxy"
  # Absent proxy: the new one gets the profile and the route. The fake
  # publishes no address, so the run then fails on the address wait.
  rm -f "$world/containers/pi-proxy.json"
  : > "$logfile"
  (cd "$t/project" && export PI_PROXY_WAIT=0 && pi "$run_sh" pi)
  log_has "-e PI_PROXY_EGRESS=offline -e PI_PROXY_TUNNEL= -e PI_PROXY_MODEL_RULE=private -e PI_PROXY_MODEL_HOST=192.168.64.1 -e PI_PROXY_MODEL_PORT=8090" "offline reaches the proxy"
  log_lacks "build -t pi-proxy" "a new offline proxy reuses the image"
  # Back to standard: the proxy is recreated without the profile, the token returns.
  proxy_running_json > "$world/containers/pi-proxy.json"
  : > "$logfile"
  (cd "$t/project" && export PI_PROXY_WAIT=0 && pi "$run_sh" --egress standard pi)
  log_has "delete --force pi-proxy" "turning offline off recreates the proxy"
  log_lacks "PI_PROXY_EGRESS=offline" "standard proxy gets no offline profile"
  log_lacks "build -t pi-proxy" "turning offline off does not rebuild the proxy image"
  contains "GITHUB_TOKEN=ghp_test" "$(cat "$cfg/pi.env")" "standard pi.env has the GitHub token again"
}

case_offline_refusals() {
  offline_world offlinerefuse
  local u flag
  for u in openrouter http://1.1.1.1:8090 http://127.0.0.1:8090 http://models.lan:8090; do
    : > "$logfile"
    offline_pi --model-url "$u" pi
    expect_status 2 "offline refuses model_url [$u]"
    contains 'egress offline needs model_url' "$(e)" "offline names the model_url [$u]"
    log_lacks "CALL" "offline [$u] starts nothing"
  done
  for flag in --allow-egress --manual; do
    : > "$logfile"
    offline_pi "$flag"
    expect_status 2 "offline refuses $flag"
    contains 'egress offline needs pi-proxy' "$(e)" "offline $flag message"
    log_lacks "CALL run" "offline $flag starts nothing"
  done
  : > "$logfile"
  offline_pi --clone owner/repo
  expect_status 2 "offline --clone without a mirror is refused"
  contains "needs a local mirror. Make it with: git clone --mirror https://github.com/owner/repo.git $cfg/mirrors/owner/repo.git" "$(e)" "offline --clone names the mirror command"
  log_lacks "CALL run" "offline --clone without a mirror starts nothing"
  git init -q --bare "$cfg/mirrors/owner/repo.git"
  : > "$logfile"
  offline_pi --clone owner/repo
  expect_status 0 "offline --clone with a mirror runs"
  log_has "-v $cfg/mirrors/owner/repo.git:$cfg/mirrors/owner/repo.git:ro -e PI_CLONE_SOURCE=$cfg/mirrors/owner/repo.git" "the mirror is mounted read-only"
  rm -rf "$cfg/mirrors"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --egress Offline pi)
  expect_status 2 "unknown egress refused"
  contains '--egress must be a profile name' "$(e)" "bad egress name named"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --egress lab pi)
  expect_status 2 "absent profile refused"
  contains "egress \"lab\" is neither built in" "$(e)" "absent profile named"
  log_lacks "CALL run" "absent profile starts nothing"
  mkdir -p "$cfg/egress"
  printf '{"v":1,"tunnel":["openrouter.ai"],"model_url":"any","github_token":false}\n' > "$cfg/egress/lab.json"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --egress lab pi)
  expect_status 2 "bad profile refused"
  contains "cannot list openrouter.ai" "$(e)" "bad profile names why"
  printf '{"v":1,"tunnel":["pypi.org"],"model_url":"any","github_token":false}\n' > "$cfg/egress/lab.json"
  : > "$logfile"
  (cd "$t/project" && pi "$run_sh" --egress lab config --json)
  expect_status 0 "user profile config"
  eq 'lab ["pypi.org"] false' "$(o | jq -r '"\(.egress) \(.egress_profile.tunnel | tojson) \(.egress_profile.github_token)"')" "user profile in config --json"
  rm -rf "$cfg/egress"
  # The pre-config variables are gone: setting them changes nothing.
  : > "$logfile"
  (cd "$t/project" && export PI_PROXY_OPENROUTER_HOST=10.0.0.9 && pi "$run_sh" pi)
  expect_status 0 "a removed variable is ignored"
  log_lacks "10.0.0.9" "PI_PROXY_OPENROUTER_HOST is ignored"
  : > "$logfile"
  (cd "$t/project" && export PI_IMAGE=pi-min:local && pi "$run_sh" pi)
  expect_status 2 "PI_IMAGE takes a pack name, not a tag"
  contains "PI_IMAGE must be min, full or zig" "$(e)" "bad PI_IMAGE named"
  : > "$logfile"
  (cd "$t/project" && export PI_IMAGE=min PI_EGRESS=offline PI_MODEL_URL=http://gateway:8090 && pi "$run_sh" config --json > "$tmp/out")
  eq "min env offline env http://gateway:8090 env" "$(jq -r '"\(.image) \(.source.image) \(.egress) \(.source.egress) \(.model_url) \(.source.model_url)"' "$tmp/out")" "env vars set the config"
  (cd "$t/project" && export PI_IMAGE=min && pi "$run_sh" --image zig config --json > "$tmp/out")
  eq "zig flag" "$(jq -r '"\(.image) \(.source.image)"' "$tmp/out")" "a flag beats the env var"
}

# A fake VM curl for check. The VM environment is only what run.sh passes, so
# the answers live next to the stub: pi-proxy reports DIR/egress (offline) and
# answers GitHub's CONNECT with DIR/connect (403); nothing else answers.
fake_vm_curl() { # dir
  mkdir -p "$1"
  cat > "$1/curl" <<'CURL'
#!/usr/bin/env bash
url="" w=""
while [ $# -gt 0 ]; do
  case $1 in
    -w) w=$2; shift 2 ;;
    -m|-o|--cacert|--noproxy) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case $url in
  */egress) cat "$(dirname "$0")/egress" 2>/dev/null || echo offline ;;
  https://openrouter.ai/api/v1/key) printf '{"data":{"label":"local","limit":null}}\n' ;;
  https://github.com/|https://api.github.com/)
    [ "$w" != '%{http_connect}' ] || cat "$(dirname "$0")/connect" 2>/dev/null || printf 403; exit 56 ;;
  *) [ -z "$w" ] || printf '000'; exit 7 ;;
esac
CURL
  chmod +x "$1/curl"
}

case_offline_check() {
  offline_world offlinecheck
  fake_vm_curl "$t/vmbin"
  mkdir -p "$t/disk"
  offline_pi check
  log_has "check '' offline" "check passes the mode to the VM"
  contains 'egress     offline' "$(o)" "offline check starts with the config summary"
  log_lacks "ghp_test" "offline check mounts no token"
  : > "$logfile"
  (
    cd "$t/project" || exit 1
    export FAKE_CONTAINER_EXEC="$t/disk" FAKE_CONTAINER_PATH="$t/vmbin"
    pi "$run_sh" --egress offline check
  )
  local out
  out=$(o)
  contains 'profile offline: tunnel none, model_url private, token false' "$out" "check reports the profile"
  contains 'pi-proxy enforces offline' "$out" "check confirms the proxy's mode"
  contains 'no GitHub token in the VM' "$out" "check asserts the token is absent"
  contains 'github.com refused by pi-proxy' "$out" "check asserts github.com is refused"
  contains 'api.github.com refused by pi-proxy' "$out" "check asserts api.github.com is refused"
  contains '"label": "local"' "$out" "check reaches the local upstream"
  not_contains 'skipping GitHub checks' "$out" "offline check does not skip GitHub"
  not_contains 'no credit limit' "$out" "offline check does not warn about OpenRouter credit"
  not_contains 'FAIL: pi-proxy' "$out" "offline check has no proxy failures"
  not_contains 'FAIL: GITHUB_TOKEN' "$out" "offline check sees no token"
  : > "$logfile"
  printf 'normal\n' > "$t/vmbin/egress"
  printf 200 > "$t/vmbin/connect"
  (
    cd "$t/project" || exit 1
    export FAKE_CONTAINER_EXEC="$t/disk" FAKE_CONTAINER_PATH="$t/vmbin"
    pi "$run_sh" --egress offline check
  )
  out=$(o)
  contains "FAIL: pi-proxy reports egress 'normal', not offline" "$out" "check fails when the proxy is not offline"
  contains 'FAIL: pi-proxy did not refuse github.com (CONNECT 200)' "$out" "check fails when GitHub is reachable"
  [ "$(s)" != 0 ] && pass || fail "offline check exits nonzero on failures"
}

# ------------------------------------------------------------------- drivers
# ---------------------------------------------------------------- ~/.pic
case_pic_home() {
  new_case pichome
  local old
  for old in .config/pi-container pi-backups .fleet; do
    mkdir -p "$home/$old"
    pi "$run_sh" config
    expect_status 2 "run.sh refuses a leftover ~/$old"
    contains "run pic migrate to move $home/$old" "$(e)" "the refusal names ~/$old"
    pi "$clear_sh" list
    expect_status 1 "clear.sh refuses a leftover ~/$old"
    contains "pic migrate" "$(e)" "clear.sh names pic migrate for ~/$old"
    rmdir "$home/$old"
  done
  mkdir -p "$home/pi-backups"
  printf '# pic overrides v1, written x by pic migrate at y\nPI_BACKUP_DIR=%s\n' "$home/pi-backups" > "$home/.pic/overrides.env"
  chmod 600 "$home/.pic/overrides.env"
  pi "$run_sh" config
  expect_status 0 "backups kept by overrides.env are not refused"
  chmod 644 "$home/.pic/overrides.env"
  pi "$run_sh" config
  expect_status 2 "a group-readable overrides.env is refused"
  contains "overrides.env must be mode 600" "$(e)" "the refusal names the mode"
  pi "$clear_sh" list
  expect_status 2 "clear.sh refuses it too"
  printf '# pic overrides v2\n' > "$home/.pic/overrides.env"
  chmod 600 "$home/.pic/overrides.env"
  pi "$run_sh" config
  expect_status 2 "another overrides.env version is refused"
  contains "reads only v1" "$(e)" "the refusal names the version"
  rm -f "$home/.pic/overrides.env" && rmdir "$home/pi-backups"
  mkdir -p "$home/.pic/profiles/x/proj"
  (cd "$home/.pic/profiles/x/proj" && pi "$run_sh" pi)
  expect_status 1 "refuses to mount a folder in ~/.pic"
  contains "holds every profile's keys" "$(e)" "the mount refusal names ~/.pic"
}

# A v7 layout: the default profile, backups, fleet data and profile "dev".
v7_home() { # name
  t="$tmp/$1" home="$t/home" world="$t/world" logfile="$t/log"
  mkdir -p "$home/.config/pi-container/private" "$home/pi-backups/20260101" "$home/.fleet/sessions/s1" \
    "$home/.config/pi-container-dev" "$world/images" "$world/networks" "$world/containers" "$world/volumes"
  printf 'OPENROUTER_API_KEY=sk-or-v1-real\n' > "$home/.config/pi-container/env"
  chmod 600 "$home/.config/pi-container/env"
  : > "$home/pi-backups/20260101/s.jsonl"
}

migrate() { # answers
  printf '%b' "$1" | run_it env HOME="$home" CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" \
    FAKE_CONTAINER_LOG="$logfile" bash "$run_sh" migrate
}

case_migrate() {
  v7_home migrate
  # profile, backups, keep?, fleet, another profile, move dev?, go ahead?
  migrate '\n\nn\n\n-\ny\ny\n'
  expect_status 0 "migrate moves a v7 layout"
  [ -f "$home/.pic/config/env" ] && pass || fail "the env file moved with the default profile"
  [ -f "$home/.pic/backups/20260101/s.jsonl" ] && pass || fail "backups moved"
  [ -d "$home/.pic/fleet/sessions/s1" ] && pass || fail "fleet data moved"
  [ -d "$home/.pic/profiles/dev" ] && pass || fail "profile dev moved"
  [ ! -e "$home/.config/pi-container" ] && [ ! -e "$home/pi-backups" ] && [ ! -e "$home/.fleet" ] &&
    [ ! -e "$home/.config/pi-container-dev" ] && pass || fail "a v7 path is left behind"
  eq 700 "$(pi_file_mode "$home/.pic")" "~/.pic is mode 700"
  eq 600 "$(pi_file_mode "$home/.pic/overrides.env")" "overrides.env is mode 600"
  contains "# pic overrides v1, written " "$(head -n 1 "$home/.pic/overrides.env")" "overrides.env has the v1 header"
  contains "# moved $home/.config/pi-container-dev -> $home/.pic/profiles/dev" "$(cat "$home/.pic/overrides.env")" "overrides.env records the moves"
  not_contains "PI_BACKUP_DIR" "$(cat "$home/.pic/overrides.env")" "nothing kept, nothing overridden"
  not_contains "sk-or-v1-real" "$(o)$(e)" "migrate prints no key"
  run_it env HOME="$home" PI_ENV_FILE="$home/.pic/config/env" bash "$run_sh" config
  expect_status 0 "run.sh runs after the migration"
  migrate '\n'
  expect_status 1 "a second migrate exits early"
  contains "already exists" "$(e)" "it names the existing ~/.pic"

  v7_home migrate-keep
  migrate '\n\ny\n\n-\nn\ny\n'
  expect_status 0 "migrate keeps the backups when asked"
  [ -f "$home/pi-backups/20260101/s.jsonl" ] && pass || fail "kept backups stay"
  contains "PI_BACKUP_DIR=$home/pi-backups" "$(cat "$home/.pic/overrides.env")" "overrides.env names the kept backups"
  [ -d "$home/.config/pi-container-dev" ] && pass || fail "a declined profile stays"
  run_it env HOME="$home" PI_ENV_FILE="$home/.pic/config/env" bash "$run_sh" config
  expect_status 0 "kept backups don't block run.sh"

  v7_home migrate-abort
  migrate '\n\nn\n\n-\nn\nn\n'
  expect_status 1 "declining the plan aborts"
  [ ! -e "$home/.pic" ] && [ -d "$home/.config/pi-container" ] && pass || fail "an aborted migrate changed something"

  v7_home migrate-proxy
  proxy_running_json > "$world/containers/pi-proxy.json"
  migrate '\n\nn\n\n-\ny\ny\n'
  expect_status 1 "migrate refuses while pi-proxy runs"
  contains "pic proxy-stop" "$(e)" "the refusal says how to stop it"
  [ ! -e "$home/.pic" ] && pass || fail "a refused migrate created ~/.pic"

  v7_home migrate-v2
  mkdir -p "$home/.pic"
  migrate '\n'
  expect_status 1 "migrate exits early when ~/.pic exists"
  [ -d "$home/.config/pi-container" ] && pass || fail "an early exit moved something"
}

for c in case_normal_run case_check_enforcer case_tokenless_run case_tokenless_check case_pack_missing_pi \
         case_egress_run case_egress_clone case_egress_refusals case_egress_requires_key \
         case_network_nat_refused case_network_escaped_subnet \
         case_proxy_unknown_state case_manual_clone case_manual_clone_env case_manual_clone_env_mode \
         case_clear_list case_clear_list_runtime_down case_clear_list_legacy_volume \
         case_clear_list_dead_profile \
         case_nuke_agent case_nuke_agent_without_image case_nuke_clones_scoped \
         case_nuke_profile case_nuke_profile_rejects_instance \
         case_option_guards case_nuke_all case_mount_guards case_fleet_state case_pi_ctr_stop \
         case_netlock_modes case_netlock_capability case_proxy_running_no_addr case_model_url \
         case_config_command case_images_command \
         case_min case_enforcer_check_script case_offline_run case_offline_refusals case_offline_check \
         case_pic_home case_migrate; do
  "$c"
done

finish

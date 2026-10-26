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
  PI_IMAGE PI_NVIM_CONFIG PI_NVIM_DATA PI_NVIM_STATE PI_NVIM_CACHE \
  PI_CPUS PI_MEMORY PI_PROXY_WAIT PI_LOCK_WAIT PI_SOURCE_ONLY TZ COLORTERM

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

# Create an isolated world and config. Sets: t, home, cfg, world, logfile.
new_case() { # name
  t="$tmp/$1"
  home="$t/home"
  # Use the default profile so names stay pi-locked/pi-proxy/pi-agent-home.
  cfg="$home/.config/pi-container"
  world="$t/world"
  logfile="$t/log"
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
image_json() { # version
  printf '[{"id":"sha256:test","configuration":{"descriptor":{"digest":"sha256:test"},"name":"pi-agent:local"},"variants":[{"config":{"config":{"Env":["PI_CONTAINER_PI_VERSION=%s"]},"history":[]}}]}]' "$1"
}

network_json() { # subnet [mode] [internal]
  local subnet=$1 mode=${2:-hostOnly} internal=${3:-} internal_field=""
  [ -z "$internal" ] || internal_field=",\"internal\":$internal"
  printf '[{"configuration":{"name":"pi-locked","mode":"%s","ipv4Subnet":"%s"%s},"id":"pi-locked","status":{"ipv4Gateway":"172.30.240.1","ipv4Subnet":"%s"}}]' \
    "$mode" "$subnet" "$internal_field" "$subnet"
}

proxy_running_json() {
  printf '[{"id":"pi-proxy","configuration":{"name":"pi-proxy"},"status":{"state":"running"}}]'
}

# Run a pi-container script in the isolated world. The default profile is used,
# so PI_CONFIG_DIR stays unset and cfg resolves to $HOME/.config/pi-container.
pi() { # script, args...
  local script=$1
  shift
  run_it env HOME="$home" PI_ENV_FILE="$cfg/env" \
    CONTAINER_CLI="$fake" FAKE_CONTAINER_WORLD="$world" FAKE_CONTAINER_LOG="$logfile" \
    bash "$script" "$@"
}

# ---------------------------------------------------------------- normal run
case_normal_run() {
  new_case normal
  image_json 1.4.0 > "$world/images/pi-agent_local.json"
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
  log_has "pi-agent:local" "agent image named"
  log_has "volume create" "agent volume created"
  log_has "build -t pi-proxy:local" "proxy image built on first run"
  log_has "delete --force pi-proxy" "stale proxy deleted before rebuild"
  log_has "exec pi-proxy" "proxy health checked from inside"
  log_has "/root/.pi/agent/settings.json:ro" "settings mounted read-only"
  log_lacks "network create" "existing host-only network reused"
  [ -f "$cfg/settings.json" ] && pass || fail "settings.json was not created"
  local settings
  settings=$(cat "$cfg/settings.json" 2>/dev/null || true)
  contains 'lastChangelogVersion' "$settings" "settings seeds lastChangelogVersion"
  contains '1.4.0' "$settings" "settings version comes from image env"
  contains 'deepseek/deepseek-v4.1-flash-1017' "$settings" "default model seeded"
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

# ------------------------------------------------------ network shape guards
case_network_nat_refused() {
  new_case nat
  image_json 1.4.0 > "$world/images/pi-agent_local.json"
  network_json "192.168.64.0/24" nat false > "$world/networks/pi-locked.json"
  printf 'pi-locked\n' > "$world/networks.list"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" pi
  )
  expect_status 1 "NAT network is refused"
  contains 'not host-only/internal' "$(e)" "refusal names the reason"
  log_lacks "run --rm" "no container run after refusal"
}

case_network_escaped_subnet() {
  new_case escaped
  image_json 1.4.0 > "$world/images/pi-agent_local.json"
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
  image_json 1.4.0 > "$world/images/pi-agent_local.json"
  (
    cd "$t/project" || exit 1
    pi "$run_sh" --manual --clone owner/repo true
  )
  expect_status 0 "manual clone succeeds"
  log_has "pi-clone_default_owner-repo-" "clone volume named"
  log_has "PI_CLONE=owner/repo" "clone target passed"
  log_has "-w /work" "clone workdir set"
  log_has "ZIG_LOCAL_CACHE_DIR=/root/.cache/zig-local/" "zig local cache redirected"
  log_has "/root/.config/nvim" "nvim config mounted"
  log_lacks "--env-file" "no pi.env mounted when absent"
  [ -f "$cfg/nvim/init.lua" ] && pass || fail "nvim init.lua was not seeded"
}

# ------------------------------------------------------------ clear.sh list
case_clear_list() {
  new_case list
  image_json 1.4.0 > "$world/images/pi-agent_local.json"
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

# ---------------------------------------------------- clear.sh save + nuke agent
case_nuke_agent() {
  new_case nukeagent
  image_json 1.4.0 > "$world/images/pi-agent_local.json"
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

# --------------------------------------------- proxy container unknown state
case_proxy_unknown_state() {
  new_case proxyunknown
  image_json 1.4.0 > "$world/images/pi-agent_local.json"
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
  log_lacks "network create" "help has no side effects"
}

# ---------------------------------------- nuke all with a failed builder delete
case_nuke_all_builder_failure() {
  new_case nukeall
  image_json 1.4.0 > "$world/images/pi-agent_local.json"
  image_json 1.4.0 > "$world/images/pi-proxy_local.json"
  network_json "172.30.240.0/24" > "$world/networks/pi-locked.json"
  printf 'pi-locked\n' > "$world/networks.list"
  proxy_running_json > "$world/containers/pi-proxy.json"
  printf 'pi-agent-home\n' > "$world/volumes.list"
  vol_json pi-agent-home agent default "$cfg" "$cfg/settings.json" \
    > "$world/volumes/pi-agent-home.json"
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
  log_has "volume delete pi-agent-home" "agent volume deleted"
}

# ------------------------------------------------------------------- drivers
for c in case_normal_run case_network_nat_refused case_network_escaped_subnet \
         case_proxy_unknown_state case_manual_clone case_clear_list case_nuke_agent case_nuke_clones_scoped \
         case_option_guards case_nuke_all_builder_failure case_mount_guards; do
  "$c"
done

finish

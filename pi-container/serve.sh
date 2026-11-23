#!/usr/bin/env bash
# pic serve: run this Mac as a fleet node whose built-in harness is pi-ctr.
#
#   run.sh serve [--check] [fleetd flags]
#
# Checks Tailscale (logged in as a user, not a tagged device, HTTPS
# certificates on), the container system, the agent image, the env file (mode 600 or
# 400, real OpenRouter key and GITHUB_TOKEN), that this shell does not hold the real
# key, the fleetd binary and the port. If any check fails it prints all of
# them and refuses to start. --check stops after the checks.
#
# Then it runs fleetd and a foreground `tailscale serve --https=443` in front
# of it. Ctrl-C, or either one exiting, stops both, and the serve config goes
# with the tailscale process.
# -name, -url and -owner default to this Mac's Tailscale name, URL and login.
#
#   FLEETD      fleetd binary (default: fleet/bin/fleetd from build.sh fleet)
#   FLEET_PORT  loopback port (default 7433)
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(CDPATH= cd -- "$here/.." && pwd -P)
. "$here/names.sh"
. "$here/lib/paths.sh"
cfg="${PI_CONFIG_DIR:-$(pi_default_config_dir)}"
env_file="${PI_ENV_FILE:-$cfg/env}"
cli="${CONTAINER_CLI:-container}"
image="${PI_IMAGE:-pi-agent:local}"
fleetd="${FLEETD:-$root/fleet/bin/fleetd}"
port="${FLEET_PORT:-7433}"
placeholder=sk-or-v1-placeholder

check=0
if [ "${1:-}" = --check ]; then check=1; shift; fi
has_name=0 has_url=0 has_owner=0
for a in "$@"; do
  case $a in
    -listen|-listen=*|--listen|--listen=*) echo "pic serve: set FLEET_PORT instead of -listen" >&2; exit 2 ;;
    -name|-name=*|--name|--name=*) has_name=1 ;;
    -url|-url=*|--url|--url=*) has_url=1 ;;
    -owner|-owner=*|--owner|--owner=*) has_owner=1 ;;
  esac
done

bad=0
ok() { printf 'ok    %s\n' "$*" >&2; }
no() { printf 'FAIL  %s\n' "$*" >&2; bad=1; }

dns="" login="" host=""
if ! ts=$(tailscale status --json 2>/dev/null) || ! jq -e . >/dev/null 2>&1 <<<"$ts"; then
  no "tailscale status failed; is the Tailscale app installed and running?"
else
  state=$(jq -r '.BackendState // ""' <<<"$ts")
  if [ "$state" = Running ]; then ok "Tailscale is running"
  else no "Tailscale is not logged in (state ${state:-unknown}); log in from the menu bar app"; fi
  tags=$(jq -r '(.Self.Tags // []) | join(",")' <<<"$ts")
  login=$(jq -r '(.Self.UserID | tostring) as $u | .User[$u].LoginName // ""' <<<"$ts")
  if [ -n "$tags" ]; then
    no "this Mac is a tagged device ($tags); log it in as your own user, so fleet's owner is a person"
    login=""
  elif [ -z "$login" ]; then no "cannot tell which user Tailscale is logged in as"
  else ok "logged in as $login"; fi
  dns=$(jq -r '.Self.DNSName // "" | rtrimstr(".")' <<<"$ts")
  host=$(jq -r '.Self.HostName // ""' <<<"$ts" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-')
  if [ -n "$dns" ] && jq -e --arg d "$dns" '(.CertDomains // []) | any(.[]; . == $d)' >/dev/null <<<"$ts"; then
    ok "HTTPS certificates are on for $dns"
  else
    no "HTTPS certificates are off for ${dns:-this Mac}; turn on HTTPS on the DNS page of the Tailscale admin console"
  fi
fi

if "$cli" system status >/dev/null 2>&1; then ok "container system is running"
else no "the container system is not running; run: container system start"; fi
if "$cli" image inspect "$image" >/dev/null 2>&1; then ok "image $image is built"
else no "image $image is missing; run: $here/build.sh"; fi

if [ ! -r "$env_file" ]; then
  no "no env file at $env_file; see pi-container/README.md"
else
  case $(pi_file_mode "$env_file") in
    600|400) ok "$env_file is mode $(pi_file_mode "$env_file")" ;;
    *) no "$env_file must be mode 600 (chmod 600 $env_file); run.sh refuses it otherwise" ;;
  esac
  if grep -q '^OPENROUTER_API_KEY=.' "$env_file" && ! grep -q "^OPENROUTER_API_KEY=$placeholder[[:space:]]*$" "$env_file"; then
    ok "OpenRouter key is in $env_file, for the proxy"
  else no "set OPENROUTER_API_KEY in $env_file"; fi
  if grep -q '^GITHUB_TOKEN=.' "$env_file"; then ok "GITHUB_TOKEN is in $env_file"
  else no "set GITHUB_TOKEN in $env_file: a fine-grained token, selected repos, Contents read and write only"; fi
fi
case ${OPENROUTER_API_KEY:-} in
  ''|"$placeholder") ok "fleetd will not hold the OpenRouter key" ;;
  *) no "OPENROUTER_API_KEY is set in this shell; unset it. The proxy reads the key from $env_file, and fleetd must not have it" ;;
esac

if [ -x "$fleetd" ]; then ok "fleetd is $fleetd"
else no "no fleetd at $fleetd; run: $here/build.sh fleet"; fi
if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/"; then
  no "something already listens on 127.0.0.1:$port"
else ok "port $port is free"; fi

if [ "$bad" != 0 ]; then
  echo "pic serve: not starting; fix the FAIL lines above" >&2
  exit 1
fi
if [ "$check" = 1 ]; then
  echo "pic serve: ready" >&2
  exit 0
fi

defaults=()
[ "$has_name" = 1 ] || defaults+=(-name "${host:-mac}")
[ "$has_url" = 1 ] || defaults+=(-url "https://$dns")
[ "$has_owner" = 1 ] || defaults+=(-owner "$login")
echo "pic serve: https://$dns -> 127.0.0.1:$port" >&2
fpid="" spid=""
stop() {
  trap - INT TERM EXIT
  for p in $spid $fpid; do kill -TERM "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap 'stop; exit 130' INT
trap 'stop; exit 143' TERM
trap stop EXIT
env -u OPENROUTER_API_KEY FLEET_PI_CTR_BIN="$here/pi-ctr" \
  "$fleetd" -listen "127.0.0.1:$port" ${defaults[@]+"${defaults[@]}"} "$@" &
fpid=$!
tailscale serve --https=443 "http://127.0.0.1:$port" &
spid=$!
while kill -0 "$fpid" 2>/dev/null && kill -0 "$spid" 2>/dev/null; do sleep 1; done
echo "pic serve: $(kill -0 "$fpid" 2>/dev/null && echo 'tailscale serve' || echo fleetd) exited; stopping" >&2
exit 1

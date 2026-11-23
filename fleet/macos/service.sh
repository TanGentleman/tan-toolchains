#!/bin/sh
# Optional: run fleetd as a per-user LaunchAgent, with a persistent
# `tailscale serve` in front. fleet-up is the default; use this only if
# fleetd should start at login. launchd does not keep the Mac awake.
#
#   service.sh install [--no-serve] -- -name mac1 -url https://... -owner you@github [fleetd flags]
#   service.sh status
#   service.sh uninstall    # removes only what install added; ~/.fleet stays
#
#   FLEET_PORT  loopback port (default 7433)
#   FLEET_LOG   log file (default ~/Library/Logs/fleetd.log), rotated at start
set -eu
here=$(cd "$(dirname "$0")" && pwd -P)
label=dev.fleet.fleetd
plist=${FLEET_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}/$label.plist
record=${FLEET_SERVICE_RECORD:-$HOME/.config/fleet/service.installed}
log=${FLEET_LOG:-$HOME/Library/Logs/fleetd.log}
port=${FLEET_PORT:-7433}
domain=gui/$(id -u)
die() { echo "service.sh: $*" >&2; exit 1; }

install() {
  serve=1
  while [ $# -gt 0 ]; do
    case $1 in
      --no-serve) serve=0; shift ;;
      --) shift; break ;;
      *) die "unknown option $1; fleetd flags go after --" ;;
    esac
  done
  for a in "$@"; do
    case $a in -listen|-listen=*|--listen|--listen=*) die "set FLEET_PORT instead of -listen" ;; esac
  done
  [ $# -gt 0 ] || die "give fleetd flags after --, e.g. -- -name mac1 -url https://... -owner you@github"
  [ ! -e "$plist" ] && [ ! -e "$record" ] || die "already installed; run: $0 uninstall"
  [ -r "${FLEET_ENV:-$HOME/.config/fleet/env}" ] || die "no key file; see docs/macos.md step 6"
  launchctl print "$domain" >/dev/null 2>&1 ||
    die "no $domain launchd domain; install from a login at the Mac's own screen, not over SSH"
  if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/"; then
    die "something already listens on 127.0.0.1:$port; stop fleet-up first"
  fi
  if [ "$serve" = 1 ]; then
    cur=$(tailscale serve status --json) || die "tailscale serve status failed; is the Tailscale app running?"
    if [ "$(printf '%s' "${cur:-null}" | jq '[.TCP["443"]?, (.Foreground // {} | .[].TCP["443"]?)] | map(select(. != null)) | length')" != 0 ]; then
      die "tailscale already serves port 443, maybe a running fleet-up (tailscale serve status); stop it, or use --no-serve"
    fi
  fi
  mkdir -p "$(dirname "$plist")" "$(dirname "$record")" "$(dirname "$log")"
  # plistlib escapes every value; a heredoc would break on & or <.
  python3 - "$plist" "$label" "$log" "$here/fleetd-run" -listen "127.0.0.1:$port" "$@" <<'PY'
import plistlib, sys
path, label, log, *argv = sys.argv[1:]
with open(path, "wb") as f:
    plistlib.dump({
        "Label": label,
        "ProgramArguments": argv,
        "EnvironmentVariables": {"FLEET_LOG": log},
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 60,
    }, f)
PY
  plutil -lint "$plist" >/dev/null || { rm -f "$plist"; die "plutil rejected $plist"; }
  printf 'plist=%s\n' "$plist" >"$record"
  launchctl bootstrap "$domain" "$plist" || die "launchctl bootstrap failed; run: $0 uninstall"
  printf 'loaded=%s\n' "$label" >>"$record"
  if [ "$serve" = 1 ]; then
    tailscale serve --bg --https=443 "http://127.0.0.1:$port" >/dev/null || die "tailscale serve failed; run: $0 uninstall"
    printf 'serve=443\n' >>"$record"
  fi
  echo "installed $label; log: $log"
}

uninstall() {
  [ -r "$record" ] || die "nothing recorded in $record; was it installed with service.sh?"
  left=''
  if grep -qx "loaded=$label" "$record"; then
    launchctl bootout "$domain/$label" 2>/dev/null || true
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      left="${left}loaded=$label "
      echo "service.sh: $label is still loaded; try: launchctl bootout $domain/$label" >&2
    fi
  fi
  if grep -qx 'serve=443' "$record" && ! tailscale serve --https=443 off >/dev/null 2>&1; then
    left="${left}serve=443 "
    echo "service.sh: could not remove fleet's serve entry; with the Tailscale app running: tailscale serve --https=443 off" >&2
  fi
  p=$(sed -n 's/^plist=//p' "$record")
  [ -z "$p" ] || rm -f "$p"
  if [ -n "$left" ]; then
    printf '%s\n' $left >"$record"
    die "not fully uninstalled; fix the above and run uninstall again"
  fi
  rm -f "$record"
  echo "uninstalled $label; ~/.fleet, the key file and the log are left alone"
}

status() {
  launchctl print "$domain/$label" 2>/dev/null | grep -E '^[[:space:]]*(state|pid|last exit code) =' || echo "$label: not loaded"
  tailscale serve status 2>/dev/null || true
  [ ! -f "$log" ] || tail -n 5 "$log"
}

case ${1:-} in
  install) shift; install "$@" ;;
  uninstall) uninstall ;;
  status) status ;;
  *) die "usage: $0 install [--no-serve] -- FLEETD_FLAGS | uninstall | status" ;;
esac

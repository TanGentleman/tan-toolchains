#!/usr/bin/env bash
# fleet/macos scripts against fake launchctl, plutil and tailscale (e2e/macos/),
# so it runs anywhere. The real commands are checked on a Mac (docs/macos.md).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$tmp"' EXIT
fail() { echo "macos: FAIL: $*" >&2; [ ! -f "$FAKE/calls" ] || sed 's/^/  /' "$FAKE/calls" >&2; exit 1; }
go build -o "$tmp/fleetd" ./cmd/fleetd
export HOME=$tmp/home FAKE=$tmp/fake PATH="$PWD/e2e/macos:$PATH"
mkdir -p "$HOME/.config/fleet" "$FAKE"
export FLEETD=$tmp/fleetd
echo 'OPENROUTER_API_KEY=sk-or-v1-placeholder' >"$HOME/.config/fleet/env"
plist=$HOME/Library/LaunchAgents/dev.fleet.fleetd.plist
svc=macos/service.sh

# install: values with XML metacharacters survive, the restart policy can't
# loop fast, and serve is added after the agent is loaded.
echo '{"TCP":{"8443":{"HTTPS":true}},"Web":{"mac1.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9000"}}}}}' >"$FAKE/serve.json"
"$svc" install -- -name 'mac&1' -url 'https://mac1.ts.net' -owner '<me>@github' >/dev/null || fail install
python3 - "$plist" "$PWD/macos/fleetd-run" <<'PY' || fail "plist content"
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["ProgramArguments"] == [sys.argv[2], "-listen", "127.0.0.1:7433", "-name", "mac&1",
    "-url", "https://mac1.ts.net", "-owner", "<me>@github"], p["ProgramArguments"]
assert p["KeepAlive"] == {"SuccessfulExit": False} and p["ThrottleInterval"] >= 30, p
assert p["Label"] == "dev.fleet.fleetd" and p["EnvironmentVariables"]["FLEET_LOG"].endswith("fleetd.log"), p
PY
cmp -s "$plist" "$FAKE/loaded.plist" || fail "bootstrap did not load the plist"
[ "$(jq -r '.Web["mac1.ts.net:443"].Handlers["/"].Proxy' "$FAKE/serve.json")" = http://127.0.0.1:7433 ] || fail "serve not added"
"$svc" status | grep -q 'state = running' || fail status
"$svc" install -- -name x -owner y 2>/dev/null && fail "second install should refuse"

# uninstall: only fleet's 443 entry goes; another serve on 8443 stays.
"$svc" uninstall >/dev/null || fail uninstall
[ ! -e "$plist" ] && [ ! -e "$FAKE/loaded.plist" ] || fail "plist left behind"
[ "$(jq -c '.TCP | keys' "$FAKE/serve.json")" = '["8443"]' ] || fail "uninstall touched other serve config"
grep -q 'serve reset' "$FAKE/calls" && fail "used tailscale serve reset"
"$svc" uninstall 2>/dev/null && fail "second uninstall should refuse"

# Refuse to take over someone else's 443; --no-serve never touches serve.
echo '{"TCP":{"443":{"HTTPS":true}}}' >"$FAKE/serve.json"
"$svc" install -- -name a -owner b 2>/dev/null && fail "install over an existing 443"
[ ! -e "$plist" ] || fail "refused install left a plist"
: >"$FAKE/calls"
"$svc" install --no-serve -- -name a -owner b >/dev/null || fail "install --no-serve"
"$svc" uninstall >/dev/null || fail "uninstall --no-serve"
grep -q '^tailscale serve --' "$FAKE/calls" && fail "--no-serve changed serve config"
[ "$(jq -c '.TCP | keys' "$FAKE/serve.json")" = '["443"]' ] || fail "someone else's 443 changed"

# uninstall tries every step even when one fails, and can be rerun.
: >"$FAKE/calls"
echo '{}' >"$FAKE/serve.json"
"$svc" install -- -name a -owner b >/dev/null || fail "install for failing uninstall"
touch "$FAKE/no-tailscale"
"$svc" uninstall 2>/dev/null && fail "uninstall hid a failed serve off"
[ ! -e "$plist" ] && [ ! -e "$FAKE/loaded.plist" ] || fail "a failed serve off stopped the unload"
rm "$FAKE/no-tailscale"
"$svc" uninstall >/dev/null || fail "second uninstall after fixing tailscale"
[ "$(jq -c '.TCP // {} | keys' "$FAKE/serve.json")" = '[]' ] || fail "serve entry left after retry"

# install refuses, writing nothing: over SSH, over a running fleet-up's
# foreground serve or port, and with its own -listen.
touch "$FAKE/no-gui"
"$svc" install -- -name a -owner b 2>/dev/null && fail "install without a gui domain"
rm "$FAKE/no-gui"
echo '{"Foreground":{"s1":{"TCP":{"443":{"HTTPS":true}}}}}' >"$FAKE/serve.json"
"$svc" install -- -name a -owner b 2>/dev/null && fail "install over a foreground serve"
echo '{}' >"$FAKE/serve.json"
"$svc" install -- -name a -owner b -listen 127.0.0.1:1 2>/dev/null && fail "install with -listen"
busy=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -m http.server "$busy" --bind 127.0.0.1 >/dev/null 2>&1 &
pids+=($!)
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$busy/" && break; sleep 0.1; done
FLEET_PORT=$busy "$svc" install -- -name a -owner b 2>/dev/null && fail "install over a busy port"
[ ! -e "$plist" ] && [ ! -e "$HOME/.config/fleet/service.installed" ] || fail "a refused install left files"
macos/fleet-up -name a -owner b -listen 127.0.0.1:1 2>/dev/null && fail "fleet-up with -listen"

# fleetd-run: fails loudly without the key file, rotates its log at start.
FLEET_ENV=$tmp/none macos/fleetd-run -h 2>"$tmp/err" && fail "fleetd-run ran without a key file"
grep -q 'missing or unreadable' "$tmp/err" || fail "fleetd-run error message"
log=$tmp/fleetd.log
head -c 200 /dev/zero >"$log"
FLEET_LOG=$log FLEET_LOG_MAX=100 macos/fleetd-run -h || true
[ "$(wc -c <"$log.1")" -eq 200 ] && grep -q 'Usage' "$log" || fail "log not rotated"

# fleet-up: serves in the foreground (no --bg), and stopping it stops both.
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
: >"$FAKE/calls"
FLEET_PORT=$port macos/fleet-up -name up -url "http://127.0.0.1:$port" -owner t -data "$tmp/data" 2>"$tmp/up.log" &
up=$!
pids+=($up)
for _ in $(seq 100); do curl -fs -H 'Tailscale-User-Login: t' "http://127.0.0.1:$port/v1/node" >/dev/null && break; sleep 0.1; done
curl -fs -H 'Tailscale-User-Login: t' "http://127.0.0.1:$port/v1/node" | jq -e '.name == "up"' >/dev/null || fail "fleet-up: fleetd not answering"
grep -qx "tailscale serve --https=443 http://127.0.0.1:$port" "$FAKE/calls" || fail "fleet-up: serve not in the foreground"
kill -TERM "$up"
wait "$up" 2>/dev/null || true
grep -q 'tailscale foreground stopped' "$FAKE/calls" || fail "fleet-up left tailscale serve running"
curl -s -o /dev/null "http://127.0.0.1:$port/v1/node" && fail "fleet-up left fleetd running"
echo "macos: ok"

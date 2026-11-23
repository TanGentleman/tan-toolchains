#!/bin/sh
# Experimental fleet harness: Pi runs on the host, and every Pi tool call runs
# in a fresh external-sandbox-v86 Linux guest that mounts only $FLEET_WORK and
# has no network. See docs/sandbox.md.
#
#   fleetd -harness "pi-sbx=/path/to/fleet/sandbox/pi-v86.sh" ...
#
# FLEET_SANDBOX_PI_EXT  external-sandbox-pi's src/index.ts (required)
# FLEET_SANDBOX_V86     sandbox server (default: external-sandbox-v86 on PATH)
# FLEETD                fleetd binary (default: fleetd on PATH)
set -eu
: "${FLEET_WORK:?}" "${FLEET_SANDBOX_PI_EXT:?path to external-sandbox-pi/src/index.ts}"
[ -f "$FLEET_SANDBOX_PI_EXT" ] || { echo "pi-v86: no extension at $FLEET_SANDBOX_PI_EXT" >&2; exit 1; }
work=$(cd "$FLEET_WORK" && pwd -P)
log=$(mktemp)
"${FLEET_SANDBOX_V86:-external-sandbox-v86}" --port 0 --preserve-paths --mount-rw "work=$work" >"$log" 2>&1 &
sbx=$!
trap 'kill "$sbx" 2>/dev/null; rm -f "$log"' EXIT

i=0 url=
until [ -n "$url" ] && curl -fs "$url/health" | jq -e --arg w "$work" \
  '.status == "ready" and .network == false and ([.mounts[] | [.hostPath, .mode]] == [[$w, "rw"]])' >/dev/null; do
  kill -0 "$sbx" 2>/dev/null || { echo "pi-v86: sandbox exited" >&2; cat "$log" >&2; exit 1; }
  i=$((i + 1))
  [ "$i" -le 1200 ] || { echo "pi-v86: sandbox not ready" >&2; cat "$log" >&2; exit 1; }
  url=$(sed -n 's|^Listening on \(http://127\.0\.0\.1:[0-9]*\)$|\1|p' "$log")
  sleep 0.1
done

"${FLEETD:-fleetd}" agent pi -- -e "$FLEET_SANDBOX_PI_EXT" --no-builtin-tools --sandbox-url "$url"

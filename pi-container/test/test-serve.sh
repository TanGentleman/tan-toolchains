#!/usr/bin/env bash
# `run.sh serve` (serve.sh) against fake tailscale, container and fleetd:
# every refusal, and a real start and stop.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
unset PI_INSTANCE PI_CLONE PI_CONFIG_DIR PI_ENV_FILE PI_IMAGE OPENROUTER_API_KEY FLEETD FLEET_PORT

tmp=$(mktemp -d)
bg=""
trap '[ -z "$bg" ] || kill "$bg" 2>/dev/null; rm -rf "$tmp"' EXIT
home=$tmp/home cfg=$tmp/home/.config/pi-container world=$tmp/world bin=$tmp/bin
mkdir -p "$cfg" "$world/images" "$bin"
printf '[{"id":"sha256:t"}]' > "$world/images/pi-agent_local.json"
cat > "$bin/tailscale" <<'SH'
#!/usr/bin/env bash
echo "tailscale $*" >> "$TS_CALLS"
case "$*" in
  "status --json") [ -f "$TS_STATUS" ] && cat "$TS_STATUS" ;;
  "serve --https=443 "*) trap 'echo "tailscale stopped" >> "$TS_CALLS"; exit 0' TERM INT; while :; do sleep 0.1; done ;;
  *) exit 1 ;;
esac
SH
cat > "$bin/fleetd" <<'SH'
#!/usr/bin/env bash
{ printf 'ARG %s\n' "$@"; env; } > "$FAKE_FLEETD_OUT"
exec sleep 30
SH
chmod +x "$bin/tailscale" "$bin/fleetd"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')

reset() {
  rm -f "$cfg/env"
  printf 'OPENROUTER_API_KEY=sk-or-v1-real\nGITHUB_TOKEN=github_pat_test\n' > "$cfg/env"
  chmod 600 "$cfg/env"
  cp "$here/fixtures/tailscale/status.json" "$tmp/status.json"
  rm -rf "$world/fail"
  printf '[{"id":"sha256:t"}]' > "$world/images/pi-agent_local.json"
  : > "$tmp/calls"
}
ts() { jq "$1" "$here/fixtures/tailscale/status.json" > "$tmp/status.json"; }
pic() { # args... (run.sh serve, in the fake world)
  env HOME="$home" PATH="$bin:$PATH" TS_STATUS="$tmp/status.json" TS_CALLS="$tmp/calls" \
    CONTAINER_CLI="$here/fake-container.sh" FAKE_CONTAINER_WORLD="$world" FLEETD="$bin/fleetd" \
    FLEET_PORT="$port" FAKE_FLEETD_OUT="$tmp/fleetd.out" ${extra:+$extra} \
    bash "$root/run.sh" serve "$@"
}
serve() { # args...
  pic "$@" > "$tmp/out" 2>&1
  echo $? > "$tmp/status"
}
out() { cat "$tmp/out"; }
st() { cat "$tmp/status"; }
extra=""

reset; serve --check
eq 0 "$(st)" "all checks pass: $(out)"
contains "pic serve: ready" "$(out)"
contains "logged in as you@github" "$(out)"
not_contains "FAIL" "$(out)"

refuses() { # label, needle
  eq 1 "$(st)" "$1 refused"
  contains "$2" "$(out)" "$1"
  contains "not starting" "$(out)" "$1"
}
reset; ts '.Self.Tags = ["tag:server"]'; serve --check
refuses "tagged device" "this Mac is a tagged device (tag:server)"
reset; ts '.CertDomains = null'; serve --check
refuses "no HTTPS certificates" "HTTPS certificates are off for mac1.example-tailnet.ts.net"
reset; ts '.CertDomains = ["other.example-tailnet.ts.net"]'; serve --check
refuses "certificate for another name" "HTTPS certificates are off"
reset; ts '.BackendState = "NeedsLogin"'; serve --check
refuses "logged out" "Tailscale is not logged in (state NeedsLogin)"
reset; rm "$tmp/status.json"; serve --check
refuses "tailscale down" "tailscale status failed"
reset; mkdir -p "$world/fail"; : > "$world/fail/system"; serve --check
refuses "container stopped" "container system is not running"
reset; rm "$world/images/pi-agent_local.json"; serve --check
refuses "image missing" "image pi-agent:local is missing"
reset; printf 'OPENROUTER_API_KEY=sk-or-v1-placeholder\nGITHUB_TOKEN=x\n' > "$cfg/env"; serve --check
refuses "placeholder key" "set OPENROUTER_API_KEY in $cfg/env"
reset; printf 'OPENROUTER_API_KEY=sk-or-v1-real\n' > "$cfg/env"; serve --check
refuses "no GitHub token" "set GITHUB_TOKEN"
reset; chmod 644 "$cfg/env"; serve --check
refuses "env file mode 644" "$cfg/env must be mode 600"
reset; chmod 400 "$cfg/env"; serve --check
eq 0 "$(st)" "env file mode 400 passes: $(out)"
reset; rm "$cfg/env"; serve --check
refuses "no env file" "no env file"
reset; extra="OPENROUTER_API_KEY=sk-or-v1-real"; serve --check; extra=""
refuses "real key in the shell" "OPENROUTER_API_KEY is set in this shell"
reset; extra="FLEETD=$tmp/missing"; serve --check; extra=""
refuses "no fleetd" "build.sh fleet"
reset; ts '.Self.Tags = ["tag:x"]'; rm "$world/images/pi-agent_local.json"; serve --check
contains "tagged device" "$(out)" "every failure is listed"
contains "image pi-agent:local is missing" "$(out)" "every failure is listed"
reset; serve -listen 127.0.0.1:1
eq 2 "$(st)" "-listen refused"
rc 2 "serve with run options" env HOME="$home" bash "$root/run.sh" --clone o/r serve

# A real start: fleetd gets the Tailscale defaults, pi-ctr, no key; serve runs
# in the foreground, and TERM stops both.
reset
rm -f "$tmp/fleetd.out"
extra="OPENROUTER_API_KEY=sk-or-v1-placeholder"
# exec, so $bg is serve.sh itself and TERM reaches its trap.
(exec env HOME="$home" PATH="$bin:$PATH" TS_STATUS="$tmp/status.json" TS_CALLS="$tmp/calls" \
  CONTAINER_CLI="$here/fake-container.sh" FAKE_CONTAINER_WORLD="$world" FLEETD="$bin/fleetd" \
  FLEET_PORT="$port" FAKE_FLEETD_OUT="$tmp/fleetd.out" $extra \
  bash "$root/run.sh" serve -data "$tmp/data") > "$tmp/out" 2>&1 &
bg=$!
extra=""
for _ in $(seq 100); do [ -s "$tmp/fleetd.out" ] && grep -q 'tailscale serve' "$tmp/calls" && break; sleep 0.05; done
got=$(cat "$tmp/fleetd.out" 2>/dev/null)
contains "ARG -listen
ARG 127.0.0.1:$port
ARG -name
ARG mac1
ARG -url
ARG https://mac1.example-tailnet.ts.net
ARG -owner
ARG you@github
ARG -data" "$got" "fleetd flags from Tailscale"
contains "FLEET_PI_CTR_BIN=$root/pi-ctr" "$got" "fleetd finds pi-ctr"
not_contains "OPENROUTER_API_KEY" "$got" "fleetd holds no OpenRouter key"
not_contains "github_pat_test" "$got" "fleetd holds no GitHub token"
contains "tailscale serve --https=443 http://127.0.0.1:$port" "$(cat "$tmp/calls")" "foreground serve"
kill -TERM "$bg"
wait "$bg" 2>/dev/null
bg=""
contains "tailscale stopped" "$(cat "$tmp/calls")" "stopping serve stops tailscale serve"

finish

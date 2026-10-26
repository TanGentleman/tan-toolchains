#!/usr/bin/env bash
# Refresh the committed fixtures from the real Apple container CLI.
#
# Run this on macOS after `container system start`, with the pi-container image
# built and (for the proxy fixture) the proxy running. It refreshes the raw
# captures in test/fixtures/container/ and records provenance. Review `git diff`
# before committing: a changed shape is exactly what the tests are meant to
# catch.
#
#   ./test/record-fixtures.sh
#
# Captures are written to a temporary file and moved into place only after they
# parse as JSON. A failed capture leaves the existing fixture untouched.
#
# It cannot synthesise every variant the tests cover. Files it does not touch
# stay synthetic: alternate network modes, the label/history/env image shapes,
# and the stopped/paused proxy states. See fixtures/container/README.md.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(CDPATH= cd -- "$here/.." && pwd -P)
. "$root/names.sh"

cli=${CONTAINER_CLI:-container}
cfg=${PI_CONFIG_DIR:-$(pi_default_config_dir)}
out="$here/fixtures/container"
image=${PI_IMAGE:-pi-agent:local}
network=${PI_NETWORK_NAME:-$(pi_network_name "$cfg")}
proxy=${PI_PROXY_NAME:-$(pi_proxy_name "$cfg")}
provenance="$out/provenance.txt"
vol=""
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/pi-fixtures.XXXXXX")

cleanup() {
  if [ -n "$vol" ]; then
    "$cli" volume delete "$vol" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

command -v "$cli" >/dev/null 2>&1 || {
  printf 'record-fixtures.sh: %s not found; install Apple container first\n' "$cli" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'record-fixtures.sh: jq not found; install it first (brew install jq)\n' >&2
  exit 1
}

: > "$provenance"
say() { printf '%s\n' "$*" | tee -a "$provenance"; }

say "Captured $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "CLI: $("$cli" --version 2>/dev/null | head -n 1 || true)"
say "Profile: $cfg"
say ""

capture() { # relative-file, command...
  local file=$1
  shift
  local tmp="$tmpdir/${file##*/}.$$" err="$tmpdir/${file##*/}.err" detail
  if "$@" >"$tmp" 2>"$err" && jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$out/$file"
    say "wrote $file  <- $*"
  else
    rm -f "$tmp"
    detail=$(sed -n '1p' "$err" 2>/dev/null || true)
    if [ -e "$out/$file" ]; then
      say "kept $file  ($* failed or invalid JSON${detail:+: $detail})"
    else
      say "skipped $file  ($* failed or invalid JSON${detail:+: $detail})"
    fi
  fi
}

say "## Networks"
capture network/host-only.json "$cli" network inspect "$network"
say "kept network/host-only-escaped.json  (synthetic: forces the \\/ decode path)"
say ""

say "## Images"
capture image/inspect.json "$cli" image inspect "$image"
say "kept image/env-version.json, image/label-version.json, and image/history-version.json"
say "     (synthetic: alternate image metadata shapes)"
say ""

say "## Proxy container"
capture inspect/proxy-running.json "$cli" inspect "$proxy"
say ""

say "## Volume labels"
vol="pi-fixture-$$"
if "$cli" volume create \
  --label pi.managed=true \
  --label "pi.profile=$(pi_profile_label "$cfg")" \
  --label "pi.config=$cfg" \
  --label "pi.settings=$(pi_settings_file "$cfg")" \
  --label pi.instance=default \
  --label pi.kind=agent \
  "$vol" >/dev/null 2>&1; then
  capture volume/labelled.json "$cli" volume inspect "$vol"
else
  if [ -e "$out/volume/labelled.json" ]; then
    say "kept volume/labelled.json  (volume create failed)"
  else
    say "skipped volume/labelled.json  (volume create failed)"
  fi
fi
say ""

say "Done. If a capture was skipped, check 'container system start' and the resource names."
say "Alternate shapes (NAT/bridge networks, env/label/history image versions,"
say "stopped/paused proxy states) stay synthetic; see fixtures/container/README.md."

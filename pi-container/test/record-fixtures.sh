#!/usr/bin/env bash
# Refresh the committed fixtures from the real Apple container CLI.
#
# Run this on macOS after `container system start`, with the pi-container image
# built and (for the proxy fixture) the proxy running. It overwrites files in
# test/fixtures/container/ and records provenance. Review `git diff` before
# committing: a changed shape is exactly what the tests are meant to catch.
#
#   ./test/record-fixtures.sh
#
# It cannot synthesise every variant the tests cover. Files it does not touch
# stay synthetic: alternate network modes, the label/history image shapes, and
# the stopped/paused proxy states. See fixtures/container/README.md.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(CDPATH= cd -- "$here/.." && pwd -P)
. "$root/names.sh"

cli=${CONTAINER_CLI:-container}
cfg=${PI_CONFIG_DIR:-$(pi_default_config_dir)}
out="$here/fixtures/container"
image=${PI_IMAGE:-pi-agent:local}
network=$(pi_network_name "$cfg")
proxy=$(pi_proxy_name "$cfg")
provenance="$out/provenance.txt"

command -v "$cli" >/dev/null 2>&1 || {
  printf 'record-fixtures.sh: %s not found; install Apple container first\n' "$cli" >&2
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
  if "$@" > "$out/$file" 2>/dev/null; then
    say "wrote $file  <- $*"
  else
    rm -f "$out/$file"
    say "skipped $file  ($* failed; resource absent?)"
  fi
}

say "## Networks"
capture network/host-only.json "$cli" network inspect "$network"
say "kept network/host-only-escaped.json  (synthetic: forces the \\/ unescape path)"
say ""

say "## Images"
capture image/env-version.json "$cli" image inspect "$image"
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
  "$cli" volume delete "$vol" >/dev/null 2>&1 || true
else
  say "skipped volume/labelled.json  (volume create failed)"
fi
say ""

say "Done. If a capture is empty or an inspect failed, check 'container system start'."
say "Alternate shapes (NAT/bridge networks, label/history image versions,"
say "stopped/paused proxy states) stay synthetic; see fixtures/container/README.md."

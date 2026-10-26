#!/usr/bin/env bash
# Capture real Apple `container` inspect output for pi-container.
#
# This is a local discovery tool, not part of the shipped image or the test
# suite. It writes raw captures plus a jq summary of the paths the parsers use
# to a temporary directory. It never edits the committed fixtures.
#
# Usage:
#   ./scripts/container-discovery.sh [OUT_DIR]
#
# Without OUT_DIR, a fresh directory under $TMPDIR is used. The path is printed.
#
# Requires macOS, Apple `container`, and jq. Start the runtime first:
#   container system start
#
# Environment overrides:
#   CONTAINER_CLI      default: container
#   PI_CONFIG_DIR      default: ~/.config/pi-container
#   PI_IMAGE           default: pi-agent:local
#   PI_NETWORK_NAME    default: derived from PI_CONFIG_DIR
#   PI_PROXY_NAME      default: derived from PI_CONFIG_DIR
#
# States this script deliberately distinguishes:
#   * runtime not started        -> every inspect below fails; start it first
#   * runtime up, image missing  -> image capture is skipped; build the image
#   * runtime up, network/proxy absent -> those captures are skipped
#   * resource present, shape unexpected -> capture succeeds but the jq summary
#     reveals it; that is the signal to update the parser contract and tests
#
# Missing resources are reported, not treated as fatal. The exit status is
# non-zero if any capture was skipped or invalid JSON was produced.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(CDPATH= cd -- "$here/.." && pwd -P)
. "$root/pi-container/names.sh"

cli=${CONTAINER_CLI:-container}
cfg=${PI_CONFIG_DIR:-$(pi_default_config_dir)}
network=${PI_NETWORK_NAME:-$(pi_network_name "$cfg")}
proxy=${PI_PROXY_NAME:-$(pi_proxy_name "$cfg")}
image=${PI_IMAGE:-pi-agent:local}
profile=$(pi_profile_label "$cfg")
settings=$(pi_settings_file "$cfg")

need() { # command, install hint
  command -v "$1" >/dev/null 2>&1 && return 0
  printf 'container-discovery: %s not found; %s\n' "$1" "$2" >&2
  exit 1
}
need jq 'install jq (brew install jq)'
need "$cli" "install Apple container and run 'container system start'"

if [ -n "${1:-}" ]; then
  out=$1
  mkdir -p "$out"
else
  out=$(mktemp -d "${TMPDIR:-/tmp}/pi-container-discovery.XXXXXX")
fi
out=$(CDPATH= cd -- "$out" && pwd -P)

{
  printf 'captured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'cli=%s\n' "$cli"
  "$cli" --version 2>&1 | head -n 1 || true
  printf 'jq=%s\n' "$(jq --version)"
  printf 'profile=%s\n' "$cfg"
  printf 'network=%s\n' "$network"
  printf 'proxy=%s\n' "$proxy"
  printf 'image=%s\n' "$image"
} > "$out/meta.txt"

status=0

capture() { # name, command...
  local name=$1
  shift
  local file="$out/$name.json" err="$out/$name.err"
  if "$@" >"$file" 2>"$err"; then
    if jq . "$file" >/dev/null 2>&1; then
      printf 'captured %-18s %s\n' "$name" "$file"
      return 0
    fi
    printf 'captured %-18s but it is not valid JSON; see %s\n' "$name" "$err" >&2
    return 1
  fi
  rm -f "$file"
  printf 'skipped  %-18s %s\n' "$name" "$(sed -n '1p' "$err" 2>/dev/null || true)" >&2
  return 1
}

capture network "$cli" network inspect "$network" || status=1
capture image "$cli" image inspect "$image" || status=1
capture proxy "$cli" inspect "$proxy" || status=1

agent_vol=""
clone_vol=""
cleanup() {
  if [ -n "$agent_vol" ]; then
    "$cli" volume delete "$agent_vol" >/dev/null 2>&1 || true
  fi
  if [ -n "$clone_vol" ]; then
    "$cli" volume delete "$clone_vol" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

suffix="$$-$(date +%s)"

agent_vol="pi-discovery-agent-$suffix"
if "$cli" volume create \
  --label pi.managed=true \
  --label "pi.profile=$profile" \
  --label "pi.config=$cfg" \
  --label "pi.settings=$settings" \
  --label pi.instance=default \
  --label pi.kind=agent \
  "$agent_vol" >/dev/null 2>"$out/volume-agent-create.err"; then
  capture volume-agent "$cli" volume inspect "$agent_vol" || status=1
else
  printf 'skipped  %-18s volume create failed: %s\n' volume-agent \
    "$(sed -n '1p' "$out/volume-agent-create.err" 2>/dev/null || true)" >&2
  status=1
fi

clone_vol="pi-discovery-clone-$suffix"
if "$cli" volume create \
  --label pi.managed=true \
  --label "pi.profile=$profile" \
  --label "pi.config=$cfg" \
  --label "pi.settings=$settings" \
  --label pi.instance=work \
  --label pi.kind=clone \
  --label pi.repo=owner/repo \
  "$clone_vol" >/dev/null 2>"$out/volume-clone-create.err"; then
  capture volume-clone "$cli" volume inspect "$clone_vol" || status=1
else
  printf 'skipped  %-18s volume create failed: %s\n' volume-clone \
    "$(sed -n '1p' "$out/volume-clone-create.err" 2>/dev/null || true)" >&2
  status=1
fi

printf '\n== jq summary\n'
if compgen -G "$out/*.json" >/dev/null; then
  for f in "$out"/*.json; do
    printf '\n=== %s\n' "${f##*/}"
    jq -c 'if type == "array" then .[0] else error("expected an array") end |
      {top_keys: keys,
       config_keys: ((.configuration // {}) | keys),
       status: (.status // null),
       configuration: ((.configuration // {}) | {name, mode, ipv4Subnet}),
       variants: ((.variants // []) | map({
         env: (.config.config.Env // null),
         labels: (.config.config.Labels // null),
         history: [.config.history[]?.created_by]
       }))}' "$f" || status=1
  done
else
  printf 'no JSON captured\n'
  status=1
fi

printf '\ncaptures: %s\n' "$out"
if ! "$cli" image inspect "$image" >/dev/null 2>&1; then
  printf '%s\n' \
    "note: image inspect failed for $image. This can mean the image is missing" \
    "      OR the container system is not running. Try 'container system start'" \
    "      before rebuilding with 'container build -t $image -f $root/pi-container/Dockerfile $root'." >&2
fi
exit "$status"

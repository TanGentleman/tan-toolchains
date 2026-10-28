#!/usr/bin/env bash
# Unit tests for lib/inspect.sh.
#
# Exact-value assertions use inline JSON shaped like real Apple `container`
# output, so refreshing a recorded fixture does not rewrite expectations. The
# committed fixtures get a smoke test each: they must still parse into the
# category the code depends on.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
. "$here/../lib/inspect.sh"

command -v jq >/dev/null 2>&1 || {
  printf 'test-inspect.sh: jq is required\n' >&2
  exit 1
}

subnet_check_json() { # want, label, subnet, json
  local want=$1 label=$2 subnet=$3 json=$4 got=1
  if printf '%s' "$json" | pi_network_has_subnet "$subnet"; then got=0; fi
  if [ "$got" = "$want" ]; then pass; else fail "$label: expected status $want, got $got"; fi
}

network_fixture_subnet() { # fixture
  jq -r '.[0] | (.configuration.ipv4Subnet // .status.ipv4Subnet // empty)' "$1" |
    head -n 1
}

# --- proxy state -----------------------------------------------------------
proxy_running_json='[{"id":"pi-proxy","configuration":{"name":"pi-proxy"},"status":{"state":"running","startedDate":"2026-10-26T00:10:21Z"}}]'
eq running "$(printf '%s' "$proxy_running_json" | pi_proxy_state_from_json)" "status.state"
eq unknown "$(printf '%s' '[{"status":{"state":"unknown"}}]' | pi_proxy_state_from_json)" "unknown state is preserved"
eq "" "$(printf '%s' '[{"id":"x"}]' | pi_proxy_state_from_json)" "no state"
eq "" "$(printf '%s' '' | pi_proxy_state_from_json)" "empty payload"
eq "" "$(printf '%s' '{"status":{"state":"running"}}' | pi_proxy_state_from_json)" "top-level object is ignored"
eq "" "$(printf '%s' '[{"status":"stopped"}]' | pi_proxy_state_from_json)" "status string is ignored"
eq "" "$(printf '%s' '[{"state":"paused"}]' | pi_proxy_state_from_json)" "top-level state is ignored"
eq running "$(printf '%s' '[{"status":{"state":"running"},"configuration":{"labels":{"state":"stopped"}}}]' | pi_proxy_state_from_json)" "label named state does not override status.state"

# --- image version ---------------------------------------------------------
image_json() { # env/labels/history fragments
  printf '[{"id":"sha256:test","configuration":{"name":"pi-agent:local"},"variants":[{"config":{"config":{%s},"history":[%s]}}]}]' "$1" "$2"
}
eq 1.4.0 "$(printf '%s' "$(image_json '"Env":["PATH=/usr/bin","PI_CONTAINER_PI_VERSION=1.4.0"]' '')" | pi_image_version_from_json)" "version from nested Env"
eq 1.4.0 "$(printf '%s' "$(image_json '"Labels":{"pi-container.pi-version":"1.4.0"}' '')" | pi_image_version_from_json)" "version from nested label"
eq 1.4.0 "$(printf '%s' "$(image_json '' '{"created_by":"RUN apk add curl && PI_VERSION=1.4.0 zig build"}')" | pi_image_version_from_json)" "version from nested build history"
# A command that ends exactly at the version must not capture the JSON quote.
eq 9.9.9 "$(printf '%s' "$(image_json '' '{"created_by":"RUN PI_VERSION=9.9.9"}')" | pi_image_version_from_json)" "version at end of history entry"
eq "" "$(printf '%s' "$(image_json '"Env":["PATH=/usr/bin"]' '{"created_by":"RUN true"}')" | pi_image_version_from_json)" "no version present"
eq "" "$(printf '%s' '{"configuration":{"env":["PI_CONTAINER_PI_VERSION=2.0.0"]}}' | pi_image_version_from_json)" "top-level Env is ignored"
eq "" "$(printf '%s' '{"configuration":{"labels":{"pi-container.pi-version":"3.0.0"}}}' | pi_image_version_from_json)" "top-level label is ignored"
eq "" "$(printf '%s' '{"history":[{"created_by":"RUN PI_VERSION=4.0.0 zig build"}]}' | pi_image_version_from_json)" "top-level history is ignored"
eq "" "$(printf '%s' '[{"variants":[{"config":{"config":{}}},{"config":{"config":{"Env":["PI_CONTAINER_PI_VERSION=2.0.0"]}}}]}]' | pi_image_version_from_json)" "only the first variant is read"
eq 2.0.0 "$(printf '%s' "$(image_json '"Env":["PI_CONTAINER_PI_VERSION=2.0.0"],"Labels":{"pi-container.pi-version":"1.0.0"}' '')" | pi_image_version_from_json)" "env precedence over label"
eq 1.4.0 "$(printf '%s' "$(image_json '"Labels":{"pi-container.pi-version":"1.4.0"}' '{"created_by":"RUN PI_VERSION=0.0.0 zig build"}')" | pi_image_version_from_json)" "label precedence over history"
eq 1.4.0 "$(printf '%s' "$(image_json '"Labels":{"pi-container.pi-version":"1.4.0"}' '{"created_by":"RUN echo PI_CONTAINER_PI_VERSION=0.0.0"}')" | pi_image_version_from_json)" "history decoy does not look like Env"

# --- image capabilities ---------------------------------------------------
eq 'zig,zigpeek,enforcer,pi' "$(printf '%s' "$(image_json '"Env":["PI_CONTAINER_CAPABILITIES=zig,zigpeek,enforcer,pi"]' '')" | pi_image_capabilities_from_json)" "capabilities from nested Env"
eq '' "$(printf '%s' "$(image_json '"Env":["PATH=/usr/bin"]' '')" | pi_image_capabilities_from_json)" "legacy image has no capabilities"
eq '' "$(printf '%s' '{"Env":["PI_CONTAINER_CAPABILITIES=pi"]}' | pi_image_capabilities_from_json)" "top-level Env is ignored"
eq '' "$(pi_image_capabilities_from_json < "$fixtures/image/inspect.json")" "recorded image fixture stays legacy"

# --- network verdict -------------------------------------------------------
network_host_only_json='[{"configuration":{"name":"pi-locked","mode":"hostOnly","ipv4Subnet":"172.30.240.0/24","labels":{}},"status":{"ipv4Subnet":"172.30.240.0/24","ipv4Gateway":"172.30.240.1"}}]'
network_host_only_escaped_json='[{"configuration":{"name":"pi-locked","mode":"hostOnly","ipv4Subnet":"172.30.240.0\/24"},"status":{"ipv4Subnet":"172.30.240.0\/24"}}]'
eq ok "$(printf '%s' "$network_host_only_json" | pi_network_host_only_verdict)" "observed hostOnly network"
eq ok "$(printf '%s' "$network_host_only_escaped_json" | pi_network_host_only_verdict)" "escaped slashes still ok"
eq not-host-only "$(printf '%s' '[{"configuration":{"mode":"bridge"}}]' | pi_network_host_only_verdict)" "bridge mode"
eq not-host-only "$(printf '%s' '[{"configuration":{"mode":"host-only"}}]' | pi_network_host_only_verdict)" "host-only spelling is not accepted"
eq unverified "$(printf '%s' '[{"id":"x"}]' | pi_network_host_only_verdict)" "no mode"
eq unverified "$(printf '%s' '[{"configuration":{"internal":true}}]' | pi_network_host_only_verdict)" "internal is ignored"
eq unverified "$(printf '%s' '{"configuration":{"mode":"hostOnly"}}' | pi_network_host_only_verdict)" "top-level object is ignored"
eq ok "$(printf '%s' '[{"configuration":{"mode":"hostOnly"},"status":{"internal":false}}]' | pi_network_host_only_verdict)" "status decoy does not override configuration.mode"

# --- subnet matching -------------------------------------------------------
subnet_check_json 0 "plain subnet matches" 172.30.240.0/24 "$network_host_only_json"
subnet_check_json 0 "escaped subnet matches via jq" 172.30.240.0/24 "$network_host_only_escaped_json"
subnet_check_json 1 "different subnet does not match" 172.30.241.0/24 "$network_host_only_json"
subnet_check_json 1 "configuration.subnet is ignored" 172.30.240.0/24 '[{"configuration":{"subnet":"172.30.240.0/24"}}]'
subnet_check_json 1 "status.subnet is ignored" 172.30.240.0/24 '[{"status":{"subnet":"172.30.240.0/24"}}]'
subnet_check_json 1 "subnet in another field does not match" 172.30.240.0/24 '[{"configuration":{"name":"172.30.240.0/24","ipv4Subnet":"10.0.0.0/8"}}]'
subnet_check_json 1 "config and status subnet must agree" 172.30.240.0/24 '[{"configuration":{"ipv4Subnet":"172.30.240.0/24"},"status":{"ipv4Subnet":"172.30.241.0/24"}}]'
subnet_check_json 1 "no subnet field" 172.30.240.0/24 '[{"configuration":{"name":"pi-locked"}}]'
contains '172.30.240.0\/24' "$network_host_only_escaped_json" "escaped fixture still contains a backslash"

# --- volume labels ---------------------------------------------------------
volume_labelled_json='[{"id":"pi-agent-home","configuration":{"name":"pi-agent-home","labels":{"pi.managed":"true","pi.kind":"agent","pi.profile":"default","pi.config":"/Users/dev/.config/pi-container"}}}]'
volume_escaped_json='[{"id":"pi-clone_work_owner-repo-12345678","configuration":{"name":"pi-clone_work_owner-repo-12345678","labels":{"pi.kind":"clone","pi.settings":"\/Users\/dev\/.config\/pi-container\/settings.json","pi.repo":"owner\/repo","pi.instance":"work"}}}]'
eq agent "$(printf '%s' "$volume_labelled_json" | pi_volume_label_from_json pi.kind)" "kind label"
eq default "$(printf '%s' "$volume_labelled_json" | pi_volume_label_from_json pi.profile)" "profile label"
eq /Users/dev/.config/pi-container "$(printf '%s' "$volume_labelled_json" | pi_volume_label_from_json pi.config)" "config label"
eq "" "$(printf '%s' "$volume_labelled_json" | pi_volume_label_from_json pi.missing)" "missing label"
eq clone "$(printf '%s' "$volume_escaped_json" | pi_volume_label_from_json pi.kind)" "escaped kind"
eq /Users/dev/.config/pi-container/settings.json "$(printf '%s' "$volume_escaped_json" | pi_volume_label_from_json pi.settings)" "escaped settings path"
eq owner/repo "$(printf '%s' "$volume_escaped_json" | pi_volume_label_from_json pi.repo)" "repo label"
eq work "$(printf '%s' "$volume_escaped_json" | pi_volume_label_from_json pi.instance)" "instance label"
eq agent "$(printf '%s' '[{"configuration":{"labels":{"pi.kind":"agent"},"annotations":{"pi.kind":"clone"}}}]' | pi_volume_label_from_json pi.kind)" "annotation decoy is ignored"
eq agent "$(printf '%s' '[{"configuration":{"labels":{"pi_kind":"clone","pi.kind":"agent"}}}]' | pi_volume_label_from_json pi.kind)" "label key is literal"
eq "" "$(printf '%s' '{"configuration":{"labels":{"pi.kind":"agent"}}}' | pi_volume_label_from_json pi.kind)" "top-level object is ignored"

# --- committed fixtures: smoke tests ---------------------------------------
# These only assert the category the code depends on. Re-record them on macOS
# and the suite should still pass as long as the CLI's shape has not moved.
eq running "$(pi_proxy_state_from_json < "$fixtures/inspect/proxy-running.json")" "fixture proxy-running"
eq stopped "$(pi_proxy_state_from_json < "$fixtures/inspect/proxy-stopped.json")" "fixture proxy-stopped"
eq paused "$(pi_proxy_state_from_json < "$fixtures/inspect/proxy-paused.json")" "fixture proxy-paused"

neq "" "$(pi_image_version_from_json < "$fixtures/image/env-version.json")" "fixture env version present"
neq "" "$(pi_image_version_from_json < "$fixtures/image/label-version.json")" "fixture label version present"
neq "" "$(pi_image_version_from_json < "$fixtures/image/history-version.json")" "fixture history version present"
eq "" "$(pi_image_version_from_json < "$fixtures/image/no-version.json")" "fixture no-version stays empty"
jq -e '.[0].variants[0].config.config' "$fixtures/image/inspect.json" >/dev/null 2>&1 \
  && pass || fail "fixture image/inspect has the observed variants shape"

eq ok "$(pi_network_host_only_verdict < "$fixtures/network/host-only.json")" "fixture host-only"
eq ok "$(pi_network_host_only_verdict < "$fixtures/network/host-only-escaped.json")" "fixture escaped host-only"
eq not-host-only "$(pi_network_host_only_verdict < "$fixtures/network/nat.json")" "fixture nat"
eq unverified "$(pi_network_host_only_verdict < "$fixtures/network/no-mode.json")" "fixture no-mode"

for f in host-only.json host-only-escaped.json; do
  subnet=$(network_fixture_subnet "$fixtures/network/$f")
  if [ -z "$subnet" ]; then
    fail "fixture $f has no subnet to match"
  else
    subnet_check_json 0 "fixture $f subnet matches itself" "$subnet" "$(cat "$fixtures/network/$f")"
  fi
done

eq agent "$(pi_volume_label_from_json pi.kind < "$fixtures/volume/labelled.json")" "fixture kind label"
# Profile is derived from PI_CONFIG_DIR, so a custom-profile capture has an id
# here. Only require that the label parses.
neq "" "$(pi_volume_label_from_json pi.profile < "$fixtures/volume/labelled.json")" "fixture profile label"
neq "" "$(pi_volume_label_from_json pi.settings < "$fixtures/volume/escaped-labels.json")" "fixture escaped settings"
eq work "$(pi_volume_label_from_json pi.instance < "$fixtures/volume/escaped-labels.json")" "fixture escaped instance"

finish

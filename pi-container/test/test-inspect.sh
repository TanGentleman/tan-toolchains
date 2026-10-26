#!/usr/bin/env bash
# Unit tests for lib/inspect.sh.
#
# Exact-value assertions use inline JSON so refreshing a recorded fixture does
# not rewrite expectations. The committed fixtures get a smoke test each: they
# must still parse into the category the code depends on. That split is what
# makes `test/record-fixtures.sh` safe to run.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
. "$here/../lib/inspect.sh"

subnet_check_json() { # want, label, subnet, json
  local want=$1 label=$2 subnet=$3 json=$4 got=1
  if printf '%s' "$json" | pi_network_has_subnet "$subnet"; then got=0; fi
  if [ "$got" = "$want" ]; then pass; else fail "$label: expected status $want, got $got"; fi
}

network_fixture_subnet() { # fixture
  pi_json_unescape_slashes < "$1" |
    sed -n 's|.*"subnet"[[:space:]]*:[[:space:]]*"\([^"]*\)".*|\1|p' |
    head -n 1
}

# --- proxy state -----------------------------------------------------------
proxy_running_json='[{"id":"pi-proxy","configuration":{"name":"pi-proxy"},"status":{"state":"running"}}]'
eq running "$(printf '%s' "$proxy_running_json" | pi_proxy_state_from_json)" "nested status.state"
eq stopped "$(printf '%s' '{"status":"stopped"}' | pi_proxy_state_from_json)" "top-level status string"
eq paused "$(printf '%s' '{"state":"paused"}' | pi_proxy_state_from_json)" "top-level state"
eq "" "$(printf '%s' '{"id":"x"}' | pi_proxy_state_from_json)" "no state"
eq "" "$(printf '%s' '' | pi_proxy_state_from_json)" "empty payload"
eq stopped "$(printf '%s' '{"status":{"state":"running"},"state":"stopped"}' | pi_proxy_state_from_json)" "later match wins"

# --- image version ---------------------------------------------------------
eq 1.4.0 "$(printf '%s' '{"configuration":{"env":["PI_CONTAINER_PI_VERSION=1.4.0","X=1"]}}' | pi_image_version_from_json)" "version from config Env"
eq 1.4.0 "$(printf '%s' '{"configuration":{"labels":{"pi-container.pi-version":"1.4.0"}}}' | pi_image_version_from_json)" "version from image label"
eq 1.4.0 "$(printf '%s' '{"history":[{"created_by":"RUN apk add curl && PI_VERSION=1.4.0 zig build"}]}' | pi_image_version_from_json)" "version from build history"
# A command that ends exactly at the version must not capture the JSON quote.
eq 9.9.9 "$(printf '%s' '{"history":[{"created_by":"RUN PI_VERSION=9.9.9"}]}' | pi_image_version_from_json)" "version at end of history entry"
eq "" "$(printf '%s' '{"configuration":{"env":["X=1"]},"history":[{"created_by":"RUN true"}]}' | pi_image_version_from_json)" "no version present"
eq 2.0.0 "$(printf '%s' '{"env":["PI_CONTAINER_PI_VERSION=2.0.0","X=1"]}' | pi_image_version_from_json)" "env value read"
eq 2.0.0 "$(printf '%s' '{"env":["PI_CONTAINER_PI_VERSION=2.0.0"],"labels":{"pi-container.pi-version":"1.0.0"}}' | pi_image_version_from_json)" "env precedence over label"

# --- network verdict -------------------------------------------------------
network_host_only_json='[{"id":"pi-locked","configuration":{"name":"pi-locked","mode":"hostOnly","subnet":"172.30.240.0/24","internal":true}}]'
network_host_only_escaped_json='[{"id":"pi-locked","configuration":{"name":"pi-locked","mode":"hostOnly","subnet":"172.30.240.0\/24","internal":true}}]'
eq ok "$(printf '%s' "$network_host_only_json" | pi_network_host_only_verdict)" "hostOnly + internal true"
eq ok "$(printf '%s' "$network_host_only_escaped_json" | pi_network_host_only_verdict)" "escaped slashes still ok"
eq ok "$(printf '%s' '{"internal":true}' | pi_network_host_only_verdict)" "internal true without mode"
eq internal-false "$(printf '%s' '{"internal":false}' | pi_network_host_only_verdict)" "internal false"
eq mode-not-host-only "$(printf '%s' '{"mode":"bridge"}' | pi_network_host_only_verdict)" "bridge mode"
eq unverified "$(printf '%s' '{"id":"x"}' | pi_network_host_only_verdict)" "no markers"
eq internal-false "$(printf '%s' '{"internal":false,"mode":"hostOnly"}' | pi_network_host_only_verdict)" "internal false wins"
eq ok "$(printf '%s' '{"internal":"true"}' | pi_network_host_only_verdict)" "quoted internal true"
eq internal-false "$(printf '%s' '{"internal":"false"}' | pi_network_host_only_verdict)" "quoted internal false"
eq ok "$(printf '%s' '{"mode":"host-only"}' | pi_network_host_only_verdict)" "host-only spelling"
eq ok "$(printf '%s' '{"mode":"hostOnly"}' | pi_network_host_only_verdict)" "hostOnly spelling"

# --- subnet matching (the escaped-slash regression) ------------------------
subnet_check_json 0 "plain subnet matches" 172.30.240.0/24 "$network_host_only_json"
subnet_check_json 0 "escaped subnet matches after unescape" 172.30.240.0/24 "$network_host_only_escaped_json"
subnet_check_json 1 "different subnet does not match" 172.30.241.0/24 "$network_host_only_json"
contains '172.30.240.0\/24' "$network_host_only_escaped_json" "raw escaped fixture has a backslash"
contains '172.30.240.0/24' "$(printf '%s' "$network_host_only_escaped_json" | pi_json_unescape_slashes)" "unescape removes the backslash"
not_contains '\/' "$(printf '%s' "$network_host_only_escaped_json" | pi_json_unescape_slashes)" "unescape leaves no escaped slash"

# --- volume labels ---------------------------------------------------------
volume_labelled_json='[{"id":"pi-agent-home","configuration":{"labels":{"pi.managed":"true","pi.kind":"agent","pi.profile":"default","pi.config":"/Users/tan/.config/pi-container"}}}]'
volume_escaped_json='[{"id":"pi-clone_work_owner-repo-12345678","configuration":{"labels":{"pi.kind":"clone","pi.settings":"\/Users\/tan\/.config\/pi-container\/settings.json","pi.repo":"owner\/repo","pi.instance":"work"}}}]'
eq agent "$(printf '%s' "$volume_labelled_json" | pi_volume_label_from_json pi.kind)" "kind label"
eq default "$(printf '%s' "$volume_labelled_json" | pi_volume_label_from_json pi.profile)" "profile label"
eq /Users/tan/.config/pi-container "$(printf '%s' "$volume_labelled_json" | pi_volume_label_from_json pi.config)" "config label"
eq "" "$(printf '%s' "$volume_labelled_json" | pi_volume_label_from_json pi.missing)" "missing label"
eq clone "$(printf '%s' "$volume_escaped_json" | pi_volume_label_from_json pi.kind)" "escaped kind"
eq /Users/tan/.config/pi-container/settings.json "$(printf '%s' "$volume_escaped_json" | pi_volume_label_from_json pi.settings)" "escaped settings path"
eq owner/repo "$(printf '%s' "$volume_escaped_json" | pi_volume_label_from_json pi.repo)" "repo label"
eq work "$(printf '%s' "$volume_escaped_json" | pi_volume_label_from_json pi.instance)" "instance label"

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

eq ok "$(pi_network_host_only_verdict < "$fixtures/network/host-only.json")" "fixture host-only"
eq ok "$(pi_network_host_only_verdict < "$fixtures/network/host-only-escaped.json")" "fixture escaped host-only"
eq ok "$(pi_network_host_only_verdict < "$fixtures/network/internal-true.json")" "fixture internal-true"
eq internal-false "$(pi_network_host_only_verdict < "$fixtures/network/nat.json")" "fixture nat"
eq mode-not-host-only "$(pi_network_host_only_verdict < "$fixtures/network/mode-bridge.json")" "fixture bridge"
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

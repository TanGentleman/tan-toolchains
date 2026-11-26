#!/usr/bin/env bash
# Unit tests for lib/config.sh. No container runtime required.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
. "$root/lib/validate.sh"
. "$root/lib/config.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
f="$tmp/config.json"

legacy() { printf '%s' "$1" > "$f"; pi_config_legacy "$f"; }
eq "PI_IMAGE='min'" "$(legacy '{"v":1,"image":"min"}')" "legacy image"
eq "PI_EGRESS='offline' PI_MODEL_URL='http://gateway:8090'" "$(legacy '{"v":1,"egress":"offline","model_url":"http://gateway:8090"}')" "legacy egress and model_url"
eq "" "$(legacy '{"v":1}')" "legacy file with no settings"
eq "" "$(legacy 'not json')" "legacy file that is not JSON"
eq "" "$(legacy '[1]')" "legacy file that is not an object"
eq "" "$(pi_config_legacy "$tmp/absent.json")" "legacy absent file"

eq "min flag" "$(pi_config_pick min zig full)" "flag beats env"
eq "min env" "$(pi_config_pick '' min full)" "env beats default"
eq "full default" "$(pi_config_pick '' '' full)" "default last"
eq "full standard openrouter" "$pi_config_default_image $pi_config_default_egress $pi_config_default_model_url" "built-in defaults"

rc 0 "standard with openrouter" pi_config_combo_check standard any openrouter
rc 0 "standard with a public model_url" pi_config_combo_check standard any http://models.example:80
rc 0 "offline with gateway" pi_config_combo_check offline private http://gateway:8090
rc 0 "offline with a private IPv4" pi_config_combo_check offline private http://192.168.64.1:8090
for u in openrouter http://1.1.1.1:80 http://127.0.0.1:8090 http://models.lan:8090; do
  rc 1 "offline refuses [$u]" pi_config_combo_check offline private "$u"
done
contains "openrouter is refused offline" "$(pi_config_combo_check offline private openrouter)" "offline openrouter reason"
contains "not 127.0.0.1" "$(pi_config_combo_check offline private http://127.0.0.1:8090)" "offline loopback reason"
contains "egress lab needs model_url" "$(pi_config_combo_check lab private openrouter)" "a user profile is named"

json=$(pi_config_json min env offline flag http://gateway:8090 default pi-min:local /p/offline.json "" private false)
eq '{"file":"/p/offline.json","tunnel":[],"model_url":"private","github_token":false}' "$(jq -c .egress_profile <<<"$json")" "json egress profile"
json2=$(pi_config_json full default standard default openrouter default pi-full:local /p/standard.json "a.com,b.com" any true)
eq '["a.com","b.com"]' "$(jq -c .egress_profile.tunnel <<<"$json2")" "json tunnel list"
eq 1 "$(jq -r .v <<<"$json")" "json v"
eq "min offline http://gateway:8090 pi-min:local null" \
  "$(jq -r '"\(.image) \(.egress) \(.model_url) \(.tag) \(.config)"' <<<"$json")" "json values, no config file"
eq "env flag default" "$(jq -r '"\(.source.image) \(.source.egress) \(.source.model_url)"' <<<"$json")" "json sources"

finish

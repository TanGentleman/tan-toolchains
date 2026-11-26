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
us=$'\037'

read_ok() { # json, expected fields joined by |, label
  local out
  printf '%s' "$1" > "$f"
  if out=$(pi_config_read "$f"); then
    eq "$2" "${out//$us/|}" "$3"
  else
    fail "$3: refused: $out"
  fi
}
read_bad() { # json, reason needle, label
  local out
  printf '%s' "$1" > "$f"
  if out=$(pi_config_read "$f"); then
    fail "$3: accepted: $out"
  else
    contains "$2" "$out" "$3"
  fi
}

eq "||" "$(pi_config_read "$tmp/absent.json" | sed "s/$us/|/g")" "absent file: every key empty"
read_ok '{"v":1}' "||" "only v"
read_ok '{"v":1,"image":"min"}' "min||" "image only"
read_ok '{"v":1,"egress":"offline","model_url":"http://gateway:8090"}' "|offline|http://gateway:8090" "egress and model_url"
read_ok '{"v": 1, "image": "zig", "egress": "standard", "model_url": "openrouter"}' "zig|standard|openrouter" "every key"
read_ok $'{\n  "v": 1,\n  "image": "full"\n}\n' "full||" "pretty-printed"

read_bad '' "one JSON object" "empty file"
read_bad 'not json' "not valid JSON" "not JSON"
read_bad '[]' "one JSON object" "an array"
read_bad '{"v":1}{"v":1}' "one JSON object" "two objects"
read_bad '{}' 'needs "v": 1, not null' "missing v"
read_bad '{"v":2}' 'needs "v": 1, not 2' "other version"
read_bad '{"v":"1"}' 'needs "v": 1' "string version"
read_bad '{"v":1,"proxy":"x"}' 'unknown key "proxy"' "unknown key"
read_bad '{"v":1,"OPENROUTER_API_KEY":"sk"}' 'unknown key "OPENROUTER_API_KEY"' "a secret is an unknown key"
read_bad '{"v":1,"image":1}' "one-line strings" "number image"
read_bad '{"v":1,"image":null}' "one-line strings" "null is not absent"
read_bad '{"v":1,"model_url":"http://a:1\nb"}' "one-line strings" "newline in a value"
read_bad '{"v":1,"image":"agent"}' 'image must be min, full or zig, not "agent"' "removed pack"
read_bad '{"v":1,"image":"editor"}' 'image must be min, full or zig' "non-Pi pack"
read_bad '{"v":1,"egress":"normal"}' 'egress must be standard or offline, not "normal"' "old egress name"
read_bad '{"v":1,"model_url":"https://x:1"}' 'model_url must be' "https model_url"
mkdir "$tmp/dir.json"
contains "not a readable file" "$(pi_config_read "$tmp/dir.json")" "a directory is refused"
rc 1 "a directory fails" pi_config_read "$tmp/dir.json"
ln -s "$tmp/nowhere" "$tmp/dangling.json"
rc 1 "a dangling symlink is refused, not absent" pi_config_read "$tmp/dangling.json"

eq "min flag" "$(pi_config_pick min zig full)" "flag beats file"
eq "zig file" "$(pi_config_pick '' zig full)" "file beats default"
eq "full default" "$(pi_config_pick '' '' full)" "default last"
eq "full standard openrouter" "$pi_config_default_image $pi_config_default_egress $pi_config_default_model_url" "built-in defaults"

rc 0 "standard with openrouter" pi_config_combo_check standard openrouter
rc 0 "standard with a public model_url" pi_config_combo_check standard http://models.example:80
rc 0 "offline with gateway" pi_config_combo_check offline http://gateway:8090
rc 0 "offline with a private IPv4" pi_config_combo_check offline http://192.168.64.1:8090
for u in openrouter http://1.1.1.1:80 http://127.0.0.1:8090 http://models.lan:8090; do
  rc 1 "offline refuses [$u]" pi_config_combo_check offline "$u"
done
contains "openrouter is refused offline" "$(pi_config_combo_check offline openrouter)" "offline openrouter reason"
contains "not 127.0.0.1" "$(pi_config_combo_check offline http://127.0.0.1:8090)" "offline loopback reason"

json=$(pi_config_json /c/config.json min file offline flag http://gateway:8090 default pi-min:local)
eq 1 "$(jq -r .v <<<"$json")" "json v"
eq "min offline http://gateway:8090 pi-min:local /c/config.json" \
  "$(jq -r '"\(.image) \(.egress) \(.model_url) \(.tag) \(.config)"' <<<"$json")" "json values"
eq "file flag default" "$(jq -r '"\(.source.image) \(.source.egress) \(.source.model_url)"' <<<"$json")" "json sources"

finish

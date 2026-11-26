#!/usr/bin/env bash
# Unit tests for lib/egress.sh and the built-in profiles. No container runtime.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
. "$root/lib/egress.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
f="$tmp/p.json"
us=$'\037'
gh="github.com,api.github.com,codeload.github.com,objects.githubusercontent.com,raw.githubusercontent.com,uploads.github.com"

eq "$gh|any|true" "$(pi_egress_read "$root/egress/standard.json" | sed "s/$us/|/g")" "standard profile"
eq "|private|false" "$(pi_egress_read "$root/egress/offline.json" | sed "s/$us/|/g")" "offline profile"

mkdir -p "$tmp/user"
printf '{"v":1,"tunnel":[],"model_url":"any","github_token":false}\n' > "$tmp/user/mine.json"
printf '{"v":1,"tunnel":[],"model_url":"any","github_token":true}\n' > "$tmp/user/standard.json"
eq "$root/egress/standard.json" "$(pi_egress_file standard "$root/egress" "$tmp/user")" "a built-in name is never overridden"
eq "$tmp/user/mine.json" "$(pi_egress_file mine "$root/egress" "$tmp/user")" "user profile found"
rc 1 "absent profile" pi_egress_file nope "$root/egress" "$tmp/user"

read_ok() { # json, expected, label
  local out
  printf '%s' "$1" > "$f"
  if out=$(pi_egress_read "$f"); then eq "$2" "${out//$us/|}" "$3"; else fail "$3: refused: $out"; fi
}
read_bad() { # json, reason needle, label
  local out
  printf '%s' "$1" > "$f"
  if out=$(pi_egress_read "$f"); then fail "$3: accepted: $out"; else contains "$2" "$out" "$3"; fi
}

read_ok '{"v":1,"tunnel":["pypi.org","files.pythonhosted.org"],"model_url":"any","github_token":false}' \
  "pypi.org,files.pythonhosted.org|any|false" "extra hosts"
read_ok '{"v":1,"about":"x","tunnel":[],"model_url":"private","github_token":false}' "|private|false" "about is allowed"
read_bad '{"v":2,"tunnel":[],"model_url":"any","github_token":true}' 'needs "v": 1' "other version"
read_bad '{"v":1,"tunnel":[],"model_url":"any","github_token":true,"allow":[]}' 'unknown key "allow"' "unknown key"
read_bad '{"v":1,"model_url":"any","github_token":true}' 'tunnel must be a list' "missing tunnel"
read_bad '{"v":1,"tunnel":"github.com","model_url":"any","github_token":true}' 'tunnel must be a list' "tunnel string"
for h in '*.github.com' 'GitHub.com' 'localhost' '1.2.3' 'a..b' 'github.com:443' 'github.com.' ''; do
  read_bad "{\"v\":1,\"tunnel\":[\"$h\"],\"model_url\":\"any\",\"github_token\":true}" 'lowercase host names' "bad host [$h]"
done
read_bad '{"v":1,"tunnel":["openrouter.ai"],"model_url":"any","github_token":true}' 'cannot list openrouter.ai' "openrouter tunnel"
read_bad '{"v":1,"tunnel":["api.openrouter.ai"],"model_url":"any","github_token":true}' 'cannot list openrouter.ai' "openrouter subdomain tunnel"
read_bad '{"v":1,"tunnel":["a.com","a.com"],"model_url":"any","github_token":true}' 'twice' "duplicate host"
read_bad '{"v":1,"tunnel":[],"model_url":"local","github_token":true}' 'model_url must be' "bad model_url rule"
read_bad '{"v":1,"tunnel":[],"model_url":"any","github_token":"yes"}' 'github_token must be' "bad github_token"
read_bad '{"v":1,"about":"a\nb","tunnel":[],"model_url":"any","github_token":true}' 'about must be one line' "multi-line about"
read_bad 'nope' 'not valid JSON' "not JSON"
read_bad '{"v":1}{"v":1}' 'one JSON object' "two objects"
rc 1 "absent file" pi_egress_read "$tmp/absent.json"

rc 0 "tunnels github.com" pi_egress_tunnels "$gh" github.com
rc 1 "no partial match" pi_egress_tunnels "$gh" hub.com
rc 1 "empty tunnel" pi_egress_tunnels "" github.com

finish

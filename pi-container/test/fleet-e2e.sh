#!/usr/bin/env bash
# On a Mac running `pic serve`: fleet/docs/macos.md step 8 against real Pi,
# GitHub and container. Spawns sessions on REPO through the tailnet URL, so
# `tailscale serve` supplies the identity, and checks what each turn left on
# GitHub with git and the env file's GITHUB_TOKEN.
#
#   test/fleet-e2e.sh OWNER/REPO
#
# REPO is a private throwaway repo with a README on main that the token can
# push to. Prints one "ok" or "FAIL" line per check, then "fleet-e2e: ok" or
# "fleet-e2e: FAIL"; exits non-zero on FAIL. Runs fleet-isolation.sh on the
# first session. TURN_TIMEOUT (seconds, 300) bounds each turn. For
# fleet/e2e/pi-ctr.sh: FLEET_URL, FLEET_LOGIN (sent as the identity header),
# FLEET_ISOLATION and CONTAINER_CLI. The token comes from PI_ENV_FILE, else
# $PI_CONFIG_DIR/env, as in run.sh.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
die() { echo "fleet-e2e.sh: $*" >&2; exit 2; }
repo=${1:-}
case $repo in
  */* ) ;;
  *) die "usage: test/fleet-e2e.sh OWNER/REPO" ;;
esac
env_file=${PI_ENV_FILE:-${PI_CONFIG_DIR:-$HOME/.config/pi-container}/env}
ctr=${CONTAINER_CLI:-container}
timeout=${TURN_TIMEOUT:-300}
URL=${FLEET_URL:-https://$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

nfail=0
ok() { echo "  ok    $1"; }
bad() { nfail=$((nfail + 1)); echo "  FAIL  $1${2:+ ($2)}"; }
expect() { # desc want got
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want ${2:-nothing}, got ${3:-nothing}"; fi
}

api() { # METHOD PATH [JSON]
  curl -sS --fail-with-body --max-time 30 -X "$1" -H 'Content-Type: application/json' \
    ${FLEET_LOGIN:+-H "Tailscale-User-Login: $FLEET_LOGIN"} ${3:+-d "$3"} "$URL$2"
}
st() { api GET "/v1/sessions/$1" | jq -r --arg f "$2" '.[$f] | if . == null then "" else tostring end'; }
events() { api GET "/v1/sessions/$1/events" >"$tmp/events"; }
# The last turn's exited event, as "code reason".
exited() { events "$1"; jq -rs '[.[] | select(.kind == "exited")] | last | .data | "\(.code) \(.reason // "")"' "$tmp/events"; }
# Every event of turn RUN, for grepping what Pi said and did.
said() { events "$1"; jq -rs --argjson r "$2" '.[] | select(.run == $r) | .data | tostring' "$tmp/events"; }
want=1 # the turn idle waits for; say bumps it
idle() { # sid
  local t=0
  while [ "$t" -lt "$timeout" ]; do
    [ "$(st "$1" running)" = false ] && [ "$(st "$1" run)" -ge "$want" ] && return 0
    sleep 2; t=$((t + 2))
  done
  bad "session $1 finished its turn within ${timeout}s"
  return 1
}
spawn() { # repo prompt -> sid
  want=1
  api POST /v1/sessions "$(jq -cn --arg r "$1" --arg p "$2" --arg k "e2e-$RANDOM$RANDOM" \
    '{harness: "pi-ctr", repo: $r, key: $k, prompt: $p}')" | jq -r .sid
}
say() { # sid text
  want=$(($(st "$1" run) + 1))
  api POST "/v1/sessions/$1/inputs" "$(jq -cn --arg t "$2" --arg k "e2e-$RANDOM$RANDOM" '{key: $k, text: $t}')" >/dev/null
}
no_container() { ! "$ctr" ls -a 2>/dev/null | grep -q "fleet-$1"; }

# git against GitHub with the token in the environment, not in argv.
token=$(sed -n 's/^GITHUB_TOKEN=//p' "$env_file" | tail -n 1)
[ -n "$token" ] || die "no GITHUB_TOKEN in $env_file"
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
unset token
git init -q --bare "$tmp/gh"
tip() { git ls-remote "https://github.com/$repo" "refs/heads/$1" | cut -f1; }
fetch() { git -C "$tmp/gh" fetch -q "https://github.com/$repo" "$1" && git -C "$tmp/gh" rev-parse FETCH_HEAD; }

echo "== fleet-e2e $repo via $URL"
main=$(tip main 2>/dev/null) || main=""
[ -n "$main" ] || die "the GITHUB_TOKEN in $env_file can't read $repo, or it has no main branch; set PI_CONFIG_DIR or PI_ENV_FILE to the profile pic serve uses"

echo "-- 1. isolation"
sid=$(spawn "$repo" "Say hi.")
if idle "$sid"; then
  if "${FLEET_ISOLATION:-$here/fleet-isolation.sh}" "$sid" >"$tmp/iso" 2>&1 && grep -q "isolation: ok" "$tmp/iso" && ! grep -q FAIL "$tmp/iso"; then
    ok "fleet-isolation.sh: isolation: ok, no FAIL"
  else
    bad "fleet-isolation.sh: isolation: ok, no FAIL"; sed 's/^/        /' "$tmp/iso"
  fi
fi

echo "-- 2. turns"
sid=$(spawn "$repo" "Create hello.txt containing hi.")
if idle "$sid"; then
  c1=$(tip "fleet/$sid")
  expect "turn: base is main's tip" "$main" "$(st "$sid" base)"
  expect "turn: commit is fleet/$sid's tip" "$c1" "$(st "$sid" commit)"
  fetch "$c1" >/dev/null || true
  expect "turn: hello.txt is hi" hi "$(git -C "$tmp/gh" show "$c1:hello.txt" 2>/dev/null | tr -d '[:space:]')"
  # Only a Pi that remembers turn 1 knows the name; writing it makes a commit.
  say "$sid" "Write the name of the file you just created into created.txt."
  if idle "$sid"; then
    c2=$(tip "fleet/$sid")
    fetch "$c2" >/dev/null || true
    expect "follow-up: the new commit's parent is the first" "$c1" "$(git -C "$tmp/gh" rev-parse "$c2^" 2>/dev/null)"
    if git -C "$tmp/gh" show "$c2:created.txt" 2>/dev/null | grep -q 'hello\.txt'; then
      ok "follow-up: Pi remembers; created.txt names hello.txt"
    else
      bad "follow-up: Pi remembers; created.txt names hello.txt"
    fi
  fi
  fork=$(api POST "/v1/sessions/$sid/fork" "$(jq -cn --arg k "e2e-$RANDOM" '{key: $k}')" | jq -r .sid)
  expect "fork: the fork's base is the parent's commit" "$(st "$sid" commit)" "$(st "$fork" base)"

  echo "-- 3. refusals"
  before=$(tip "fleet/$sid")
  say "$sid" "Run sleep 120 in bash, then create late.txt"
  # Abort once Pi has started the sleep.
  t=0
  while [ "$t" -lt 120 ]; do
    if said "$sid" "$want" | grep -q 'sleep 120'; then break; fi
    sleep 2; t=$((t + 2))
  done
  api POST "/v1/sessions/$sid/abort" '{}' >/dev/null
  if idle "$sid"; then
    case $(exited "$sid") in *aborted*) ok "abort: the turn says aborted" ;; *) bad "abort: the turn says aborted" "$(exited "$sid")" ;; esac
    expect "abort: fleet/$sid unchanged" "$before" "$(tip "fleet/$sid")"
    sleep 5
    if no_container "$sid"; then ok "abort: no fleet-$sid container"; else bad "abort: no fleet-$sid container"; fi
    say "$sid" "Reply with the single word ok."
    idle "$sid" && expect "abort: the next prompt runs" "0 " "$(exited "$sid")"
  fi
  for p in workflow token; do
    before=$(tip "fleet/$sid")
    case $p in
      workflow) say "$sid" 'Create .github/workflows/x.yml containing "on: push"' ;;
      token) say "$sid" 'Run this in bash: printenv GITHUB_TOKEN > token.txt' ;;
    esac
    idle "$sid" || continue
    out=$(said "$sid" "$(st "$sid" run)")
    case $p in
      workflow) grep -q 'push refused' <<<"$out" && grep -q '\.github/workflows' <<<"$out" ;;
      token) grep -q 'push refused' <<<"$out" ;;
    esac && ok "$p: push refused" || bad "$p: push refused" "Pi may have declined to do it; rerun"
    expect "$p: fleet/$sid unchanged" "$before" "$(tip "fleet/$sid")"
  done
fi

if [ "$nfail" = 0 ]; then echo "fleet-e2e: ok"; else echo "fleet-e2e: FAIL ($nfail)"; exit 1; fi

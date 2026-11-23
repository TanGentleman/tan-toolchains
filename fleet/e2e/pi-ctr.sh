#!/usr/bin/env bash
# fleetd's pi-ctr harness end to end, with no Mac: real fleetd, real
# pi-container run.sh and pi-ctr, a fake `container` that runs the command
# here (test/fake-container.sh, FAKE_CONTAINER_EXEC), a fake Pi, and a local
# bare repo standing in for GitHub through git's insteadOf.
set -euo pipefail
cd "$(dirname "$0")/.."
fleet=$(pwd -P)
pic=$(cd ../pi-container && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
pid=""
cleanup() { [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; [ -n "${KEEP:-}" ] || rm -rf "$tmp"; }
trap cleanup EXIT
go build -o "$tmp/fleetd" ./cmd/fleetd

real=sk-or-v1-REALKEY0123456789
token=testtoken-0123456789abcdef
home=$tmp/home cfg=$tmp/home/.config/pi-container world=$tmp/world disk=$tmp/disk
mkdir -p "$home/.fleet" "$cfg/certs" "$cfg/private" "$world/images" "$world/networks" "$world/containers" "$disk" "$tmp/bin" "$tmp/gh/o"
: > "$cfg/certs/ca.pem"
printf 'OPENROUTER_API_KEY=%s\nGITHUB_TOKEN=%s\nGIT_AUTHOR_NAME=Test\nGIT_AUTHOR_EMAIL=test@example.com\n' "$real" "$token" > "$cfg/env"
chmod 600 "$cfg/env"
img='[{"id":"sha256:t","configuration":{"descriptor":{"digest":"sha256:t"},"name":"pi-agent:local"},"variants":[{"config":{"config":{"Env":["PI_CONTAINER_PI_VERSION=1.5.2","PI_CONTAINER_CAPABILITIES=pi"]},"history":[]}}]}]'
printf '%s' "$img" > "$world/images/pi-agent_local.json"
printf '%s' "$img" > "$world/images/pi-proxy_local.json"
printf '[{"configuration":{"name":"pi-locked","mode":"hostOnly","ipv4Subnet":"172.30.240.0/24"},"id":"pi-locked","status":{"ipv4Gateway":"172.30.240.1","ipv4Subnet":"172.30.240.0/24"}}]' > "$world/networks/pi-locked.json"
printf 'pi-locked\n' > "$world/networks.list"
printf '[{"id":"pi-proxy","configuration":{"name":"pi-proxy"},"status":{"state":"running"}}]' > "$world/containers/pi-proxy.json"
printf '172.30.240.2\n' > "$cfg/private/proxy.addr"

git init -q --bare -b main "$tmp/gh/o/r.git"
cp e2e/pi-ctr/pre-receive "$tmp/gh/o/r.git/hooks/pre-receive"
git clone -q "$tmp/gh/o/r.git" "$tmp/seed" 2>/dev/null
git -C "$tmp/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m main
git -C "$tmp/seed" push -q origin HEAD:main
git -C "$tmp/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m dev
git -C "$tmp/seed" push -q origin HEAD:dev
main=$(git -C "$tmp/gh/o/r.git" rev-parse main) dev=$(git -C "$tmp/gh/o/r.git" rev-parse dev)
printf '[url "file://%s/gh/"]\n\tinsteadOf = https://github.com/\n' "$tmp" > "$disk/gitconfig"
cp e2e/pi-ctr/pi "$tmp/bin/pi"
# Records what fleetd hands pi-ctr, then runs the real one.
printf '#!/usr/bin/env bash\n{ env; printf "ARG %%s\\n" "$@"; } >> %q\nexec %q "$@"\n' "$tmp/pi-ctr.env" "$pic/pi-ctr" > "$tmp/bin/pi-ctr-spy"
# fleetd passes pi-ctr only an allowlisted environment, so the fake's
# settings travel inside a wrapper.
printf '#!/usr/bin/env bash\nexport FAKE_CONTAINER_WORLD=%q FAKE_CONTAINER_LOG=%q FAKE_CONTAINER_EXEC=%q FAKE_CONTAINER_PATH=%q\nexec %q "$@"\n' \
  "$world" "$tmp/container.log" "$disk" "$tmp/bin" "$pic/test/fake-container.sh" > "$tmp/container"
chmod +x "$tmp/bin/pi-ctr-spy" "$tmp/container"

U=http://127.0.0.1:17441
env HOME="$home" OPENROUTER_API_KEY="$real" PI_CTR_MAX_FILE_BYTES=1000 \
  CONTAINER_CLI="$tmp/container" \
  "$tmp/fleetd" -name a -url $U -listen 127.0.0.1:17441 -owner tan \
  -harness "ctr=$tmp/fleetd agent pi-ctr -bin $tmp/bin/pi-ctr-spy" 2>>"$tmp/fleetd.log" &
pid=$!
api() { curl -fsS -X "$1" -H 'Tailscale-User-Login: tan' -H 'Content-Type: application/json' ${3:+-d "$3"} "$U$2"; }
for _ in $(seq 50); do api GET /v1/node >/dev/null 2>&1 && break; sleep 0.1; done
fail() { echo "pi-ctr: FAIL: $*"; echo "--- fleetd log"; tail -20 "$tmp/fleetd.log"; tail -n 15 "$home"/.fleet/sessions/*/stderr-*.log; exit 1; }
idle() { # sid
  for _ in $(seq 200); do
    st=$(api GET "/v1/sessions/$1")
    [ "$(jq -r .running <<<"$st")" = false ] && [ "$(jq -r .head <<<"$st")" -gt 2 ] && return
    sleep 0.05
  done
  fail "session $1 never went idle"
}
say() { # sid key text
  api POST "/v1/sessions/$1/inputs" "$(jq -cn --arg k "$2" --arg t "$3" '{key: $k, text: $t}')" >/dev/null
  idle "$1"
}
st() { api GET "/v1/sessions/$1" | jq -r ".$2 // \"\""; }
tip() { git -C "$tmp/gh/o/r.git" rev-parse -q --verify "refs/heads/$1" || true; }
events() { api GET "/v1/sessions/$1/events"; }
# Through a file: grep -q closing the pipe early would fail curl under pipefail.
has() { events "$1" > "$tmp/events"; grep -q -- "$2" "$tmp/events"; }

# Turn 1: clone o/r, start from dev, push to fleet/<sid>, report dev as base.
sid=$(api POST /v1/sessions '{"harness":"ctr","repo":"o/r","branch":"dev","key":"k1","prompt":"write one"}' | jq -r .sid)
idle "$sid"
c1=$(tip "fleet/$sid")
[ -n "$c1" ] || fail "turn 1 pushed nothing: $(events "$sid" | tail -5)"
[ "$(st "$sid" commit)" = "$c1" ] || fail "exited commit $(st "$sid" commit), branch has $c1"
[ "$(st "$sid" base)" = "$dev" ] || fail "base $(st "$sid" base), want dev $dev"
[ "$(git -C "$tmp/gh/o/r.git" rev-parse "$c1^")" = "$dev" ] || fail "turn 1 did not start from dev"
[ "$(git -C "$tmp/gh/o/r.git" show "$c1:notes.txt")" = "write one" ] || fail "turn 1's change missing"

# Turn 2 continues fleet/<sid> on a fresh clone; base stays.
say "$sid" i2 "write two"
c2=$(tip "fleet/$sid")
[ "$(git -C "$tmp/gh/o/r.git" rev-parse "$c2^")" = "$c1" ] && [ "$(st "$sid" commit)" = "$c2" ] || fail "turn 2 did not continue fleet/$sid"
[ "$(git -C "$tmp/gh/o/r.git" show "$c2:notes.txt" | wc -l)" = 2 ] || fail "turn 2 lost turn 1's change"
[ "$(st "$sid" base)" = "$dev" ] || fail "base changed"

# A failed Pi turn still pushes: its transcript is kept, so its code is too.
say "$sid" i3 fail
c3=$(tip "fleet/$sid")
[ "$c3" != "$c2" ] && [ "$(st "$sid" commit)" = "$c3" ] || fail "failed turn did not push"
has "$sid" 'stopReason error' || fail "failed turn not reported as failed"

# Guardrails: each refuses the push and fails the turn, leaving the branch.
for p in token exact big workflow; do
  say "$sid" "g-$p" "$p"
  [ "$(tip "fleet/$sid")" = "$c3" ] || fail "$p: pushed anyway"
  [ "$(st "$sid" commit)" = "$c3" ] || fail "$p: exited recorded a commit"
  has "$sid" 'push refused' || fail "$p: no refusal shown"
done
has "$sid" 'no Workflows permission' || fail "workflow rejection not explained"
has "$sid" 'over the 1000 byte cap' || fail "size cap not explained"

# Only agent.json and pi/sessions/*.jsonl survive into the checkpoint.
say "$sid" i4 ext
left=$(cd "$home/.fleet/sessions/$sid/state" && find . -mindepth 1 | sort | tr '\n' ' ')
case $left in
  "./agent.json ./pi ./pi/sessions ./pi/sessions/2026-01-01_"*".jsonl ") ;;
  *) fail "state kept more than agent.json and the session file: $left" ;;
esac

# An aborted turn pushes nothing.
api POST "/v1/sessions/$sid/inputs" '{"key":"i5","text":"sleep"}' >/dev/null
for _ in $(seq 100); do events "$sid" | grep -q sleeping && break; sleep 0.05; done
api POST "/v1/sessions/$sid/abort" '{}' >/dev/null
idle "$sid"
[ "$(tip "fleet/$sid")" = "$c3" ] || fail "aborted turn pushed"
has "$sid" '"aborted"' || fail "abort not recorded"

# The session resumes Pi's own transcript after all of the above.
say "$sid" i6 "write three"
c4=$(tip "fleet/$sid")
[ "$(git -C "$tmp/gh/o/r.git" rev-parse "$c4^")" = "$c3" ] || fail "turn after abort did not continue"
[ "$(ls "$home/.fleet/sessions/$sid/state/pi/sessions" | wc -l)" = 1 ] || fail "pi started a second session file"
[ "$(grep -c '"type":"message"' "$home/.fleet/sessions/$sid/state/pi/sessions/"*.jsonl)" = 9 ] || fail "transcript should hold 9 turns (the aborted one is dropped)"

# A fork starts from the parent's last pushed commit, on its own branch.
fid=$(api POST "/v1/sessions/$sid/fork" '{"key":"f1"}' | jq -r .sid)
[ "$(st "$fid" base)" = "$c4" ] || fail "fork base $(st "$fid" base), want $c4"
say "$fid" f2 "write fork"
[ "$(git -C "$tmp/gh/o/r.git" rev-parse "$(tip "fleet/$fid")^")" = "$c4" ] || fail "fork did not start from the parent's commit"

# No branch: the default branch, reported as base.
nid=$(api POST /v1/sessions '{"harness":"ctr","repo":"o/r","key":"k2","prompt":"write main"}' | jq -r .sid)
idle "$nid"
[ "$(st "$nid" base)" = "$main" ] || fail "no-branch base $(st "$nid" base), want main $main"

# The real key reaches neither pi-ctr (args or env) nor the container.
say "$nid" n2 key
[ "$(git -C "$tmp/gh/o/r.git" show "$(tip "fleet/$nid"):key.txt")" = sk-or-v1-placeholder ] || fail "Pi did not see the placeholder"
grep -q "^PI_CTR_HOME=$home$" "$tmp/pi-ctr.env" || fail "pi-ctr did not get the real home"
grep -q '^HOME=' "$tmp/pi-ctr.env" && fail "pi-ctr got the adapter's HOME"
grep -q '^PI_CODING_AGENT_DIR=' "$tmp/pi-ctr.env" && fail "pi-ctr got a writable agent dir"
for f in "$tmp/pi-ctr.env" "$disk/env.log" "$tmp/container.log"; do
  ! grep -qF "$real" "$f" || fail "the real key reached $f"
done

events "$sid" > "$tmp/events"
ms=$(grep -o 'first_output_ms[^,]*' "$tmp/events" | tr -d '\\"' | sed 's/first_output_ms://' | sort -n | tr '\n' ' ')
echo "pi-ctr: ok ($sid; $ms)"

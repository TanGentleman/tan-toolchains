#!/usr/bin/env bash
# fleetd and its pi-ctr harness end to end, with no Mac: real fleetd, real
# pi-container run.sh and pi-ctr, a fake `container` that runs the command
# here (test/fake-container.sh, FAKE_CONTAINER_EXEC), a fake Pi, and a local
# bare repo standing in for GitHub through git's insteadOf. Also: owners
# only, retries, abort, and kill -9 of fleetd in the middle of a turn.
set -euo pipefail
# Hermetic: an inherited PI_* (E2E.md exports PI_CONFIG_DIR and PI_ENV_FILE)
# would point run.sh at a real profile and its env file.
for v in $(compgen -v PI_); do unset "$v"; done
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
home=$tmp/home cfg=$tmp/home/.pic/config world=$tmp/world disk=$tmp/disk
mkdir -p "$home/.pic/fleet" "$cfg/certs" "$cfg/private" "$world/images" "$world/networks" "$world/containers" "$disk" "$tmp/bin" "$tmp/gh/o"
: > "$cfg/certs/ca.pem"
printf 'OPENROUTER_API_KEY=%s\nGITHUB_TOKEN=%s\nGIT_AUTHOR_NAME=Test\nGIT_AUTHOR_EMAIL=test@example.com\n' "$real" "$token" > "$cfg/env"
chmod 600 "$cfg/env"
img='[{"id":"sha256:t","configuration":{"descriptor":{"digest":"sha256:t"},"name":"pi-agent:local"},"variants":[{"config":{"config":{"Env":["PI_CONTAINER_PI_VERSION=1.7.0","PI_CONTAINER_CAPABILITIES=pi,netlock"]},"history":[]}}]}]'
printf '%s' "$img" > "$world/images/pi-full_local.json"
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
api() { curl -fsS -X "$1" -H 'Tailscale-User-Login: tan' -H 'Content-Type: application/json' ${3:+-d "$3"} "$U$2"; }
# fleetd gets the real key in its environment; it must reach no turn.
# Arguments are more env, e.g. PI_IMAGE=min: the node's config.
start_fleetd() {
  env HOME="$home" OPENROUTER_API_KEY="$real" PI_CTR_MAX_FILE_BYTES=1000 FLEET_PI_CTR_BIN="$tmp/bin/pi-ctr-spy" \
    CONTAINER_CLI="$tmp/container" "$@" \
    "$tmp/fleetd" -name a -url $U -listen 127.0.0.1:17441 -owner tan 2>>"$tmp/fleetd.log" &
  pid=$!
  for _ in $(seq 50); do api GET /v1/node >/dev/null 2>&1 && return; sleep 0.1; done
  echo "pi-ctr: fleetd did not start"; cat "$tmp/fleetd.log"; exit 1
}
restart_fleetd() { kill "$pid"; wait "$pid" 2>/dev/null || true; start_fleetd "$@"; }
start_fleetd
fail() { echo "pi-ctr: FAIL: $*"; echo "--- fleetd log"; tail -20 "$tmp/fleetd.log"; tail -n 15 "$home"/.pic/fleet/sessions/*/stderr-*.log; exit 1; }
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

# GET /v1/node reports the node's config: the defaults, then the PI_* env
# fleetd was started with.
node=$(api GET /v1/node)
[ "$(jq -r '.config | "\(.image) \(.egress) \(.model_url)"' <<<"$node")" = "full standard openrouter" ] || fail "GET /v1/node config: $node"
restart_fleetd PI_IMAGE=min PI_MODEL_URL=http://gateway:8090
node=$(api GET /v1/node)
[ "$(jq -r '.config | "\(.image) \(.model_url)"' <<<"$node")" = "min http://gateway:8090" ] || fail "GET /v1/node with PI_IMAGE: $node"
restart_fleetd PI_IMAGE=agent
api GET /v1/node | jq -e '.config_error | contains("PI_IMAGE must be")' >/dev/null || fail "GET /v1/node hides a bad PI_IMAGE"
restart_fleetd

# Turn 1: clone o/r, start from dev, push to fleet/<sid>, report dev as base.
sid=$(api POST /v1/sessions '{"harness":"pi-ctr","repo":"o/r","branch":"dev","key":"k1","prompt":"write one"}' | jq -r .sid)
idle "$sid"
c1=$(tip "fleet/$sid")
[ -n "$c1" ] || fail "turn 1 pushed nothing: $(events "$sid" | tail -5)"
[ "$(st "$sid" commit)" = "$c1" ] || fail "exited commit $(st "$sid" commit), branch has $c1"
[ "$(st "$sid" base)" = "$dev" ] || fail "base $(st "$sid" base), want dev $dev"
[ "$(st "$sid" harness)" = pi-ctr ] || fail "created does not record the harness"
[ "$(git -C "$tmp/gh/o/r.git" rev-parse "$c1^")" = "$dev" ] || fail "turn 1 did not start from dev"
[ "$(git -C "$tmp/gh/o/r.git" show "$c1:notes.txt")" = "write one" ] || fail "turn 1's change missing"

# A retried spawn names the same session; only owners get in.
again=$(api POST /v1/sessions '{"harness":"pi-ctr","repo":"o/r","branch":"dev","key":"k1","prompt":"write one"}' | jq -r .sid)
[ "$again" = "$sid" ] || fail "retried spawn made $again"
code() { curl -s -o /dev/null -w '%{http_code}' ${2:+-H "Tailscale-User-Login: $2"} "$U$1"; }
[ "$(code "/v1/sessions/$sid")" = 401 ] || fail "no identity was not 401"
[ "$(code "/v1/sessions/$sid" bob)" = 403 ] || fail "a stranger was not 403"

# Turn 2 continues fleet/<sid> on a fresh clone; base stays.
say "$sid" i2 "write two"
c2=$(tip "fleet/$sid")
[ "$(git -C "$tmp/gh/o/r.git" rev-parse "$c2^")" = "$c1" ] && [ "$(st "$sid" commit)" = "$c2" ] || fail "turn 2 did not continue fleet/$sid"
[ "$(git -C "$tmp/gh/o/r.git" show "$c2:notes.txt" | wc -l)" -eq 2 ] || fail "turn 2 lost turn 1's change"
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
left=$(cd "$home/.pic/fleet/sessions/$sid/state" && find . -mindepth 1 | sort | tr '\n' ' ')
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
[ "$(ls "$home/.pic/fleet/sessions/$sid/state/pi/sessions" | wc -l)" -eq 1 ] || fail "pi started a second session file"
[ "$(grep -c '"type":"message"' "$home/.pic/fleet/sessions/$sid/state/pi/sessions/"*.jsonl)" = 9 ] || fail "transcript should hold 9 turns (the aborted one is dropped)"

# A fork starts from the parent's last pushed commit, on its own branch.
fid=$(api POST "/v1/sessions/$sid/fork" '{"key":"f1"}' | jq -r .sid)
[ "$(st "$fid" base)" = "$c4" ] || fail "fork base $(st "$fid" base), want $c4"
say "$fid" f2 "write fork"
[ "$(git -C "$tmp/gh/o/r.git" rev-parse "$(tip "fleet/$fid")^")" = "$c4" ] || fail "fork did not start from the parent's commit"

# No branch: the default branch, reported as base.
nid=$(api POST /v1/sessions '{"harness":"pi-ctr","repo":"o/r","key":"k2","prompt":"write main"}' | jq -r .sid)
idle "$nid"
[ "$(st "$nid" base)" = "$main" ] || fail "no-branch base $(st "$nid" base), want main $main"

# The real key reaches neither pi-ctr (args or env) nor the container.
say "$nid" n2 key
[ "$(git -C "$tmp/gh/o/r.git" show "$(tip "fleet/$nid"):key.txt")" = sk-or-v1-placeholder ] || fail "Pi did not see the placeholder"
grep -q "^PI_CTR_HOME=$home$" "$tmp/pi-ctr.env" || fail "pi-ctr did not get the real home"
grep -q '^FLEET_IMAGE=full$' "$tmp/pi-ctr.env" && grep -q '^FLEET_EGRESS=standard$' "$tmp/pi-ctr.env" &&
  grep -q '^FLEET_MODEL_URL=openrouter$' "$tmp/pi-ctr.env" || fail "pi-ctr did not get the node config fleetd recorded"
configs=$(api GET "/v1/sessions/$sid/events" | jq -sc '[.[] | select(.kind == "input") | .data.config] | unique')
[ "$configs" = '[{"image":"full","egress":"standard","model_url":"openrouter"}]' ] ||
  fail "input events record $configs, not the node config"
grep -q '^HOME=' "$tmp/pi-ctr.env" && fail "pi-ctr got the adapter's HOME"
grep -q '^PI_CODING_AGENT_DIR=' "$tmp/pi-ctr.env" && fail "pi-ctr got a writable agent dir"
for f in "$tmp/pi-ctr.env" "$disk/env.log" "$tmp/container.log"; do
  ! grep -qF "$real" "$f" || fail "the real key reached $f"
done

# fleetd dies mid-turn (kill -9) and restarts: the turn is recorded as
# exited, its input is not re-run, and the next turn resumes the transcript
# and the branch. The orphaned turn stops itself and removes its container,
# and the restart removes the container again before recording the exit.
before=$(tip "fleet/$sid")
api POST "/v1/sessions/$sid/inputs" '{"key":"i7","text":"sleep"}' >/dev/null
for _ in $(seq 100); do events "$sid" | grep -q sleeping && break; sleep 0.05; done
grep -q -- "--name fleet-$sid " "$tmp/container.log" || fail "the turn's container is not named after the session"
kill -9 "$pid"; wait "$pid" 2>/dev/null || true
for _ in $(seq 50); do pgrep -f "$tmp/" >/dev/null || break; sleep 0.1; done
! pgrep -f "$tmp/" >/dev/null || fail "the orphaned turn kept running: $(pgrep -af "$tmp/")"
[ "$(grep -c "CALL delete --force fleet-$sid\$" "$tmp/container.log")" -ge 2 ] || fail "the orphaned turn did not remove its container"
n=$(grep -c "CALL delete --force fleet-$sid\$" "$tmp/container.log")
start_fleetd
[ "$(grep -c "CALL delete --force fleet-$sid\$" "$tmp/container.log")" -gt "$n" ] || fail "the restart did not remove the container"
has "$sid" 'node restarted' || fail "the dead turn was not recorded"
say "$sid" i8 "write four"
[ "$(git -C "$tmp/gh/o/r.git" rev-parse "$(tip "fleet/$sid")^")" = "$before" ] || fail "turn after restart did not continue the branch"
[ "$(ls "$home/.pic/fleet/sessions/$sid/state/pi/sessions" | wc -l)" -eq 1 ] || fail "restart started a second session file"

# pi-container/test/fleet-e2e.sh, the release's step 8, against this fleetd.
printf '#!/bin/sh\necho "isolation: ok"\n' > "$tmp/bin/isolation"
chmod +x "$tmp/bin/isolation"
if ! FLEET_URL=$U FLEET_LOGIN=tan FLEET_ISOLATION="$tmp/bin/isolation" CONTAINER_CLI="$tmp/container" \
  PI_ENV_FILE="$cfg/env" GIT_CONFIG_GLOBAL="$disk/gitconfig" TURN_TIMEOUT=30 \
  "$pic/test/fleet-e2e.sh" o/r > "$tmp/fleet-e2e.log" 2>&1; then
  cat "$tmp/fleet-e2e.log"; fail "test/fleet-e2e.sh"
fi
grep -q "fleet-e2e: ok" "$tmp/fleet-e2e.log" || { cat "$tmp/fleet-e2e.log"; fail "test/fleet-e2e.sh did not say ok"; }
out=$(FLEET_URL=$U FLEET_LOGIN=tan PI_CONFIG_DIR="$cfg" GIT_CONFIG_GLOBAL="$disk/gitconfig" "$pic/test/fleet-e2e.sh" o/missing 2>&1) && fail "fleet-e2e.sh passed on a repo it can't read"
grep -q "can't read o/missing" <<<"$out" || fail "fleet-e2e.sh did not explain an unreadable repo: $out"

events "$sid" > "$tmp/events"
ms=$(grep -o 'first_output_ms[^,]*' "$tmp/events" | tr -d '\\"' | sed 's/first_output_ms://' | sort -n | tr '\n' ' ')
# Offline repo session: clones from a local mirror, pushes nothing, and
# keeps its commits in the session's repo.bundle for the next turn.
git clone -q --mirror "$tmp/gh/o/r.git" "$cfg/mirrors/o/r.git"
restart_fleetd PI_EGRESS=offline PI_MODEL_URL=http://10.0.0.5:8090
osid=$(api POST /v1/sessions '{"harness":"pi-ctr","repo":"o/r","key":"k-off","prompt":"write off1"}' | jq -r .sid)
idle "$osid"
o1=$(st "$osid" commit)
[ -n "$o1" ] || fail "offline turn recorded no commit: $(events "$osid" | tail -5)"
[ -z "$(tip "fleet/$osid")" ] || fail "offline turn pushed to GitHub"
b="$home/.pic/fleet/sessions/$osid/state/repo.bundle"
[ "$(git bundle list-heads "$b" | awk '{print $1}')" = "$o1" ] || fail "repo.bundle does not hold the turn's commit"
say "$osid" off2 "write off2"
o2=$(st "$osid" commit)
[ "$(git -C "$tmp/gh/o/r.git" rev-parse -q --verify "$o2^" 2>/dev/null || git --git-dir="$cfg/mirrors/o/r.git" fetch -q "$b" "refs/heads/fleet/$osid:refs/b" 2>/dev/null && git --git-dir="$cfg/mirrors/o/r.git" rev-parse "refs/b^")" = "$o1" ] ||
  fail "offline turn 2 did not continue from the bundle"
has "$osid" '"egress":"offline"' || fail "offline turns do not record egress offline"

echo "pi-ctr: ok ($sid; $ms)"

#!/usr/bin/env bash
# Tests for lib/release.sh: redaction and the release gate.
set -uo pipefail
. "$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
. "$root/lib/release.sh"

eq 1.6.1 "$(rel_semver 'container CLI version 1.6.1 (build: release, commit: abc)')" semver
eq "" "$(rel_semver 'no version')" "semver none"

out=$(printf '%s\n' 'key=sk-or-v1-0123456789abcdef tok=github_pat_11ABCDEFG_xyz123 old=ghp_abcdefghijk' |
  rel_redact)
eq 'key=sk-or-v1-<redacted> tok=github_pat_<redacted> old=ghp_<redacted>' "$out" "redact shapes"
out=$(printf '%s\n' 'mac.tail1234.ts.net 100.101.2.3 10.0.0.1 me@example.com' | rel_redact)
eq '<tailnet>.ts.net 100.x.x.x 10.0.0.1 <email>' "$out" "redact tailnet and email"
out=$(printf '%s\n' 'secret is hunter2.value[x]' | rel_redact 'hunter2.value[x]' '' ab)
eq 'secret is <redacted>' "$out" "redact literal values"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
good='{"sha":"abc","ci":{"conclusion":"success"},"fleetd_commit":"abc","stages":{
  "fresh":{"user":"pirel","date":"2026-01-01T00:00:00Z","pass":5,"fail":0,"skip":0},
  "verify":{"user":"pirel","date":"2026-01-01T01:00:00Z","pass":90,"fail":0,"skip":0},
  "manual":{"user":"pirel","date":"2026-01-01T02:00:00Z","pass":9,"fail":0,"skip":0},
  "fleet":{"user":"me","date":"2025-12-31T00:00:00Z","pass":4,"fail":0,"skip":0}}}'
printf '%s\n' "$good" >"$tmp/good.json"
rc 0 "gate passes a complete report" rel_gate "$tmp/good.json" abc
out=$(rel_gate "$tmp/good.json" def)
contains "not def" "$out" "gate checks the sha"
jq '.stages.verify.skip = 1 | .stages.fleet.fail = 2 | del(.stages.manual) | .ci.conclusion = "failure"' \
  "$tmp/good.json" >"$tmp/bad.json"
out=$(rel_gate "$tmp/bad.json" abc)
rc 1 "gate blocks a bad report" rel_gate "$tmp/bad.json" abc
contains "verify: 1 skipped" "$out" "gate blocks skips"
contains "fleet: 2 failed" "$out" "gate blocks failures"
contains "stage manual missing" "$out" "gate needs every stage"
contains "CI on abc is failure" "$out" "gate needs green CI"
jq '.stages.manual.user = "other" | .stages.fleet.user = "pirel"' "$tmp/good.json" >"$tmp/users.json"
out=$(rel_gate "$tmp/users.json" abc)
contains "ran in different accounts" "$out" "gate needs one test account"
contains "fleet ran in the test account pirel" "$out" "gate needs fleet from another account"
jq '.stages.fresh.date = "2026-01-02T00:00:00Z" | .stages.manual.date = "2025-01-01T00:00:00Z"' \
  "$tmp/good.json" >"$tmp/order.json"
out=$(rel_gate "$tmp/order.json" abc)
contains "verify ran before fresh" "$out" "gate checks fresh before verify"
contains "manual ran before verify" "$out" "gate checks verify before manual"
jq '.fleetd_commit = "abc-dirty"' "$tmp/good.json" >"$tmp/fleetd.json"
out=$(rel_gate "$tmp/fleetd.json" abc)
contains "fleetd was built from abc-dirty, not abc" "$out" "gate checks the fleetd commit"
printf 'not json' >"$tmp/broken.json"
rc 1 "gate refuses a broken report" rel_gate "$tmp/broken.json" abc

eq success "$(printf '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]}' | rel_ci_conclusion)" "ci success"
eq pending "$(printf '{"check_runs":[{"status":"in_progress","conclusion":null}]}' | rel_ci_conclusion)" "ci pending"
eq failure "$(printf '{"check_runs":[{"status":"completed","conclusion":"failure"}]}' | rel_ci_conclusion)" "ci failure"
eq none "$(printf '{"check_runs":[]}' | rel_ci_conclusion)" "ci none"

lines=$(printf '%s\n' '== Build' '  ok    built full' '  FAIL  proxy up' '  skip  no pi' 'mac-e2e.sh: 1 passed' | rel_e2e_lines)
eq "$(printf 'pass\tbuilt full\nfail\tproxy up\nskip\tno pi')" "$lines" "e2e lines"
st=$(printf '%s\n' "$lines" | rel_checks_json verify tester)
eq "1 1 1 verify tester" "$(jq -r '"\(.pass) \(.fail) \(.skip) \(.stage) \(.user)"' <<<"$st")" "stage counts"
eq "proxy up" "$(jq -r '.checks[1].name' <<<"$st")" "stage check names"

# release.sh report: merges the stages, redacts, and gates on CI.
home=$tmp/home bin=$tmp/bin rdir=$tmp/rel
mkdir -p "$home" "$bin" "$rdir"
for v in $(env | sed -n 's/^\(PI_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
sha=$(git -C "$root" rev-parse HEAD)
mkdir -p "$rdir/$sha"
for st in fresh verify manual fleet; do
  u=t
  [ "$st" = fleet ] && u=main
  printf '{"stage":"%s","user":"%s","date":"d","pass":1,"fail":0,"skip":0,"checks":[{"result":"pass","name":"key sk-or-v1-abcdefgh12345678"}]}\n' "$st" "$u" >"$rdir/$sha/$st.json"
done
jq --arg sha "$sha" '. + {fleetd_commit: $sha}' "$rdir/$sha/fleet.json" >"$tmp/f" && mv "$tmp/f" "$rdir/$sha/fleet.json"
printf '#!/bin/sh\necho "{\\"check_runs\\":[{\\"status\\":\\"completed\\",\\"conclusion\\":\\"$CI\\"}]}"\n' >"$bin/gh"
chmod +x "$bin/gh"
report() { env HOME="$home" PATH="$bin:$PATH" PI_RELEASE_DIR="$rdir" CI=$1 "$root/test/release.sh" report; }
out=$(report success)
contains "gate: open for $sha" "$out" "report opens the gate"
not_contains "abcdefgh12345678" "$(cat "$rdir/$sha/release.json")" "report redacts release.json"
eq success "$(jq -r .ci.conclusion "$rdir/$sha/release.json")" "report records CI"
eq "$sha" "$(jq -r .fleetd_commit "$rdir/$sha/release.json")" "report records the fleetd commit"
out=$(report failure)
contains "is failure" "$out" "report gates on CI"
cp "$rdir/$sha/fleet.json" "$tmp/fleet.json"
rm "$rdir/$sha/fleet.json"
out=$(report success)
contains "stage fleet missing" "$out" "report needs the fleet stage"
rel() { env HOME="$home" PATH="$bin:$PATH" PI_RELEASE_DIR="$rdir" "$root/test/release.sh" "$@"; }
out=$(rel)
contains "fleet: not run" "$out" "status lists a missing stage"
contains "fresh: 1 passed, 0 failed, 0 skipped (t, d)" "$out" "status lists a stage"
contains "next: main account, pic serve up" "$out" "status says fleet is next"
mkdir -p "$home/.pi-release" && echo "$sha" >"$home/.pi-release/sha"
jq '.fail = 1' "$rdir/$sha/verify.json" >"$tmp/v" && mv "$tmp/v" "$rdir/$sha/verify.json"
contains "next: test/release.sh account" "$(rel)" "status in the test account"
rm -r "$home/.pi-release"
cp "$tmp/fleet.json" "$rdir/$sha/fleet.json"
contains "next: main account, pic serve stopped: test/release.sh tester" "$(rel status)" "status says tester is next"
contains "test/release.sh account" "$(rel --help)" "help lists the stages"
envf=$tmp/env
printf 'OPENROUTER_API_KEY=sk-or-v1-abcdefgh12345678\n' >"$envf"
out=$(rel tester 'Bad' --env "$envf" --repo o/r 2>&1)
contains "usage: test/release.sh tester" "$out" "tester checks NAME"
out=$(rel tester pirel --env "$envf" 2>&1)
contains "needs --repo" "$out" "tester needs a repo"
out=$(rel tester pirel --env "$envf" --repo o/r 2>&1)
contains "has no GITHUB_TOKEN" "$out" "tester needs a token"
not_contains "abcdefgh12345678" "$out" "tester redacts its env file"
out=$(rel account 2>&1)
contains "run this in an account made by test/release.sh tester" "$out" "account needs tester"
out=$(rel fleet 2>&1)
contains "usage: test/release.sh fleet --repo OWNER/REPO" "$out" "fleet needs a repo"
rc 2 "unknown stage" env HOME="$home" PI_RELEASE_DIR="$rdir" "$root/test/release.sh" bogus

finish

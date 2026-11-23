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
good='{"sha":"abc","ci":{"conclusion":"success"},"stages":{
  "fresh":{"pass":5,"fail":0,"skip":0},"verify":{"pass":90,"fail":0,"skip":0},
  "manual":{"pass":9,"fail":0,"skip":0},"fleet":{"pass":4,"fail":0,"skip":0}}}'
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
  printf '{"stage":"%s","user":"t","date":"d","pass":1,"fail":0,"skip":0,"checks":[{"result":"pass","name":"key sk-or-v1-abcdefgh12345678"}]}\n' "$st" >"$rdir/$sha/$st.json"
done
printf '#!/bin/sh\necho "{\\"check_runs\\":[{\\"status\\":\\"completed\\",\\"conclusion\\":\\"$CI\\"}]}"\n' >"$bin/gh"
chmod +x "$bin/gh"
report() { env HOME="$home" PATH="$bin:$PATH" PI_RELEASE_DIR="$rdir" CI=$1 "$root/test/release.sh" report; }
out=$(report success)
contains "gate: open for $sha" "$out" "report opens the gate"
not_contains "abcdefgh12345678" "$(cat "$rdir/$sha/release.json")" "report redacts release.json"
eq success "$(jq -r .ci.conclusion "$rdir/$sha/release.json")" "report records CI"
out=$(report failure)
contains "is failure" "$out" "report gates on CI"
rm "$rdir/$sha/fleet.json"
out=$(report success)
contains "stage fleet missing" "$out" "report needs the fleet stage"
rc 2 "unknown stage" env HOME="$home" PI_RELEASE_DIR="$rdir" "$root/test/release.sh" bogus

finish

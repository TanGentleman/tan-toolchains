# Release-gate helpers for test/release.sh. Sourced, never executed.

# The `container` release the JSON contract was observed on (AGENTS.md).
pi_release_container_version=1.6.1
pi_release_macos_major=26

# rel_semver TEXT: the first x.y.z in TEXT.
rel_semver() {
  printf '%s\n' "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

# rel_redact [VALUE...]: copy stdin to stdout with each non-empty VALUE and
# anything shaped like a key, token, tailnet name or tailnet IP replaced.
rel_redact() {
  local v script=''
  for v in "$@"; do
    [ ${#v} -ge 4 ] || continue
    v=$(printf '%s' "$v" | sed 's/[][\\/.*^$|+?(){}]/\\&/g')
    script="${script}s/${v}/<redacted>/g;"
  done
  sed -E -u "${script}"'
    s/sk-or-v1-[A-Za-z0-9]{8,}/sk-or-v1-<redacted>/g
    s/(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{8,}/\1_<redacted>/g
    s/github_pat_[A-Za-z0-9_]{8,}/github_pat_<redacted>/g
    s/[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.ts\.net/<tailnet>.ts.net/g
    s/(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}/\1100.x.x.x/g
    s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g'
}

# rel_env_value FILE NAME: the last NAME= value in an env file.
rel_env_value() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1 | tr -d '\r'
}

# rel_gate REPORT_JSON SHA: print one line per reason the report blocks a
# release of SHA; status 0 only when there is none.
rel_gate() {
  jq -r --arg sha "$2" '
    def need($s): if (.stages[$s] // null) == null then "stage \($s) missing" else empty end;
    (if .sha != $sha then "report is for \(.sha), not \($sha)" else empty end),
    need("fresh"), need("verify"), need("manual"), need("fleet"),
    (.stages | to_entries[] | .key as $k | .value |
      (if (.fail // 0) > 0 then "\($k): \(.fail) failed" else empty end),
      (if (.skip // 0) > 0 then "\($k): \(.skip) skipped" else empty end)),
    (if .ci.conclusion != "success" then "CI on \($sha) is \(.ci.conclusion // "unknown")" else empty end),
    (.stages.fresh.user // null) as $t
    | (.stages.fresh.account_id // "") as $id
    | (if $t != null and $id == "" then "fresh did not run in an account made by tester" else empty end),
      (if $t != null and ([.stages.verify, .stages.manual] | any(. != null and (.account_id // "") != $id))
       then "fresh, verify and manual ran in different accounts" else empty end),
      (if $t != null and .stages.fleet.user == $t then "fleet ran in the test account \($t)" else empty end),
      (if $t != null and .test_machine.admin != false then "the test account is not a standard account" else empty end),
      (if (.stages.fresh.date // "") > (.stages.verify.date // "~") then "verify ran before fresh" else empty end),
      (if (.stages.verify.date // "") > (.stages.manual.date // "~") then "manual ran before verify" else empty end),
      (if (.stages.fleet // null) != null and .fleetd_commit != $sha
       then "fleetd was built from \(.fleetd_commit // "an unknown commit"), not \($sha)" else empty end)
  ' "$1" 2>/dev/null | grep . && return 1
  jq -e . "$1" >/dev/null 2>&1 || { echo "report $1 is not JSON"; return 1; }
  return 0
}

# rel_old_tester NAME: status 0 when the existing account NAME may be deleted
# by test/release.sh tester: tester made it (~/.pi-release/sha), it is not an
# admin, and nothing runs as it. Otherwise print why and return 1.
rel_old_tester() {
  local home
  home=$(dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  if [ -z "$home" ] || ! sudo test -f "$home/.pi-release/sha"; then
    echo "account $1 exists and was not made by test/release.sh tester; delete it yourself or pick another NAME"
    return 1
  fi
  if id -Gn "$1" | tr ' ' '\n' | grep -qx admin; then
    echo "$1 is an admin; not deleting it"
    return 1
  fi
  if ps -axo uid= | awk -v u="$(id -u "$1")" '$1 == u { f = 1 } END { exit !f }'; then
    echo "$1 has processes running; log it out first"
    return 1
  fi
  return 0
}

# rel_ci_conclusion: read GitHub's check-runs JSON for one commit and print
# success, pending, failure or none.
rel_ci_conclusion() {
  jq -r '
    [.check_runs[]?] as $r
    | if ($r | length) == 0 then "none"
      elif any($r[]; .status != "completed") then "pending"
      elif all($r[]; .conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral") then "success"
      else "failure" end'
}

# rel_checks_json STAGE USER: read "result<TAB>name" lines (result is
# pass, fail or skip) and print the stage object.
rel_checks_json() {
  jq -R -s --arg stage "$1" --arg user "$2" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    [split("\n")[] | select(length > 0) | split("\t") | {result: .[0], name: (.[1:] | join("\t"))}] as $c
    | {stage: $stage, user: $user, date: $date,
       pass: ([$c[] | select(.result == "pass")] | length),
       fail: ([$c[] | select(.result == "fail")] | length),
       skip: ([$c[] | select(.result == "skip")] | length),
       checks: $c}'
}

# rel_e2e_lines: turn mac-e2e.sh output into "result<TAB>name" lines.
rel_e2e_lines() {
  sed -n -E 's/^  ok    (.*)$/pass	\1/p; s/^  FAIL  (.*)$/fail	\1/p; s/^  skip  (.*)$/skip	\1/p'
}

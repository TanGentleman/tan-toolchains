#!/usr/bin/env bash
# Run every pi-container test. No Apple container, Docker, or network needed.
# Requires jq.
#
#   ./test/run-tests.sh
#
# Exits non-zero if any test file fails. Safe to run in CI and on a laptop.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

fail=0

command -v jq >/dev/null 2>&1 || {
  printf 'run-tests.sh: jq is required; macOS 26 ships /usr/bin/jq, so check PATH (Linux: apt-get install jq)\n' >&2
  exit 1
}

# Fixtures must stay parseable; a broken JSON file would make a parser test
# fail for the wrong reason.
while IFS= read -r f; do
  jq -e . "$f" >/dev/null 2>&1 || { printf 'FAIL: invalid JSON fixture: %s\n' "$f" >&2; fail=1; }
done < <(find "$here/fixtures/container" -name '*.json' -type f)

# Each test file ends its stdout with "<name>: N passed, M failed".
passed=0
failed=0
files=0
uncounted=""
log=$(mktemp "${TMPDIR:-/tmp}/run-tests.XXXXXX")
trap 'rm -f "$log"' EXIT

for f in "$here"/test-*.sh; do
  printf '== %s\n' "${f##*/}"
  bash "$f" | tee "$log"
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then fail=1; fi
  files=$((files + 1))
  counts=$(sed -n 's/^.*: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\1 \2/p' "$log" | tail -n 1)
  if [ -n "$counts" ]; then
    passed=$((passed + ${counts% *}))
    failed=$((failed + ${counts#* }))
  else
    uncounted="$uncounted ${f##*/}"
  fi
done

summary="$passed passed, $failed failed across $files files"
[ -z "$uncounted" ] || summary="$summary; no count from:$uncounted"
if [ "$fail" -eq 0 ]; then
  printf 'run-tests.sh: all tests passed (%s)\n' "$summary"
else
  printf 'run-tests.sh: failures above (%s)\n' "$summary" >&2
fi
exit "$fail"

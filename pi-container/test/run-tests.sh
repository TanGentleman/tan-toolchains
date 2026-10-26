#!/usr/bin/env bash
# Run every pi-container test. No Apple container, Docker, or network needed.
# Requires jq.
#
#   ./test/run-tests.sh
#
# Exits non-zero if any test file fails. Safe to run in CI and on a laptop.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(CDPATH= cd -- "$here/.." && pwd -P)

fail=0

command -v jq >/dev/null 2>&1 || {
  printf 'run-tests.sh: jq is required (install with: brew install jq)\n' >&2
  exit 1
}

# Fixtures must stay parseable; a broken JSON file would make a parser test
# fail for the wrong reason.
while IFS= read -r f; do
  jq -e . "$f" >/dev/null 2>&1 || { printf 'FAIL: invalid JSON fixture: %s\n' "$f" >&2; fail=1; }
done < <(find "$here/fixtures/container" -name '*.json' -type f)

for f in "$here"/test-*.sh; do
  printf '== %s\n' "${f##*/}"
  if ! bash "$f"; then fail=1; fi
done

# The naming tests predate the test/ directory and stay where run.sh users and
# the README expect them.
printf '== test-names.sh\n'
if ! bash "$root/test-names.sh"; then fail=1; fi

if [ "$fail" -eq 0 ]; then
  printf 'run-tests.sh: all tests passed\n'
else
  printf 'run-tests.sh: failures above\n' >&2
fi
exit "$fail"

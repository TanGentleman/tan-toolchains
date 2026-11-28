#!/usr/bin/env bash
# Unit tests for proxy.py's route policy (test_proxy.py). No container runtime.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# The policy code imports on macOS's python3 (3.9); main() itself needs 3.11.
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
  echo "test-proxy.sh: FAIL: needs python3 3.9 or newer" >&2
  exit 1
fi
out=$(PYTHONDONTWRITEBYTECODE=1 python3 "$here/test_proxy.py" 2>&1)
status=$?
ran=$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9][0-9]*\) tests* in .*/\1/p')
bad=$(printf '%s\n' "$out" | grep -cE '^(FAIL|ERROR): ')
if [ "$status" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  [ "$bad" -gt 0 ] || bad=1
fi
printf 'test-proxy.sh: %d passed, %d failed\n' "$(( ${ran:-0} - bad < 0 ? 0 : ${ran:-0} - bad ))" "$bad"
exit "$status"

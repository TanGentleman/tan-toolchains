#!/usr/bin/env bash
# Unit tests for proxy.py's route policy (test_proxy.py). No container runtime.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# The policy code imports on macOS's python3 (3.9); main() itself needs 3.11.
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
  echo "test-proxy.sh: FAIL: needs python3 3.9 or newer" >&2
  exit 1
fi
PYTHONDONTWRITEBYTECODE=1 python3 "$here/test_proxy.py" 2>&1 | tail -n 3
exit "${PIPESTATUS[0]}"

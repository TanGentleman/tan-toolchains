#!/usr/bin/env bash
# Headless Pi integration: prove `on` installs a hook that runs before the model.
# Requires `pi` on PATH and no API keys in the environment.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
bin=${1:-"$root/zig-out/bin/enforcer"}
case $bin in
  /*) ;;
  *) bin="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")" ;;
esac

command -v pi >/dev/null 2>&1 || {
  echo "pi-integration: pi is not on PATH" >&2
  exit 1
}
[ -x "$bin" ] || {
  echo "pi-integration: missing executable: $bin" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/agent" "$tmp/work"

run_pi() { # prompt, stdout, stderr
  local prompt=$1 out=$2 err=$3 code=0
  (
    cd "$tmp/work"
    env -i \
      HOME="$tmp/home" \
      PATH="$PATH" \
      PI_CODING_AGENT_DIR="$tmp/agent" \
      PI_TELEMETRY=0 \
      TERM=xterm \
      pi -p --no-session --offline --no-skills --no-prompt-templates \
      --no-themes --no-context-files "$prompt" >"$out" 2>"$err"
  ) || code=$?
  return "$code"
}

fail() {
  echo "pi-integration: $*" >&2
  for f in blocked.out blocked.err clean.out clean.err off.out off.err; do
    [ -s "$tmp/$f" ] && { echo "--- $f" >&2; cat "$tmp/$f" >&2; }
  done
  exit 1
}

HOME="$tmp/home" PI_CODING_AGENT_DIR="$tmp/agent" "$bin" on >/dev/null
[ -f "$tmp/agent/extensions/enforcer.ts" ] || fail "enforcer on did not write the extension"

# Blocked: the hook consumes the prompt, so Pi exits 0 before checking auth.
code=0
run_pi "please use ghp_abc" "$tmp/blocked.out" "$tmp/blocked.err" || code=$?
[ "$code" -eq 0 ] || fail "blocked prompt exited $code, expected 0"
[ ! -s "$tmp/blocked.out" ] || fail "blocked prompt wrote to stdout"
[ ! -s "$tmp/blocked.err" ] || fail "blocked prompt wrote to stderr"

# Clean: the hook continues, so Pi reaches the missing-auth check.
code=0
run_pi "hello" "$tmp/clean.out" "$tmp/clean.err" || code=$?
[ "$code" -eq 1 ] || fail "clean prompt exited $code, expected auth failure 1"
grep -q "No API key found" "$tmp/clean.err" || fail "clean prompt did not reach the auth check"

# Removed: the same blocked prompt now reaches the missing-auth check.
HOME="$tmp/home" PI_CODING_AGENT_DIR="$tmp/agent" "$bin" off >/dev/null
[ ! -e "$tmp/agent/extensions/enforcer.ts" ] || fail "enforcer off did not remove the extension"
code=0
run_pi "please use ghp_abc" "$tmp/off.out" "$tmp/off.err" || code=$?
[ "$code" -eq 1 ] || fail "prompt after off exited $code, expected auth failure 1"
grep -q "No API key found" "$tmp/off.err" || fail "prompt after off still used the hook"

echo "pi integration ok"

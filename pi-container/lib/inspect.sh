# Parsers for Apple's `container` CLI JSON output. Sourced, never executed.
#
# Every function reads JSON on stdin and prints one value on stdout. The output
# shapes are pinned by pi-container/test/fixtures/container/ and exercised by
# test/test-inspect.sh. Refresh the fixtures on a Mac with
# test/record-fixtures.sh. If Apple changes a shape, a unit test fails instead
# of a production run.
#
# Quirks this module owns:
#   * raw JSON escapes slashes as \/ (jq hides it, plain grep does not)
#   * inspect may nest state under status or expose it top-level
#   * host-only networks may report internal=true or mode=hostOnly/host-only
#   * image inspect may expose the version as config Env, an image label, or
#     only in build history

pi_json_unescape_slashes() {
  sed 's|\\/|/|g'
}

# running|stopped|stopping|exited|created|paused|unknown, or empty when absent.
# Accept both nested and top-level state shapes.
pi_proxy_state_from_json() {
  awk '
    BEGIN { RS = "}" }
    /"state"[[:space:]]*:[[:space:]]*"/ || /"status"[[:space:]]*:[[:space:]]*"/ {
      s = $0
      sub(/.*"(state|status)"[[:space:]]*:[[:space:]]*"/, "", s)
      sub(/".*/, "", s)
      if (s ~ /^(running|stopped|stopping|exited|created|paused|unknown)$/) state = s
    }
    END { print state }
  '
}

# The Pi version recorded at image build time. Prefer the stamped environment
# value, then the label, then build history for older images. Empty when none.
pi_image_version_from_json() {
  local json version
  json=$(cat)
  version=$(printf '%s\n' "$json" |
    sed -n 's/.*PI_CONTAINER_PI_VERSION=\([^"\\]*\).*/\1/p' |
    head -n 1)
  if [ -z "$version" ]; then
    version=$(printf '%s\n' "$json" |
      sed -n 's/.*"pi-container\.pi-version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
      head -n 1)
  fi
  if [ -z "$version" ]; then
    # Stop at a space or a quote: a command that ends at the version would
    # otherwise capture the closing JSON quote.
    version=$(printf '%s\n' "$json" |
      sed -n 's/.*RUN[^"]*[[:space:]]PI_VERSION=\([^ "}]*\).*/\1/p' |
      head -n 1)
  fi
  [ -z "$version" ] || printf '%s\n' "$version"
}

# Classify a network inspect payload as one of:
#   ok                 verified host-only/internal
#   internal-false     explicitly not internal
#   mode-not-host-only a mode is present but is neither hostOnly nor host-only
#   unverified         neither internal=true nor hostOnly mode is present
# The order matches run.sh's historical checks; internal=false wins.
pi_network_host_only_verdict() {
  local json
  json=$(pi_json_unescape_slashes)
  if printf '%s\n' "$json" | grep -Eq '"internal"[[:space:]]*:[[:space:]]*"?false"?'; then
    printf 'internal-false\n'
    return 0
  fi
  if printf '%s\n' "$json" | grep -Eq '"mode"[[:space:]]*:[[:space:]]*"' && \
     ! printf '%s\n' "$json" | grep -Eq '"mode"[[:space:]]*:[[:space:]]*"(hostOnly|host-only)"'; then
    printf 'mode-not-host-only\n'
    return 0
  fi
  if ! printf '%s\n' "$json" | grep -Eq '"internal"[[:space:]]*:[[:space:]]*"?true"?' && \
     ! printf '%s\n' "$json" | grep -Eq '"mode"[[:space:]]*:[[:space:]]*"(hostOnly|host-only)"'; then
    printf 'unverified\n'
    return 0
  fi
  printf 'ok\n'
}

# Exit 0 when the inspect payload mentions the subnet. Slashes are unescaped
# first so 172.30.240.0\/24 matches 172.30.240.0/24.
pi_network_has_subnet() { # subnet
  pi_json_unescape_slashes | grep -qF "$1"
}

# Value of a label in a volume inspect payload. Slashes in label values may be
# escaped as \/; normalise first. Empty when the key is absent.
pi_volume_label_from_json() { # key
  sed -n 's|\\/|/|g; s/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

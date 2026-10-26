# Parsers for Apple's `container` CLI JSON output. Sourced, never executed.
#
# Every function reads JSON on stdin. Scalar parsers print one value on stdout;
# predicates return a status. Payloads are arrays, and the parsers accept only
# the paths below: an unexpected shape yields empty output or a failing
# predicate. jq is a hard dependency: callers fail early when it is absent.
#
# Observed Apple `container` shapes (2026-10, macOS 26):
#   * `container inspect <name>` is an array; state is at [0].status.state
#   * `container network inspect <name>` is an array; mode is at
#     [0].configuration.mode, subnets at [0].configuration.ipv4Subnet and
#     [0].status.ipv4Subnet
#   * `container image inspect <name>` is an array; image config is at
#     [0].variants[0].config.config (Env/Labels) and history is at
#     [0].variants[0].config.history
#   * `container volume inspect <name>` is an array; labels are at
#     [0].configuration.labels
#   * container 1.4.1+ emits plain `/`; older captures may use `\/`, and jq
#     decodes both, so no textual unescaping pass is needed
#
# Fixtures live in pi-container/test/fixtures/container/ and are exercised by
# test/test-inspect.sh. Refresh recorded captures on a Mac with
# test/record-fixtures.sh.

# running|stopped|stopping|exited|created|paused|unknown, or empty when absent
# or unrecognised.
pi_proxy_state_from_json() {
  jq -r '
    .[0]?
    | (.status?.state? // empty)
    | select(. as $s |
        ["running", "stopped", "stopping", "exited", "created", "paused", "unknown"]
        | index($s))
  ' 2>/dev/null
}

# The Pi version recorded at image build time: the stamped environment value,
# then the image label, then build history. Empty when none is present.
pi_image_version_from_json() {
  jq -r '
    def variant: .[0]?.variants[0]?;
    def env_version:
      [ (variant.config.config.Env[]?)
        | select(type == "string")
        | (capture("^PI_CONTAINER_PI_VERSION=(?<v>.*)$")? // {})
        | .v? // empty
      ] | .[0] // empty;
    def label_version:
      [ ((variant.config.config.Labels // {})["pi-container.pi-version"]?)
      ] | map(select(type == "string" and . != "")) | .[0] // empty;
    def history_version:
      [ (variant.config.history[]?.created_by?)
        | select(type == "string")
        | (capture("(^|\\s)PI_VERSION=(?<v>[^\\s\"}]+)")? // {})
        | .v? // empty
      ] | .[0] // empty;
    [env_version, label_version, history_version]
    | map(select(. != null and . != ""))
    | .[0] // empty
  ' 2>/dev/null
}

# Classify a network inspect payload:
#   ok             configuration.mode is hostOnly
#   not-host-only  a different mode is present
#   unverified     mode is missing or not a string
pi_network_host_only_verdict() {
  local mode
  if ! mode=$(jq -r '
        .[0]?
        | (.configuration?.mode? // empty)
        | select(type == "string")
      ' 2>/dev/null); then
    printf 'unverified\n'
    return 0
  fi
  case $mode in
    hostOnly) printf 'ok\n' ;;
    '') printf 'unverified\n' ;;
    *) printf 'not-host-only\n' ;;
  esac
}

# Exit 0 when every subnet field present in the payload matches. Apple exposes
# the requested value at configuration.ipv4Subnet and the active value at
# status.ipv4Subnet; if both are present, both must match.
pi_network_has_subnet() { # subnet
  jq -e --arg subnet "$1" '
    .[0]?
    | [ .configuration?.ipv4Subnet?, .status?.ipv4Subnet? ]
    | map(select(type == "string"))
    | length > 0 and (unique == [$subnet])
  ' >/dev/null 2>&1
}

# Value of a label in a volume inspect payload. Empty when the key is absent.
pi_volume_label_from_json() { # key
  jq -r --arg key "$1" '
    .[0]?
    | (.configuration?.labels // {})[$key]
    | if type == "string" then . else empty end
  ' 2>/dev/null
}

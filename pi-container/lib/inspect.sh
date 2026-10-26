# Parsers for Apple's `container` CLI JSON output. Sourced, never executed.
#
# Every function reads JSON on stdin. Scalar parsers print one value on stdout;
# predicates return a status. jq is a hard dependency: callers should fail early
# with a clear message when it is absent. The shapes below are pinned by
# pi-container/test/fixtures/container/ and exercised by test/test-inspect.sh.
# Refresh the primary captures on a Mac with test/record-fixtures.sh.
#
# Observed Apple `container` shapes (2026-10, macOS 26):
#   * `container inspect <name>` is an array; state is at [0].status.state
#   * `container network inspect <name>` is an array; mode is at
#     [0].configuration.mode, subnets at [0].configuration.ipv4Subnet and
#     [0].status.ipv4Subnet
#   * `container image inspect <name>` is an array; image config is nested at
#     [0].variants[0].config.config (Env/Labels) and history is at
#     [0].variants[0].config.history
#   * `container volume inspect <name>` is an array; labels are at
#     [0].configuration.labels
#   * jq decodes JSON's `\/` escapes, so no textual unescaping pass is needed

# running|stopped|stopping|exited|created|paused|unknown, or empty when absent.
# Prefer the observed [0].status.state shape, then the older top-level status
# string/state shapes. This is deterministic: a later field never overrides an
# earlier one.
pi_proxy_state_from_json() {
  jq -r '
    def container: if type == "array" then .[0] else . end;
    container
    | [
        (if (.status | type) == "object" then (.status.state // empty) else empty end),
        (if (.status | type) == "string" then .status else empty end),
        (.state // empty)
      ]
    | map(select(type == "string"))
    | map(select(. as $s |
        ["running", "stopped", "stopping", "exited", "created", "paused", "unknown"]
        | index($s)))
    | .[0] // empty
  ' 2>/dev/null
}

# The Pi version recorded at image build time. Prefer the stamped environment
# value, then the image label, then build history for older images. Empty when
# none. Apple nests the real image config under variants; the top-level
# configuration fallback keeps older captures and other runtimes working.
pi_image_version_from_json() {
  jq -r '
    def container: if type == "array" then .[0] else . end;
    def env_version:
      container
      | [ ((.variants[]?.config.config.Env[]?), (.configuration.env[]?))
        | select(type == "string")
        | (capture("^PI_CONTAINER_PI_VERSION=(?<v>.*)$")? // {})
        | .v? // empty
      ] | .[0] // empty;
    def label_version:
      container
      | [ ((.variants[]?.config.config.Labels // {})["pi-container.pi-version"]?),
        ((.configuration.labels // {})["pi-container.pi-version"]?)
      ] | map(select(type == "string" and . != "")) | .[0] // empty;
    def history_version:
      container
      | [ ((.variants[]?.config.history[]?.created_by?), (.history[]?.created_by?))
        | select(type == "string")
        | (capture("(^|\\s)PI_VERSION=(?<v>[^\\s\"}]+)")? // {})
        | .v? // empty
      ] | .[0] // empty;
    [env_version, label_version, history_version]
    | map(select(. != null and . != ""))
    | .[0] // empty
  ' 2>/dev/null
}

# Classify a network inspect payload as one of:
#   ok                 verified host-only/internal
#   internal-false     explicitly not internal
#   mode-not-host-only a mode is present but is neither hostOnly nor host-only
#   unverified         neither internal=true nor hostOnly mode is present
# internal=false wins, then a non-host-only mode, then the positive markers.
pi_network_host_only_verdict() {
  local values mode internal
  values=$(jq -r '
    def container: if type == "array" then .[0] else . end;
    def boolstr:
      if . == true then "true"
      elif . == false then "false"
      elif . == null then ""
      else tostring
      end;
    container
    | [ ((.configuration // {}) | (.mode? // "")),
        ((.configuration // {}) | (.internal? | boolstr)) ]
    | @tsv
  ' 2>/dev/null) || { printf 'unverified\n'; return 0; }
  mode=${values%%$'\t'*}
  internal=${values#*$'\t'}
  if [ "$internal" = false ]; then
    printf 'internal-false\n'
    return 0
  fi
  if [ -n "$mode" ] && [ "$mode" != hostOnly ] && [ "$mode" != host-only ]; then
    printf 'mode-not-host-only\n'
    return 0
  fi
  if [ "$internal" = true ] || [ "$mode" = hostOnly ] || [ "$mode" = host-only ]; then
    printf 'ok\n'
    return 0
  fi
  printf 'unverified\n'
}

# Exit 0 when the inspect payload lists the subnet. Apple exposes the requested
# value at configuration.ipv4Subnet and the active value at status.ipv4Subnet;
# older captures used configuration.subnet. If more than one value is present,
# all of them must match.
pi_network_has_subnet() { # subnet
  jq -e --arg subnet "$1" '
    def container: if type == "array" then .[0] else . end;
    container
    | [ .configuration.ipv4Subnet?, .status.ipv4Subnet?,
        .configuration.subnet?, .status.subnet? ]
    | map(select(type == "string"))
    | length > 0 and (unique == [$subnet])
  ' >/dev/null 2>&1
}

# Value of a label in a volume inspect payload. Empty when the key is absent.
pi_volume_label_from_json() { # key
  jq -r --arg key "$1" '
    def container: if type == "array" then .[0] else . end;
    container
    | (.configuration.labels // {})[$key]
    | if type == "string" then . else empty end
  ' 2>/dev/null
}

# Assumptions about external output

`run.sh` and `clear.sh` read Apple's `container` CLI. `lib/inspect.sh` parses
only the paths below with `jq`, observed against the `container` version in
`test/fixtures/container/provenance.txt` (first 1.6.1 on `macOS 26`, 2026-10;
1.7.1 also passes `test/migrate-check.sh` and `run.sh check`, 2026-11). A different shape yields no value or an `unverified` network
verdict.
A change in Apple's output should fail `test/test-inspect.sh` or
`test/test-integration.sh` before it fails a real run.

Since `container` 1.4.1, JSON output no longer escapes forward slashes as
`\/`. Older captures may still contain the escaped form; `jq` decodes both, so
the parsers have no unescape pass. `network/host-only-escaped.json` and
`volume/escaped-labels.json` keep the older form covered.

`jq` is a hard dependency for `run.sh` normal/check/proxy and `clear.sh`
list/nuke; those paths fail early with an install hint when it is missing.

Refresh the recorded captures on a Mac with `./test/record-fixtures.sh`. It
writes to a temporary file and replaces a fixture only after the output parses
as JSON, so a failed capture leaves the old fixture in place. See
`test/fixtures/container/README.md`.

| Assumption | Code | Fixture |
| --- | --- | --- |
| `container inspect <name>` is an array; state is at `[0].status.state`. Values are `running`, `stopped`, `stopping`, `exited`, `created`, `paused`, `unknown`. | `lib/inspect.sh: pi_proxy_state_from_json` | `inspect/proxy-running.json`, `inspect/proxy-stopped.json`, `inspect/proxy-paused.json` |
| A failed `container inspect` is `absent`; an existing container with no recognised state is `unknown` and is recreated. | `run.sh: proxy_state`, `ensure_proxy` | `test/test-integration.sh` |
| `container network inspect <name>` is an array; the only host-only mode is `[0].configuration.mode == "hostOnly"`. Any other mode is `not-host-only`; a missing or non-string mode is `unverified`. | `lib/inspect.sh: pi_network_host_only_verdict` | `network/host-only.json`, `network/nat.json`, `network/no-mode.json` |
| Subnets are `[0].configuration.ipv4Subnet` and `[0].status.ipv4Subnet`. Every subnet present must match `PI_LOCKED_SUBNET`. jq decodes both `/` and older `\/` captures, so no textual unescape pass is needed. | `lib/inspect.sh: pi_network_has_subnet` | `network/host-only.json`, `network/host-only-escaped.json` |
| A network's IPv4 gateway (the Mac's side) is the string at `[0].status.ipv4Gateway`. `run.sh` reads the `default` network's to resolve `gateway` in `model_url`; a missing or non-IPv4 value is refused. | `lib/inspect.sh: pi_network_gateway_from_json` | `network/host-only.json` (observed), `network/nat.json` (hand-built) |
| `container image inspect <name>` is an array. The image config is at `[0].variants[0].config.config`: `Env` and `Labels`. History is at `[0].variants[0].config.history[].created_by`. Precedence is Env, label, history. With no version, the parser returns empty and `ensure_settings` uses the Dockerfile ARG. | `lib/inspect.sh: pi_image_version_from_json` | `image/inspect.json`, `image/env-version.json`, `image/label-version.json`, `image/history-version.json`, `image/no-version.json` |
| Image capabilities are the `PI_CONTAINER_CAPABILITIES=<comma-list>` entry in the same `Env` array. An absent value means a legacy image and skips the capability gate. | `lib/inspect.sh: pi_image_capabilities_from_json`; `run.sh: require_image_capability` | `test/test-inspect.sh` inline payloads |
| `container volume inspect <name>` is an array; labels are at `[0].configuration.labels`. Label values are plain on 1.4.1+; older captures may escape slashes as `\/` and jq decodes them. Lookup is by exact key. | `lib/inspect.sh: pi_volume_label_from_json` | `volume/labelled.json`, `volume/escaped-labels.json` |
| `container volume list -q` and `container network list -q` print one name per line. | `run.sh: volume_exists`, `ensure_network`; `clear.sh: all_volumes` | `test/fake-container.sh` |
| `container run` exits non-zero when the container fails. | `run.sh` exec; `clear.sh: save_sessions` | `test/fake-container.sh` (`fail/<key>`) |

## VM runtime

The egress lock (`lib/netlock.sh`) depends on these, observed with
`test/vm-net-diag.sh` on `container` 1.6.1 (2026-11); on 1.7.1 (kernel
6.18.56) `test/migrate-check.sh` shows iptables-legacy and ip6tables-legacy
still load. `test/test-netlock.sh` covers the script; `run.sh check` and `test/fleet-isolation.sh` check the
result in a real VM.

| Assumption | Code |
| --- | --- |
| `container run` accepts `--cap-add NET_ADMIN`; the default bounding set (`a80425fb`) has `SETPCAP` but not `NET_ADMIN`. | `run.sh` |
| The VM kernel has `ip_tables` (legacy iptables) and no `nf_conntrack`, so the rules are stateless OUTPUT rules. | `lib/netlock.sh` |
| The container runs as root, so dropping a capability from the bounding set removes it from every program it starts. | `lib/netlock.sh` |

## Why these are centralised

The parsers live in `lib/inspect.sh`; each path is covered by a fixture or an
inline payload in `test/test-inspect.sh`. A shape change fails a unit test, and
`run.sh` only decides what to do: distinguish an absent proxy from an unknown
one, report a network verdict, refuse a subnet mismatch, or refuse an image that
lacks a required capability.

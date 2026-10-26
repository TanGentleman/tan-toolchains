# Assumptions about external output

`run.sh` and `clear.sh` read Apple's `container` CLI. `lib/inspect.sh` parses
only the paths below with `jq`, observed against `container` 1.6.1 (`macOS 26`,
2026-10). A different shape yields no value or an `unverified` network verdict.
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
| `container image inspect <name>` is an array. The image config is at `[0].variants[0].config.config`: `Env` and `Labels`. History is at `[0].variants[0].config.history[].created_by`. Precedence is Env, label, history. With no version, the parser returns empty and `ensure_settings` uses the Dockerfile ARG. | `lib/inspect.sh: pi_image_version_from_json` | `image/inspect.json`, `image/env-version.json`, `image/label-version.json`, `image/history-version.json`, `image/no-version.json` |
| `container volume inspect <name>` is an array; labels are at `[0].configuration.labels`. Label values are plain on 1.4.1+; older captures may escape slashes as `\/` and jq decodes them. Lookup is by exact key. | `lib/inspect.sh: pi_volume_label_from_json` | `volume/labelled.json`, `volume/escaped-labels.json` |
| `container volume list -q` and `container network list -q` print one name per line. | `run.sh: volume_exists`, `ensure_network`; `clear.sh: all_volumes` | `test/fake-container.sh` |
| `container run` exits non-zero when the container fails. | `run.sh` exec; `clear.sh: save_sessions` | `test/fake-container.sh` (`fail/<key>`) |

## Why these are centralised

The parsers live in `lib/inspect.sh` and each path has a fixture. A shape change
fails a unit test, and `run.sh` only decides what to do: distinguish an absent
proxy from an unknown one, report a network verdict, or refuse a subnet
mismatch.

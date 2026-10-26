# Assumptions about external output

`run.sh` and `clear.sh` read output from Apple's `container` CLI. Every shape
they depend on is listed here, with the code that consumes it and the fixture
that pins it. A change in Apple's output should fail a test in
`test/test-inspect.sh` or `test/test-integration.sh` before it fails a real run.

Refresh the primary fixtures on a Mac with `./test/record-fixtures.sh`.
Fixtures are synthetic until you do; see
`test/fixtures/container/README.md`. Alternate shapes (NAT/bridge networks,
label/history image versions, stopped/paused proxy states, and the escaped-slash
network) stay synthetic because a live CLI may not emit them on demand. Unit
tests assert exact values inline and treat fixtures as shape smoke tests, so
re-recording does not rewrite expectations.

| Assumption | Code | Fixture |
| --- | --- | --- |
| `container inspect` may nest state at `status.state` or expose a top-level `status`/`state` string; values are `running`, `stopped`, `stopping`, `exited`, `created`, `paused`, `unknown` | `lib/inspect.sh: pi_proxy_state_from_json` | `inspect/proxy-running.json`, `inspect/proxy-stopped.json`, `inspect/proxy-paused.json` |
| `container network inspect` reports an internal network as `internal: true`, as `mode: hostOnly`/`host-only`, or both; `internal: false` means NAT | `lib/inspect.sh: pi_network_host_only_verdict` | `network/host-only.json`, `network/internal-true.json`, `network/nat.json`, `network/mode-bridge.json`, `network/no-mode.json` |
| Network inspect may escape slashes as `\/` (so `172.30.240.0/24` appears as `172.30.240.0\/24`); plain `grep -F` misses it | `lib/inspect.sh: pi_json_unescape_slashes`, `pi_network_has_subnet` | `network/host-only-escaped.json` |
| `container image inspect` may expose the build version as config `Env` (`PI_CONTAINER_PI_VERSION=…`), as an image label (`pi-container.pi-version`), or only in build history (`RUN … PI_VERSION=…`); precedence is Env, label, history | `lib/inspect.sh: pi_image_version_from_json` | `image/env-version.json`, `image/label-version.json`, `image/history-version.json`, `image/no-version.json` |
| `container volume inspect` exposes labels; label values may escape slashes as `\/` | `lib/inspect.sh: pi_volume_label_from_json` | `volume/labelled.json`, `volume/escaped-labels.json` |
| `container volume list -q`, `container network list -q` print one name per line | `run.sh: volume_exists`, `ensure_network`; `clear.sh: all_volumes` | exercised by `test/fake-container.sh` |
| `container run` exits non-zero when the container fails | `run.sh` exec; `clear.sh: save_sessions` | `test/fake-container.sh` (`fail/<key>`) |

## Why these are centralised

The two bugs that prompted this file were both in this table:

- `run.sh` grepped the locked subnet without unescaping `\/`, so a network that
  was correct looked wrong. Fixed by `pi_json_unescape_slashes`.
- `run.sh` assumed host-only networks always set `internal: true`. Apple
  reports `mode: hostOnly` instead. Fixed by `pi_network_host_only_verdict`.

Keeping the parsing in `lib/inspect.sh` and the shapes in fixtures means the
next such change fails a unit test instead of a user's `pic` command.

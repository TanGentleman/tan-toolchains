# `container` output fixtures

Every JSON file here models a payload from Apple's `container` CLI that
`pi-container/lib/inspect.sh` parses. A test fails when the parser and a fixture
disagree, so a shape change shows up in CI instead of during a run.

## Provenance

The files committed today are **synthetic**: they reproduce the key names and
escaping that the code was written against, but they were not captured from a
live runtime. Refresh the primary captures on a Mac:

```bash
cd pi-container
./test/record-fixtures.sh          # writes this directory
git diff test/fixtures/container   # review what the CLI actually emits
```

`record-fixtures.sh` also rewrites `provenance.txt` with the date, the CLI
version, and the commands it ran. Run it after upgrading Apple `container`, and
after any change to the Dockerfile that alters image metadata.

The recorder refreshes the primary captures (`network/host-only.json`,
`image/env-version.json`, `inspect/proxy-running.json`,
`volume/labelled.json`). It deliberately leaves the alternate-shape fixtures
(synthetic): the NAT/bridge/no-mode networks, the label/history image variants,
the stopped/paused proxy states, and `network/host-only-escaped.json`. Those
exist to pin parser branches that a live CLI may not produce on demand. Tests
assert exact values inline and use the fixtures as shape smoke tests, so
re-recording cannot rewrite expectations.

## Layout

| Fixture | Command that produces it | Pins |
| --- | --- | --- |
| `network/host-only.json` | `container network inspect <pi-locked>` | `internal: true` + `mode: hostOnly` |
| `network/host-only-escaped.json` | hand-built (not refreshed) | slashes escaped as `\/` in the subnet |
| `network/internal-true.json` | same, older CLI | `internal: true`, no `mode` |
| `network/nat.json` | `container network inspect <a non-internal network>` | `internal: false`, `mode: nat` |
| `network/mode-bridge.json` | same | a mode that is not host-only |
| `network/no-mode.json` | same | neither marker present |
| `image/env-version.json` | `container image inspect pi-agent:local` | version in `configuration.env` |
| `image/label-version.json` | same, image with labels | version in a `pi-container.pi-version` label |
| `image/history-version.json` | same, old image | version only in build history |
| `image/no-version.json` | same | no version anywhere |
| `volume/labelled.json` | `container volume inspect <pi-agent-…>` | `pi.*` labels |
| `volume/escaped-labels.json` | same, raw | `\/` inside label values |
| `inspect/proxy-running.json` | `container inspect <pi-proxy>` | nested `status.state` |
| `inspect/proxy-stopped.json` | same | top-level `status` string |
| `inspect/proxy-paused.json` | same | an unrecognised state |

`test/fake-container.sh` also serves these payloads to `run.sh` and `clear.sh`
during integration tests, so the orchestration code is exercised without Apple
`container`.

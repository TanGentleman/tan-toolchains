# `container` output fixtures

Every JSON file here models a payload from Apple's `container` CLI that
`pi-container/lib/inspect.sh` parses. A test fails when the parser and a fixture
disagree, so a shape change shows up in CI instead of during a run.

The committed fixtures use the observed `macOS 26` shapes: arrays, proxy state
at `[0].status.state`, network subnets at `[0].configuration.ipv4Subnet` /
`[0].status.ipv4Subnet`, image config at `[0].variants[0].config.config`, and
volume labels at `[0].configuration.labels`.

## Provenance

Some files are still synthetic because a live CLI does not emit every variant on
demand. Refresh the primary captures on a Mac:

```bash
cd pi-container
./test/record-fixtures.sh          # writes this directory safely
git diff test/fixtures/container   # review what the CLI actually emits
```

`record-fixtures.sh` writes each capture to a temporary file and replaces a
fixture only after the output parses as JSON. A failed capture leaves the old
fixture in place and reports `kept`; it also rewrites `provenance.txt` with the
date, CLI version, and commands it ran. Run it after upgrading Apple
`container`, and after any change to the Dockerfile that alters image metadata.

The recorder refreshes `network/host-only.json`, `image/inspect.json`,
`inspect/proxy-running.json`, and `volume/labelled.json`. It deliberately leaves
the alternate-shape fixtures synthetic: the NAT/bridge/no-mode networks, the
env/label/history image variants, the stopped/paused proxy states, and
`network/host-only-escaped.json`. Those exist to pin parser branches that a
live CLI may not produce on demand. Tests assert exact values inline and use the
fixtures as shape smoke tests, so re-recording cannot rewrite expectations.

## Layout

| Fixture | Command that produces it | Pins |
| --- | --- | --- |
| `network/host-only.json` | `container network inspect <pi-locked>` | observed `mode: hostOnly`, `ipv4Subnet` in configuration and status |
| `network/host-only-escaped.json` | hand-built (not refreshed) | slashes escaped as `\/` in the subnet |
| `network/internal-true.json` | synthetic older shape | `internal: true`, no `mode` |
| `network/nat.json` | synthetic non-internal network | `internal: false` |
| `network/mode-bridge.json` | synthetic non-host-only network | a mode that is not host-only |
| `network/no-mode.json` | synthetic | neither marker present |
| `image/inspect.json` | `container image inspect pi-agent:local` | the observed raw image shape (`variants[0].config.config`) |
| `image/env-version.json` | synthetic branch | version in `variants[0].config.config.Env` |
| `image/label-version.json` | synthetic branch | version in `variants[0].config.config.Labels` |
| `image/history-version.json` | synthetic branch | version only in `variants[0].config.history[].created_by` |
| `image/no-version.json` | synthetic branch | no version anywhere |
| `volume/labelled.json` | `container volume inspect <pi-agent-…>` | `pi.*` labels at `configuration.labels` |
| `volume/escaped-labels.json` | synthetic raw shape | `\/` inside label values |
| `inspect/proxy-running.json` | `container inspect <pi-proxy>` | observed `status.state: running` |
| `inspect/proxy-stopped.json` | synthetic | `status.state: stopped` |
| `inspect/proxy-paused.json` | synthetic | `status.state: paused` |

`test/fake-container.sh` serves payloads from a test world directory to
`run.sh` and `clear.sh` during integration tests, so orchestration is exercised
without Apple `container`. Integration tests generate their payloads inline so
re-recording fixtures cannot rewrite their expectations.

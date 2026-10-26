# `container` output fixtures

Every JSON file here models a payload from Apple's `container` CLI that
`pi-container/lib/inspect.sh` parses. A test fails when the parser and a fixture
disagree, so a shape change shows up in CI instead of during a run.

The recorded fixtures use the observed `container` 1.6.1 (`macOS 26`) shapes:
arrays, proxy state at `[0].status.state`, network subnets at
`[0].configuration.ipv4Subnet` / `[0].status.ipv4Subnet`, image config at
`[0].variants[0].config.config`, and volume labels at
`[0].configuration.labels`.

Since `container` 1.4.1, JSON output does not escape forward slashes. The
hand-built escaped fixtures keep older captures covered because the parsers use
`jq`, which decodes both forms.

## Provenance

Refresh the recorded captures on a Mac:

```bash
cd pi-container
./test/record-fixtures.sh          # writes this directory safely
git diff test/fixtures/container   # review what the CLI actually emits
```

`record-fixtures.sh` writes each capture to a temporary file and replaces a
fixture only after the output parses as JSON. A failed capture leaves the old
fixture in place and reports `kept`; it also rewrites `provenance.txt` with the
date, CLI version, and commands it ran. After capturing, it checks that the
paths the parsers use are still present and exits non-zero on a changed shape.
Run it after upgrading Apple `container`, then run `./test/run-tests.sh` and
review the diff.

The recorder refreshes `network/host-only.json`, `image/inspect.json`,
`inspect/proxy-running.json`, and `volume/labelled.json`. The other files are
hand-built to pin values and branches the recorder does not produce on demand.
Tests assert exact values inline and use the fixtures as shape smoke tests, so
re-recording cannot rewrite expectations.

## Layout

| Fixture | Command that produces it | Pins |
| --- | --- | --- |
| `network/host-only.json` | `container network inspect <pi-locked>` | observed `mode: hostOnly`, `ipv4Subnet` in configuration and status |
| `network/host-only-escaped.json` | hand-built | older capture with slashes escaped as `\/` in the subnet |
| `network/nat.json` | hand-built | a non-host-only `mode` |
| `network/no-mode.json` | hand-built | no `mode` |
| `image/inspect.json` | `container image inspect pi-agent:local` | the observed raw image shape (`variants[0].config.config`) |
| `image/env-version.json` | hand-built | version in `variants[0].config.config.Env` |
| `image/label-version.json` | hand-built | version in `variants[0].config.config.Labels` |
| `image/history-version.json` | hand-built | version only in `variants[0].config.history[].created_by` |
| `image/no-version.json` | hand-built | no version anywhere |
| `volume/labelled.json` | `container volume inspect <pi-agent-…>` | `pi.*` labels at `configuration.labels` |
| `volume/escaped-labels.json` | hand-built | older capture with `\/` inside label values |
| `inspect/proxy-running.json` | `container inspect <pi-proxy>` | observed `status.state: running` |
| `inspect/proxy-stopped.json` | hand-built | `status.state: stopped` |
| `inspect/proxy-paused.json` | hand-built | `status.state: paused` |

`test/fake-container.sh` serves payloads from a test world directory to
`run.sh` and `clear.sh` during integration tests, so orchestration is exercised
without Apple `container`. Integration tests generate their payloads inline so
re-recording fixtures cannot rewrite their expectations.

# Assumptions about external output

`run.sh` and `clear.sh` read output from Apple's `container` CLI. The parsers
in `lib/inspect.sh` use `jq` and target the paths below. Every observed shape is
listed with the code that consumes it and the fixture that pins it. A change in
Apple's output should fail a test in `test/test-inspect.sh` or
`test/test-integration.sh` before it fails a real run.

**Confidence:** high for the observed (`macOS 26`, 2026-10) paths below. The
legacy/alternate fallbacks are medium confidence: they are kept for older
captures and other runtimes, and the synthetic fixtures pin them. `jq` is a hard
dependency for the parsing paths (`run.sh` normal/check/proxy and `clear.sh`
list/nuke); they fail early with an install hint when it is missing.

Refresh the primary captures on a Mac with `./test/record-fixtures.sh`. It
writes to a temporary file and only replaces a fixture after the output parses
as JSON; a failed capture leaves the old fixture in place. See
`test/fixtures/container/README.md`.

| Assumption | Code | Fixture |
| --- | --- | --- |
| `container inspect <name>` is an array; state is at `[0].status.state`. Values are `running`, `stopped`, `stopping`, `exited`, `created`, `paused`, `unknown`. The parser also accepts a top-level `status` string or `state` for older captures, with nested `status.state` taking precedence. | `lib/inspect.sh: pi_proxy_state_from_json` | `inspect/proxy-running.json`, `inspect/proxy-stopped.json`, `inspect/proxy-paused.json` |
| A missing `container inspect` is `absent`; an existing container with no recognised state is `unknown` and is recreated. They are not the same. | `run.sh: proxy_state`, `ensure_proxy` | exercised by `test/test-integration.sh` |
| `container network inspect <name>` is an array. Observed host-only fields are `[0].configuration.mode` (`hostOnly`) and `[0].configuration.ipv4Subnet` / `[0].status.ipv4Subnet`. Older captures may use `configuration.internal` and `configuration.subnet`; those remain fallbacks. `internal: false` wins, then a non-host-only mode, then positive markers. | `lib/inspect.sh: pi_network_host_only_verdict` | `network/host-only.json`, `network/internal-true.json`, `network/nat.json`, `network/mode-bridge.json`, `network/no-mode.json` |
| Network subnets must be read from the subnet fields, not from arbitrary text. If both the configured and active subnet are present, both must match `PI_LOCKED_SUBNET`. jq decodes JSON `\/`, so `172.30.240.0\/24` works without a textual unescape pass. | `lib/inspect.sh: pi_network_has_subnet` | `network/host-only.json`, `network/host-only-escaped.json` |
| `container image inspect <name>` is an array. The real image config is at `[0].variants[0].config.config`: `Env` and `Labels`. Build history is at `[0].variants[0].config.history[].created_by`. Top-level `configuration.env` / `configuration.labels` are legacy fallbacks. Precedence is Env, label, history. A current image may have no version recorded, in which case the parser returns empty and `ensure_settings` falls back to the Dockerfile ARG. | `lib/inspect.sh: pi_image_version_from_json` | `image/inspect.json`, `image/env-version.json`, `image/label-version.json`, `image/history-version.json`, `image/no-version.json` |
| `container volume inspect <name>` is an array; labels are at `[0].configuration.labels`. Label values may escape slashes as `\/`; jq decodes them. Lookup is by exact key, not a regex. | `lib/inspect.sh: pi_volume_label_from_json` | `volume/labelled.json`, `volume/escaped-labels.json` |
| `container volume list -q`, `container network list -q` print one name per line | `run.sh: volume_exists`, `ensure_network`; `clear.sh: all_volumes` | exercised by `test/fake-container.sh` |
| `container run` exits non-zero when the container fails | `run.sh` exec; `clear.sh: save_sessions` | `test/fake-container.sh` (`fail/<key>`) |

## Why these are centralised

The two bugs that prompted this file were both in this table:

- `run.sh` grepped the locked subnet without decoding `\/`, so a network that
  was correct looked wrong. jq now decodes JSON escapes and the subnet check
  reads `configuration.ipv4Subnet` / `status.ipv4Subnet`.
- `run.sh` assumed host-only networks always set `internal: true`. Apple
  reports `mode: hostOnly` instead. `pi_network_host_only_verdict` now reads the
  configuration mode and keeps the `internal` fallback.

Keeping the parsing in `lib/inspect.sh` and the shapes in fixtures means the
next such change fails a unit test instead of a user's `pic` command.

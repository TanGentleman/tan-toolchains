# Local scripts

Utilities for working on this repo from a developer machine. These are not
shipped, baked into the container image, or part of the test suite.

## `container-discovery.sh`

Captures the real output shapes of Apple's `container` CLI for `pi-container`
and prints a jq summary plus a contract check for the paths the parsers use. It
writes only to a temporary directory; it does not update
`pi-container/test/fixtures/`.

```bash
container system start
./scripts/container-discovery.sh
```

Requires `jq` and Apple `container`. The script exits early with a clear message
if either is missing.

It captures:

- `network.json` — `container network inspect <pi-locked>`
- `image.json` — `container image inspect pi-agent:local`
- `proxy.json` — `container inspect pi-proxy`
- `volume-agent.json` — a temporary volume with the agent labels
- `volume-clone.json` — a temporary volume with the clone labels and `pi.repo`

Temporary volumes are removed on exit. Missing resources are reported as
`skipped`; the script is still useful when only some resources exist. Each
summary heading also reports whether the raw capture escapes `/` as `\/`;
`container` 1.4.1 and later emit plain slashes. A `contract ... MISMATCH` line
means the CLI moved a field the parsers depend on.

### States to distinguish

| State | Symptom | Next step |
| --- | --- | --- |
| Runtime not started | Every inspect fails; the error text may mention the CLI, not the system | `container system start` |
| Runtime up, image missing | Image inspect fails while network inspect may work | Build the image from the repo root context |
| Runtime up, network/proxy missing | Only those captures are skipped | Start a normal run/check to create them |
| Resource exists, unexpected shape | Capture succeeds; a `contract` line says `MISMATCH` | Update the parser contract and its tests |
| Proxy exists but is stopped/paused | `proxy.json` capture may show a non-running state | Optionally capture again while running |

Do not copy captures containing host paths or secrets into the repo without
reviewing them first.

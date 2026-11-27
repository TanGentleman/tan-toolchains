# Testing

Run commands from `pi-container/`.

CI runs the whole suite without Apple `container` or a network. It requires
`jq`, which macOS 26 ships as `/usr/bin/jq` (on Linux, `apt-get install jq`):

```bash
./test/run-tests.sh
```

It covers naming and validation, the image pack catalog, the mount guard's path
algebra, the JSON parsers in `lib/inspect.sh`, and the orchestration in
`run.sh`/`clear.sh` driven against `test/fake-container.sh`. The fake CLI serves
inspect payloads and captures the exact `container` argv the scripts build.
`test-proxy.sh` runs `test/test_proxy.py`, unit tests for `proxy.py`'s routes
in normal and offline egress (needs `python3` 3.9 or newer).

Separate CI jobs run `enforcer` unit/CLI tests and a headless Pi integration
test against the Pi version in `pi-container/Dockerfile`. The integration test
proves `enforcer on` makes a real `pi -p` prompt hit the hook before the model.
`run.sh check`, the image build, and the E2E checklist still need a Mac; the
integration job does not replace them. The suite does not build Dockerfile
targets; each pack is built and checked by `./build.sh PACK` on a Mac.

The output shapes the scripts assume are listed in
[ASSUMPTIONS.md](../ASSUMPTIONS.md) and pinned by files under
[`test/fixtures/container/`](../test/fixtures/container/). On a Mac, refresh the
recorded captures from the real CLI. The recorder checks the expected paths
after capturing and reports `SHAPE CHANGED` if Apple moved one:

```bash
./test/record-fixtures.sh
git diff test/fixtures/container   # a changed shape is what the tests catch
```

The recorder checks every path the parsers use and reports `shape ok` or
`SHAPE CHANGED`, so a capture that moves a field fails loudly instead of being
committed. It writes a fixture only after the capture parses as JSON, and
leaves an existing fixture untouched when a capture fails. Since `container`
1.4.1, captures use plain slashes; older escaped fixtures still pin that form.

That replace-in-place is the only capture path. To explore a new CLI version
without touching the repo, copy `test/fixtures/container/` aside first, or run
the recorder and revert with `git checkout -- test/fixtures/container`.

`run.sh check`, real volume creation, and the Neovim/ZLS paths still need the
[E2E checklist](../E2E.md) on macOS; Apple `container` is not available in CI.

`pic serve`, `pi-ctr` and `run.sh --fleet-state` are covered by
`test-serve.sh` and `test-integration.sh`, and end to end by
`fleet/e2e/pi-ctr.sh`: real `fleetd`, `run.sh` and `pi-ctr` against the fake
container. The fleet CI job runs that and fleet's Go tests, including real Pi
behind `proxy.py`; `./build.sh fleet` runs the Go tests again on the Mac.

`test/fleet-isolation.sh SID` needs a Mac running `pic serve`. From a turn's
VM it probes `fleetd`, the Mac, the tailnet and the internet by IP, using
`test/fleet-probe.sh`, which `test-fleet-probe.sh` tests here. Where each fleet
check runs: [fleet/docs/macos.md, step 8](../../fleet/docs/macos.md#8-verify-before-relying-on-it).

`test/fleet-e2e.sh REPO` is step 8's scripted part: real turns on REPO
through the tailnet URL, checked with git. `fleet/e2e/pi-ctr.sh` runs it in
CI against a fake Pi and a local bare repo.

A release follows [E2E.md, Release](../E2E.md#release): `mac-e2e.sh`,
`fleet-e2e.sh` and the by-hand checks on the main account, `mac-e2e.sh` again
in a new standard account made with `sysadminctl`, then a tag.

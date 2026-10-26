# Testing

Run commands from `pi-container/`.

CI runs the whole suite without Apple `container` or a network. It requires
`jq`:

```bash
brew install jq   # or your package manager
./test/run-tests.sh
```

It covers naming and validation, the mount guard's path algebra, the JSON
parsers in `lib/inspect.sh`, and the orchestration in `run.sh`/`clear.sh`
driven against `test/fake-container.sh`. The fake CLI serves inspect payloads
and captures the exact `container` argv the scripts build.

The output shapes the scripts assume are listed in
[ASSUMPTIONS.md](../ASSUMPTIONS.md) and pinned by files under
[`test/fixtures/container/`](../test/fixtures/container/). On a Mac, refresh the
recorded captures from the real CLI:

```bash
./test/record-fixtures.sh
# or, for a non-destructive discovery run:
../scripts/container-discovery.sh
git diff test/fixtures/container   # a changed shape is what the tests catch
```

`run.sh check`, real volume creation, and the Neovim/ZLS paths still need the
[E2E checklist](../E2E.md) on macOS; Apple `container` is not available in CI.

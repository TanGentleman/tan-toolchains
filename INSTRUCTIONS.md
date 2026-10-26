# Container upgrade instructions

Use this after upgrading Apple `container`. It was written for the 1.2.0 to
1.6.1 upgrade. The JSON paths `pi-container` parses did not change; these steps
confirm that on your Mac.

Run the commands from this repo on macOS unless a step says otherwise.

## 1. Sync and start the runtime

```bash
git switch container-bootstrap-3
git pull --ff-only
container --version          # expect 1.6.1
container system start
cd pi-container
```

## 2. Create the resources the checks inspect

```bash
container build -t pi-agent:local -f Dockerfile ..
./run.sh check OWNER/REPO
```

`run.sh check` creates the profile's `pi-locked` network and starts `pi-proxy`.
Use a disposable repo and token if you are testing the full path.

## 3. Check the live JSON contract

```bash
../scripts/container-discovery.sh
```

The script writes captures to a temporary directory and prints a jq summary.
Pass means:

- the final `cli:` line starts with `container version 1.6.1`
- every `contract ...` line says `ok`
- summary headings say `plain slashes`

If a capture says `skipped`, fix the resource and run it again. A missing proxy
means `run.sh check` did not get far enough. If a `contract` line says
`MISMATCH`, stop: Apple moved a field the parsers use. Update
`lib/inspect.sh`, the fixtures, and the tests in the same change.

## 4. Refresh the committed fixtures

```bash
./test/record-fixtures.sh
git diff test/fixtures/container
```

The recorder prints `shape ok` for each expected path and exits non-zero on
`SHAPE CHANGED`.

An expected diff from 1.2.0 captures is plain `/` replacing `\/` in the recorded
JSON. `image/inspect.json` may grow because it now contains the real image build
history. Leave the hand-built `*-escaped.json` fixtures unchanged; they keep
older captures covered.

Review the diff for host paths or secrets before committing it.

## 5. Run the offline suite

```bash
./test/run-tests.sh
```

This must pass. It does not need Apple `container`.

## 6. Run the macOS checklist

Complete [pi-container/E2E.md](pi-container/E2E.md) before merging or tagging.
At minimum, run `./run.sh check owner/repo` again and start Pi once with
`./run.sh`.

## Troubleshooting

- `container build` is an unknown command: reinstall the 1.6.1 package so its
  `build` and `builder` plugins are present.
- Every inspect fails: run `container system start`.
- Image inspect fails: build `pi-agent:local` from the repo root context.
- Proxy capture is skipped or paused: start it with `./run.sh proxy` or a
  normal `./run.sh`, then rerun discovery.
- `SHAPE CHANGED` or `MISMATCH`: do not hand-edit a recorded fixture. Update the
  parser contract and its tests together.

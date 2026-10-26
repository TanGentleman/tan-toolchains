# AGENTS.md

Read `README.md`, `pi-container/README.md`, `pi-container/ASSUMPTIONS.md`,
`pi-container/UPGRADES.md`, and `pi-container/E2E.md` before changing behavior.

## Scope

- `zigpeek/`: pure-Zig reader for Zig stdlib and `@`-builtin docs. No network,
  no bundled docs; it reads the installed compiler's `lib/` and `doc/`.
- `pi-container/`: bash driver, Dockerfiles, and proxy that run Pi in an Apple
  `container` VM.

The current development line is `container-bootstrap-3`; `main` is stable. Do
not merge or tag before `pi-container/E2E.md` passes on macOS.

## Commands

```sh
cd pi-container && ./test/run-tests.sh   # jq required; no container or network
cd zigpeek && zig build test
cd zigpeek && zig build --release=small

for f in pi-container/*.sh pi-container/lib/*.sh pi-container/test/*.sh scripts/*.sh; do
  bash -n "$f"
done
python3 -m py_compile pi-container/proxy.py
```

The image build context is the repo root because the image compiles
`../zigpeek`:

```sh
cd pi-container
container build -t pi-agent:local -f Dockerfile ..
./run.sh check owner/repo
```

If the environment has no Apple `container`, run the CI checks and say
explicitly that `run.sh check` and the E2E checklist were not run.

## Hard boundaries

- Shipped tools make no network requests. A separate process owns any network
  layer; do not add network code to a shipped binary.
- In normal Pi mode, `pi-proxy` is the only route out. It tunnels GitHub and
  MITMs OpenRouter to add the key; everything else is refused.
- `--manual` uses the container's default network and is not sandboxed by
  `pi-locked`. Do not describe it as if it were.
- The image is aarch64-only. Either add tested multi-arch handling or keep the
  explicit guard.

## `container` JSON contract

- Capture real shapes on a Mac with `scripts/container-discovery.sh` or refresh
  fixtures with `pi-container/test/record-fixtures.sh`.
- Parse the observed JSON paths with `jq` in `pi-container/lib/inspect.sh`. Do
  not add whole-document `grep`/`sed`/`awk` extraction or accept unobserved
  shapes. A new shape needs a fixture and a test.
- Update `ASSUMPTIONS.md`, fixture docs, `test/test-inspect.sh`, and, for
  orchestration changes, `test/test-integration.sh` in the same commit.
- An absent source is not an existing source with an unknown state. An absent
  proxy may be created; an unknown-state proxy must be recreated, not reused.
- `jq` is a hard dependency on parsing paths. Fail early with an install hint;
  do not add another parser.
- Recorded fixtures are recorder-owned. Do not hand-edit a capture to pass a
  test; keep expectations inline so re-recording cannot rewrite them.

## Security invariants

- The host env file stays mode 600 or 400. Filter it into `private/proxy.env`
  (OpenRouter key only) and `pi.env` (GitHub token and commit identity). The
  real OpenRouter key never enters the agent environment, argv, or logs.
- Pi gets `sk-or-v1-placeholder`; the proxy adds the real key.
- `settings.json` is mounted read-only so Pi cannot persist settings or installs.
- The mount guard fails closed: refuse `/`, `$HOME`, ancestors of `$HOME`,
  secrets directories, and anything overlapping config, env, or settings paths.
- Volumes carry `pi.*` labels. Scope deletion by profile, instance, kind, and
  `pi.managed`; never delete unlabelled or unmanaged volumes implicitly.
- `run.sh` and `clear.sh` share `lib/lock.sh` because images, networks, and the
  builder cache are machine-wide.
- Backups contain only regular `*.jsonl` files. Do not extract symlinks, device
  nodes, or unrelated volume contents.
- When a security check cannot be verified, refuse rather than assume safe.

## Version pins

Move these together:

- `pi-container/Dockerfile`: base image digest, `PI_VERSION`, `ZIG_VERSION`,
  `NVIM_VERSION` + `NVIM_SHA256`, `ZLS_VERSION` + `ZLS_SHA256`.
- `.github/workflows/test.yml`: `ZIG_VERSION`.
- `zigpeek/build.zig.zon`: `minimum_zig_version` and `version`.
- `zigpeek/src/version.zig`: `version`.

`ZLS_VERSION` must equal `ZIG_VERSION`; a mismatch silently mis-parses projects.
Verify downloads by publisher signature (Zig/minisign) or publisher checksum
(Neovim/ZLS).

## Testing rules

- Add a test for every behavior change. Pure logic goes in `lib/` with a unit
  test; orchestration gets a fake-CLI integration case.
- Integration tests must be hermetic: temporary `HOME`, all inherited `PI_*`
  unset, and no dependence on the developer's profile or running containers.
- Use `test/lib.sh` assertions and `test/fake-container.sh`. Make unknown fake
  commands fail so coverage cannot silently disappear.
- Test refusals, missing dependencies, malformed state, and option guards.
- Keep tests runnable with macOS `/bin/bash` 3.2 and Linux CI bash.

## Style

- `run.sh` and `clear.sh` are CLIs: `set -euo pipefail`, quote expansions, use
  `local`, and keep user-facing messages in the calling script.
- `lib/*.sh` and `test/lib.sh` are sourced, never executed. They must not set
  shell options or call `exit`; return a status and let the caller decide.
- Keep parsing in `lib/inspect.sh`, naming in `names.sh`, validation in
  `lib/validate.sh`, and path/security logic in `lib/paths.sh`.
- Zig targets the pinned version and uses the standard library only. Keep
  command parsing in `cli.zig`, indexing in `stdlib.zig`, builtins in
  `builtins.zig`, and rendering in `info.zig`/`get.zig`. Run `zig fmt`.
- Docs must be concise and literal: no slogans, stale metrics, or repeated
  claims. Root `README.md` owns the network boundary; `UPGRADES.md` holds open
  work only; `modal-scratchpad.md` is speculative.
- Update docs in the same commit as behavior changes and delete stale text
  instead of appending corrections.
- Prefer a clear helper over duplicated blocks, but do not churn working code
  for cosmetic DRY. Record non-blocking gaps in `UPGRADES.md`.

## Commits and review

- Do not commit or push unless asked. When asked to review, report findings
  first rather than mixing review with edits.
- Use `scope: lowercase imperative summary`, then a body explaining why, the
  invariant, and test coverage. Keep one concern per commit.
- Run the relevant checks and inspect `git diff` before committing. Never commit
  `.zig-cache/`, `zig-out/`, captures, secrets, or generated binaries.
- If a check needs a Mac, put the helper in `scripts/`, ask the user to run the
  exact command, and end the turn. Do not fake the result.

# AGENTS.md

Read `README.md`, `pi-container/README.md` and the docs under
`pi-container/docs/`, plus `pi-container/ASSUMPTIONS.md`,
`pi-container/UPGRADES.md`, and `pi-container/E2E.md` before changing behavior.

## Scope

- `zigpeek/`: pure-Zig reader for Zig stdlib and `@`-builtin docs. No network,
  no bundled docs; it reads the installed compiler's `lib/` and `doc/`.
- `enforcer/`: pure-Zig Pi prompt hook. Pi is the only supported agent; Claude
  is detection-only and points at the upstream project.
- `pi-container/`: bash driver, Dockerfiles, and proxy that run Pi in an Apple
  `container` VM.
- `fleet/`: Go daemon (`fleetd`, standard library only) that runs Pi
  sessions on one Mac, one `pi-ctr` turn at a time in pi-container's VM, for
  owners on the tailnet. Protocol rules live in `fleet/core` as pure
  functions; read `fleet/README.md` first.

Do not merge or tag before `pi-container/E2E.md` (through its Release
section) and `fleet/docs/macos.md` step 8 pass on macOS.

## Paths

- Docs write the checkout as `$T` (`T=~/path/to/tan-toolchains`) and the
  local-model spike as `$S`, never a real home or checkout path.
- Messages and generated files (`overrides.env`) show paths below the home
  folder as `$HOME/...`: pass them through `pi_show` in `lib/paths.sh`.

## Commands

```sh
cd pi-container && ./test/run-tests.sh   # jq required; no container or network
cd zigpeek && zig build test
cd zigpeek && zig build --release=small
cd enforcer && zig build check
cd enforcer && zig build --release=small
cd enforcer && bash test/pi-integration.sh ./zig-out/bin/enforcer  # pi required

for f in pi-container/*.sh pi-container/lib/*.sh pi-container/test/*.sh enforcer/test/*.sh fleet/e2e/*.sh; do
  bash -n "$f"
done
python3 -m py_compile pi-container/proxy.py

cd fleet && test -z "$(gofmt -l .)" && go vet ./... && go test -race ./...
cd fleet && bash e2e/pi-ctr.sh  # git, jq, curl; no container
```

The image build context is the repo root because the images (all but
`min`) compile `../enforcer` and, for the Zig packs, `../zigpeek`:

```sh
cd pi-container
./build.sh full             # pi-full:local: Pi, gh, enforcer; no Zig (the default image)
./build.sh min              # pi-min:local: Pi; no gh, enforcer or Zig stage
./build.sh zig              # pi-zig:local: full + Zig, zigpeek, Neovim, ZLS
./run.sh images             # every pack, its tag, and whether it is built
./run.sh check owner/repo
```

If the environment has no Apple `container`, run the CI checks and say
explicitly that `run.sh check` and the E2E checklist were not run.

## Hard boundaries

- The root README's Setup table is the complete list of what the Mac needs.
  A new host tool goes in that table first, with what needs it; no
  Homebrew-only install steps, since the `.pkg` and macOS's own tools work in
  every account.

- Shipped tools make no network requests. A separate process owns any network
  layer; do not add network code to a shipped binary. `fleetd` is such a
  process: it listens on loopback only, behind `tailscale serve`, and dials
  nothing; its turns reach the network only through `pi-proxy`.
- `fleetd` runs only `pi-ctr`: Pi in pi-container's normal mode. Do not add
  harnesses that run an agent on the host. `go test ./agent` runs real Pi
  behind the real `proxy.py` and fails on any traffic but model calls. Live
  check, never in CI:
  `FLEET_LIVE=1 OPENROUTER_API_KEY=... go test -run TestLive ./agent`.
- `fleet/core` stays pure (no I/O, clock, or randomness) and dependency-free;
  any protocol change lands there with a simulation or rules test.
- In normal Pi mode, `pi-proxy` is the only route out. It tunnels GitHub and
  MITMs OpenRouter to add the key; everything else is refused.
- `--manual` uses the container's default network and is not sandboxed by
  `pi-locked`. Do not describe it as if it were.
- `--allow-egress` runs Pi on the default network and passes the real OpenRouter
  key in `private/egress.env`. It is opt-in and unsandboxed; keep it documented
  that way, and never fold it into normal mode.
- The image is aarch64-only. Either add tested multi-arch handling or keep the
  explicit guard.

## `container` JSON contract

- The observed contract is the `container` version named in
  `pi-container/test/fixtures/container/provenance.txt`. Since 1.4.1, JSON
  output uses plain `/`; older captures may use `\/`. Keep `jq`, which decodes
  both.
- Capture real shapes on a Mac with `pi-container/test/record-fixtures.sh`. It
  replaces a fixture only after the capture parses as JSON and passes
  `test/fixture-scrub.jq` (home, host, env values, tokens, MACs, IPv6 and
  non-container IPv4), and checks the paths the parsers use, so review
  `git diff` and revert an unwanted capture rather than reaching for a second
  tool.
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
  (OpenRouter key only) and `pi.env` (GitHub token and commit identity).
  `private/egress.env` is the `--allow-egress` exception: key plus `pi.env`.
  Outside egress mode, the real key never enters the agent environment, argv,
  or logs.
- In normal Pi mode, Pi gets `sk-or-v1-placeholder`; the proxy adds the real
  key. `--allow-egress` is the documented exception.
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

## Toolchain policy

- No compiler tarballs, wheels, or package caches in Git. Build from source or
  fetch from the publisher.
- Verify downloads by publisher signature (Zig/minisign) or publisher checksum
  (Neovim/ZLS).
- Pin versions explicitly; CI checks the Zig pins, and the image build checks
  the installed tool versions.
- Each tool owns its build and test story: `zig build test` for zigpeek, `zig
  build check` for enforcer plus the headless Pi integration script, CI for the
  source, `run.sh check` for the container.

## Version pins

Move these together:

- `pi-container/Dockerfile`: base image digest, `PI_VERSION`, `ZIG_VERSION`,
  `NVIM_VERSION` + `NVIM_SHA256`, `ZLS_VERSION` + `ZLS_SHA256`.
- `pi-container/build.sh`: `fleet_go_image` (Go image tag and digest for
  `build.sh fleet`), at least `fleet/go.mod`'s `go` version.
- `.github/workflows/test.yml`: `ZIG_VERSION`.
- `zigpeek/build.zig.zon`: `minimum_zig_version` and `version`.
- `zigpeek/src/version.zig`: `version`.
- `enforcer/build.zig.zon`: `minimum_zig_version`.

`ZLS_VERSION` must equal `ZIG_VERSION`; a mismatch silently mis-parses projects.

## Testing rules

- Add a test for every behavior change. Pure logic goes in `lib/` with a unit
  test; orchestration gets a fake-CLI integration case.
- Integration tests must be hermetic: temporary `HOME`, all inherited `PI_*`
  unset, and no dependence on the developer's profile or running containers.
- Use `test/lib.sh` assertions and `test/fake-container.sh`. Make unknown fake
  commands fail so coverage cannot silently disappear.
- Test refusals, missing dependencies, malformed state, and option guards.
- Keep tests runnable with macOS `/bin/bash` 3.2 and Linux CI bash.
  Check 3.2 without a Mac: `docker run --rm -v "$PWD":/w -w /w/pi-container
  bash:3.2 sh -c 'apk add -q jq git python3; ln -sf /usr/local/bin/bash
  /bin/bash; bash test/run-tests.sh'`.
- `sed` and `awk` must work as BSD (macOS) and GNU (CI): GNU `sed` reads
  `-l` as a line length, and `gawk` reserves `or` and `and`.

## Style

- `run.sh` and `clear.sh` are CLIs: `set -euo pipefail`, quote expansions, use
  `local`, and keep user-facing messages in the calling script.
- `lib/*.sh` and `test/lib.sh` are sourced, never executed. They must not set
  shell options or call `exit`; return a status and let the caller decide.
- Keep parsing in `lib/inspect.sh`, naming in `names.sh`, validation in
  `lib/validate.sh`, run-setting precedence and `overrides.env` in
  `lib/config.sh`, the pack catalog in `images.sh`, path/security logic in
  `lib/paths.sh`, and the v7 move in `migrate.sh`. Host paths derive from
  `PIC_HOME` in `names.sh`; don't add another root.
- Zig targets the pinned version and uses the standard library only. Keep
  zigpeek command parsing in `cli.zig`, indexing in `stdlib.zig`, builtins in
  `builtins.zig`, and rendering in `info.zig`/`get.zig`. Keep enforcer command
  parsing in `main.zig`, rules in `policy.zig`, writes in `settings.zig`, and
  agent knowledge in `adapters.zig`/`pi.zig`. Run `zig fmt`.
- Docs must be concise and literal: no slogans, stale metrics, or repeated
  claims. Root `README.md` owns the network boundary; `UPGRADES.md` holds open
  work only.
- `pi-container/docs/configuration.md` is the source of truth for user-facing
  flags, environment variables, generated config files, and build arguments.
  Image, egress and model_url are set only by the `--image`/`--egress`/
  `--model-url` flags and `PI_IMAGE`/`PI_EGRESS`/`PI_MODEL_URL`; there is no
  config file. Secrets stay in the env file.
  Update it with the code and `--help` text.
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
- If a check needs a Mac, put the helper in `pi-container/test/`, ask the user
  to run the exact command, and end the turn. Do not fake the result.

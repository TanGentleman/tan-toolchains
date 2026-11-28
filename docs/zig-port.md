# Porting the pi-container CLI to Zig

Roadmap for replacing the bash CLI in `pi-container/` with one Zig binary,
`pic`. Pi agents in the `zig` image build it, one container session per
phase. This file sets the target, the parity rules and each phase's
acceptance checks. It does not fix the internal Zig design; the agents decide
that.

Versioning, the release scheme and what to cut before `main` belong to the
pre-main decisions memo, written separately. Where this roadmap meets it
(the version string, the release artifact, `pic migrate`), the memo decides
and this file says only what the port has to support.

## Target

One binary, `pic`, written in Zig at the `ZIG_VERSION` pin (0.17.0), standard
library only, built from source or downloaded as a release binary. It does
everything the host-side bash does today:

| Today | In `pic` |
| --- | --- |
| `run.sh` (`alias pic=.../run.sh`) | `pic [RUN OPTIONS] [COMMAND]`, `pic check`, `pic config`, `pic images`, `pic proxy`, `pic proxy-stop` |
| `clear.sh` | `pic clear list\|save\|nuke\|export\|import` |
| `serve.sh` (`run.sh serve`) | `pic serve` |
| `build.sh` | `pic build PACK\|all\|fleet` |
| `pi-ctr` (host half) | a `pic` subcommand that fleetd runs per turn |
| `migrate.sh` (`run.sh migrate`) | `pic migrate`, unless the memo cuts it |
| `names.sh`, `images.sh`, `lib/{config,egress,inspect,lock,paths,validate}.sh` | modules inside `pic` |

The user-facing surface is
[`pi-container/docs/configuration.md`](../pi-container/docs/configuration.md)
plus each script's `--help` text: every flag, environment variable, generated
file, exit status and refusal stays the same. The only intended differences
are these, and each is a decision to confirm before its phase:

- Messages start with `pic:` instead of `run.sh:`/`clear.sh:`.
- `clear` and `build` become reserved first words, like `check` and `config`
  are today, so `pic clear` no longer runs `clear` in the container. Add
  `pic -- COMMAND [ARG...]` to run any command, reserved names included.
- `pic --version` prints the version and the commit it was built from.
- `configuration.md`'s `clear.sh` table lacks `export` and `import`, which
  `clear.sh help` has. Add them in phase 0.

## What stays outside the binary

| What | Where | Why |
| --- | --- | --- |
| The egress lock (`pi_netlock_script`), its check (`pi_lock_check_script`), the `prep` and clone boot scripts, `check`'s in-VM probe, the enforcer probe, `pi-ctr`'s turn script | bash files under `pi-container/vm/`, embedded in `pic` at build time | They run inside the VM, as the container's command, under the image's bash. `test/test-netlock.sh` keeps testing them directly. |
| `proxy.py`, `Dockerfile.proxy` | `pi-container/`, embedded | The proxy image is Python. `pic` writes them to a build context when the proxy image is stale, so a release binary can still build it. |
| `egress/*.json`, `nvim/init.lua` | `pi-container/`, embedded | Data `pic` reads or seeds. |
| `Dockerfile`, `enforcer/`, `zigpeek/` | unchanged | `pic build` needs a checkout for agent images; nothing else does. The `ARG PI_VERSION` fallback that `ensure_settings` reads from the `Dockerfile` is captured at build time. |
| `fleetd` | `fleet/`, Go | A separate process that owns the fleet network layer. Only how it invokes the turn command changes. |
| Test and Mac tools: `test/*.sh`, `record-fixtures.sh`, `mac-e2e.sh`, `migrate-check.sh`, `vm-net-diag.sh`, the fleet probes | bash | They drive `pic` instead of `run.sh`. |
| Host programs `pic` runs as children | `container`, `tailscale`, `fleetd`, `tar`, `du`, `git` | Only what macOS ships or the root README's Setup table lists. `jq` is no longer needed by the CLI; tests, the recorder and the image still use it. |

`pic` makes no network requests: it links no socket code. It talks to the
`container` CLI, `tailscale` and `fleetd` only by running them. `serve.sh`'s
`curl` check that the loopback port is free is the one exception today.
Replace it by reporting fleetd's own listen error (recommended), or keep it
as a `curl` child.

## Proving parity

The existing suite is the spec. It must pass, unchanged in what it asserts,
against both the bash scripts and `pic` until the switch-over phase deletes
the bash.

- **CLI tests.** `test/test-integration.sh`, `test/test-serve.sh` and
  `fleet/e2e/pi-ctr.sh` run the scripts as commands. Phase 0 makes them
  take `PIC_BIN`: unset, they run the bash as now; set, they run
  `$PIC_BIN ARGS` for `run.sh ARGS`, `$PIC_BIN clear ARGS` for
  `clear.sh ARGS`, and so on. The fake CLI logs the exact `container` argv,
  so the same log assertions prove `pic` builds the same calls. Messages are
  matched on their text, not the `run.sh:` prefix.
- **Unit tests.** `test-names.sh`, `test-config.sh`, `test-egress.sh`,
  `test-validate.sh`, `test-paths.sh`, `test-inspect.sh` and `test-images.sh`
  source bash functions. Each gets a Zig test (`zig build test`) with the
  same cases and expected values, reading fixtures in place from
  `pi-container/test/fixtures/`. Expectations stay inline, as now.
- **Differential checks.** Names and hashes have to match the bash
  byte for byte, or existing volumes, proxies and networks are orphaned:
  `pi_profile_id`, `pi_locked_subnet`, `pi_agent_volume`, `pi_clone_volume`,
  `pi_proxy_name`, `pi_network_name`, `pi_proxy_image`. While both exist, a
  test compares `pic`'s values with `names.sh` over a table of paths,
  instances and repos (trailing slashes, case, `.git`, long names, the
  default profile). It can use a test-only executable that `zig build`
  never installs.
- **Unported commands.** A dev build (a build option, off by default) runs
  the bash script for any command not yet native, so the whole suite runs
  against `PIC_BIN` from phase 0. A release build never does. Each phase's
  acceptance runs its tests against a build without that fallback.
- **Same test rules.** Hermetic (temporary `HOME`, every `PI_*` unset),
  unknown fake commands fail, test scripts stay bash 3.2 compatible, and
  refusals, missing dependencies, malformed state and option guards are
  tested.
- **Proxy restamp.** `ensure_proxy`'s stamp hashes `shasum` output, which
  includes file paths. `pic` may hash differently; the cost is one proxy
  rebuild on first use. Say so in the phase's commit, and do not chase
  byte equality there.

What cannot be proven without a Mac: real `container` behaviour, `pic check`
in a VM, the egress lock in a real kernel, TTY handling, macOS file-system
semantics (case-insensitive paths, `stat` modes, symlinked `/var`), code
signing, and the E2E checklist. CI's `macos-latest` runner can run the unit
tests and the fake-CLI suite against an `aarch64-macos` build, which covers
the file-system part.

## Security invariants

Each invariant in [AGENTS.md](../AGENTS.md#security-invariants) carries
over unchanged. Each needs a Zig unit test or an integration case against
`pic`, and most already have one in the bash suite:

- The env file must be mode 600 or 400, following a symlink as
  `stat -L` does. `pic` reads it and never passes a value in argv or its own
  environment. `private/proxy.env`, `pi.env` and `private/egress.env` keep
  their contents (last matching line, `\r` stripped), modes (files 600,
  `private/` 700), atomic temp-and-rename writes under umask 077, the
  rewrite-only-if-changed rule, and `pi.env`'s removal when no value is
  left.
- Pi gets `sk-or-v1-placeholder` outside `--allow-egress`. The real key
  reaches only `pi-proxy` (as a file) and, in egress mode, the agent VM
  (as a file).
- `settings.json` is mounted read-only. It is seeded only when missing.
- The mount guard fails closed, with the same refusals: `/`, `$HOME`, its
  ancestors, `PIC_HOME`, the secrets directories, and any overlap with
  config, env or settings paths, compared case-folded on physical paths.
  The `pi_physical_path` gap in
  [UPGRADES.md](../pi-container/UPGRADES.md#review-follow-ups) is ported as
  is, then fixed in its own commit with its own tests.
- `--fleet-state` accepts only a real directory strictly below
  `$PIC_HOME/fleet/sessions`.
- Volumes are created with their `pi.*` labels before use. Deletion is
  scoped by profile, instance, kind and `pi.managed`.
- The host lock interoperates with the bash one while both exist: same
  directory, `mkdir` to take it, `pid` file, stale-lock rules,
  `PI_LOCK_WAIT`.
- Backups hold only regular `*.jsonl` files. The in-VM `find` and the host
  `tar` flags stay as they are.
- A check that cannot be verified refuses. An unknown proxy state is
  recreated. A network with an unknown mode is `unverified` and refused.
- The run's final `container` call replaces the `pic` process, as bash's
  `exec` does, so Pi owns the terminal and its exit status is `pic`'s.

## The `container` JSON contract

[ASSUMPTIONS.md](../pi-container/ASSUMPTIONS.md) still describes the
contract. `pic` parses with `std.json` in one module that plays
`lib/inspect.sh`'s role:

- Read only the observed paths in the table, with the same fallbacks:
  `absent` vs `unknown`, `ok`/`not-host-only`/`unverified`, the image
  version precedence (Env, label, history), exact-key volume labels.
  `std.json` decodes both `/` and `\/`.
- No whole-document text search, and no second parser. List output
  (`volume list -q`, `network list -q`) stays line-based.
- Fixtures stay recorder-owned. A Zig test reads every fixture the bash
  tests read, plus the inline payloads from `test-inspect.sh`.
- At switch-over, AGENTS.md's contract section replaces "parse with `jq` in
  `lib/inspect.sh`" with the Zig module. `jq` stays required for the tests
  and `record-fixtures.sh`. The Setup table's `jq` row then says tests
  only.
- `pic config --json` must print the same object as today
  (`jq -S` equal), because `pi-ctr` and fleetd consume it.

## Shipping

**From source.** `zig build --release=small` in the `pic` project, with Zig
at the pin. The Setup table already lists Zig for changing the repo, and
CI's version-pins job must check the new `build.zig.zon`'s
`minimum_zig_version` with the others. As `build.sh fleet` does for fleetd,
`pic build pic` can cross-compile `pic` for macOS inside the pinned `tools`
image, so the Mac never needs Zig once it has any `pic`.

**Release binary.** One `aarch64-macos` binary per release tag, with a
`SHA256SUMS` file, installed with `curl` and checked with `shasum -a 256 -c`.
That is no Homebrew and no new host tool. Zig's linker ad-hoc signs arm64
Mach-O binaries. `curl` sets no quarantine attribute, but a browser download
does. The binary's version and commit come from the tag. A release must ship
the bytes that passed [E2E.md](../pi-container/E2E.md#release): either E2E runs on the
downloaded artifact, or the Mac's own build is checked against the
artifact's checksum. The memo picks which, and the numbering.

**Without a checkout.** A release binary does everything except `pic build`,
which needs the checkout whose version matches the binary. `pic serve` needs
`fleet/bin/fleetd` from `pic build fleet`. How `pic` finds the checkout
(next to the binary, a flag, or an environment variable) is phase 8's
decision. Document it in `configuration.md`.

## Phases

Each phase is one session in the `zig` image (`pic --image zig --clone
TanGentleman/tan-toolchains`, or `run.sh` before switch-over), one branch, and
one or more commits that each keep the suite green. The image has Zig, ZLS,
zigpeek, bash 5, `jq` and `git`. It has no Apple `container`, no Go, no
Docker and no `python3`. In normal mode it reaches only GitHub and
OpenRouter.

So, in every phase:

- **Runs in the image:** `zig build test`/`check` for `pic`, the bash suite
  against bash and against `PIC_BIN` (except `test-proxy.sh`, which needs
  `python3`), `bash -n`, and cross-compiling for `aarch64-macos`.
- **CI only:** `test-proxy.sh`, the fleet Go tests, `fleet/e2e/pi-ctr.sh`,
  and the `macos-latest` jobs. Push, then read the CI result.
- **Mac only, through Tan:** `pic check`, E2E.md sections, fleet step 8, the
  bash 3.2 run (Docker). Put any helper in `pi-container/test/`, give the
  exact command, and stop.

### 0. Harness and skeleton

- **Scope:** create the Zig project (`pi-container/build.zig`, so embeds can
  reach `vm/`, `egress/`, `proxy.py` and `nvim/`), with `test`, `check`
  (fmt + tests) and an install step. Add `pic --help`, `--version`, and the
  dev-only fallback to bash. Move the in-VM heredocs out of `run.sh` and
  `pi-ctr` into `pi-container/vm/*.sh`, which the bash then reads, with
  behavior unchanged. Add `PIC_BIN` to the CLI tests. Add CI jobs: build and
  test `pic` on ubuntu and macos, then run the suite with `PIC_BIN` (fallback
  build). Add the new pin to the pins job and AGENTS.md's pin list. Add
  `export`/`import` to `configuration.md`.
- **Replaces:** nothing yet.
- **Accept:** `./test/run-tests.sh` passes unchanged. It also passes with
  `PIC_BIN` set to the fallback build. `zig build check` passes. Building
  without the fallback works too, and it refuses each unported command by
  name. CI is green on both OSes.

### 1. Pure core

- **Scope:** naming and hashing, the pack catalog, validation, run-setting
  precedence and the combo check, egress profile reading and
  `PI_EXTRA_TUNNEL` merging, `overrides.env`, the v7-path message, `$HOME`
  display (`pi_show`), path algebra and the mount-guard decision, and the
  JSON parsers.
- **Replaces:** `names.sh`, `images.sh`, `lib/validate.sh`,
  `lib/config.sh`, `lib/egress.sh`, `lib/inspect.sh`, `lib/paths.sh` (as
  modules; the bash stays).
- **Accept:** a Zig test for every case in the seven unit test files above.
  Every fixture is read by a test. The differential names check passes.
  Nothing in the suite changes.

### 2. Read-only commands and option guards

- **Scope:** argument parsing for every run option, and every guard that
  exits before a container call: bad `--image`/`--egress`/`--model-url`,
  bad `PI_*` values, impossible pairs, `--scratch`/`--fleet-state`/
  `--allow-egress`/`--manual` conflicts, instance and repo validation,
  `PI_PROXY_PORT`, v7 paths, and `overrides.env` errors. Then `config`,
  `config --json`, `images` and `--help`.
- **Accept:** the suite's config, images and refusal cases pass against the
  no-fallback build. `config --json` is `jq -S` equal to bash's for every
  case. `images` shows `?` when the runtime is down.

### 3. Host setup and the proxy

- **Scope:** the lock; env-file checks and the three filtered files;
  settings seeding; `ensure_network` (host-only verdict, subnet);
  `set_model_upstream` (including `gateway`); `ensure_proxy` (stamp,
  states, rebuild from the embedded build context); `proxy_ip`'s wait; and
  `proxy`, `proxy-stop`.
- **Accept:** the suite's env-file, network, proxy-state and proxy cases
  pass without fallback. The lock interop test passes: a bash `clear.sh`
  and `pic` contend for one lock directory. File modes and contents match
  bash for the same env file. Not runnable here: a real proxy build, which is
  Mac-only (E2E "First check").

### 4. Normal runs and `check`

- **Scope:** normal mode on the current folder, `--clone` (volume, labels,
  mirror when the profile has no GitHub route), `--scratch`,
  `--allow-egress`, a trailing `COMMAND`, `-t` only on a TTY, the final
  `exec`, and `check` with its embedded in-VM script.
- **Accept:** every argv assertion for these modes passes without
  fallback, including the egress lock wrapping, the env and mount order,
  and the placeholder key. A failing `container run` gives `pic` the same
  status. Mac: E2E "First check", "Egress mode" and "Pi and instances".

### 5. Manual mode, fleet turns and `pi-ctr`

- **Scope:** `--manual` (Neovim mounts and seeding, manual clone with
  `pi.env` refresh), `--fleet-state`/`--fleet-name`, and the host half of
  `pi-ctr` (`--config`, `--stop`, the turn) as a `pic` subcommand running
  the embedded turn script. Change fleetd's harness wiring to invoke it,
  with Go tests.
- **Accept:** the manual and fleet-state cases pass without fallback.
  `fleet/e2e/pi-ctr.sh` passes with `PIC_BIN` (CI), and so does
  `go test ./agent` (CI). Mac: E2E "Mounts and clone", "Neovim and ZLS",
  and fleet step 8.

### 6. `pic clear`

- **Scope:** `list`, `save`, `nuke agent|clones|profile|all`, `export`,
  `import`, `--image`, `--instance`, `--yes`, and the confirmation prompt.
- **Accept:** every `clear.sh` case passes without fallback, including
  scoped deletion, missing-image backup skip, `import`'s v7 label rewrite,
  and its refusal when a volume exists. Mac: E2E's `clear.sh` checks and
  `migrate-check.sh`'s export comparison.

### 7. `pic serve` and `pic build`

- **Scope:** `serve` with its checks (Tailscale status JSON, from
  `test/fixtures/tailscale/`), the fleetd and `tailscale serve` children,
  signal handling, `--check`, and dropping the real key from fleetd's env.
  `build` covers packs, `all`, `fleet` (Go image pin, `go.mod` check, commit
  stamp) and `pic`. Settle the port-probe decision.
- **Accept:** `test-serve.sh` passes without fallback. The build cases pass
  (add fake-CLI cases for the `build.sh` usage errors if missing). Mac:
  `pic serve --check`, and `pic build` for every pack.

### 8. Switch-over

- **Scope:** `pic` becomes the entry point. Delete `run.sh`, `clear.sh`,
  `serve.sh`, `build.sh`, `names.sh`, `images.sh`,
  `lib/{config,egress,inspect,lock,paths,validate}.sh`, the bash unit tests
  they make redundant, and `migrate.sh` (ported or cut, per the memo). Keep
  the CLI tests, now always run against `pic`. Remove the fallback. Point
  `mac-e2e.sh`, `migrate-check.sh`, `record-fixtures.sh`, the playbooks,
  READMEs, E2E.md, `configuration.md` and fleet docs at `pic`. Update
  AGENTS.md: commands, style map, contract section, Setup table row.
  Decide how `pic` finds the checkout.
- **Accept:** `grep -rn 'run\.sh\|clear\.sh\|build\.sh\|serve\.sh'` finds
  no reference to a deleted script. The suite and CI are green.
  Mac: the full E2E.md through Release, and fleet step 8, before merge.

### 9. Release binary

- **Scope:** a tag-triggered CI job that builds `aarch64-macos`
  `--release=small`, writes `SHA256SUMS` and attaches both to the release.
  Add the README install steps (curl, `shasum -c`, where to put `pic`) and
  the E2E Release section's provenance step, per the memo.
- **Accept:** a dry run on a pre-release tag produces the artifact. Mac: the
  downloaded binary passes `shasum -c`, `codesign -v`, `pic --version`
  (tag and commit), and `mac-e2e.sh` in a new account.

Phases 1 and 2 can run in parallel after 0. Phases 3–7 are in order of
dependency, though 6 and 7 only need 3.

## Agent prompt

Paste this when spawning a phase, filling in the brackets:

```text
You are porting pi-container's bash CLI to Zig. Do phase [N] of docs/zig-port.md, and only that phase.

Base branch: [BASE]. Work on a new branch [zig-port/pN-short-name]; commit and push it when the phase's acceptance checks pass. Do not merge.

Before changing anything, read: AGENTS.md; docs/zig-port.md (all of it); pi-container/docs/configuration.md (the spec); pi-container/ASSUMPTIONS.md; [the bash files this phase replaces]; [the test files named in its Accept line]; pi-container/test/lib.sh and fake-container.sh; the decisions memo at [PATH, or "none yet"].

Use zigpeek for every Zig std API you are not sure of: Zig 0.17's std.Io, std.process and std.json differ from older docs.

Rules: standard library only; no network code; do not hand-edit fixtures; keep the bash suite's assertions unchanged unless this phase's scope says otherwise; one concern per commit, with `scope: lowercase imperative summary` and a body giving why, the invariant, and the tests.

Done means: every Accept item for phase [N] passes here, or is named as CI-only or Mac-only. Push and check CI. End with a list of each acceptance item as passed, failed (with output), CI pending, or needs Tan on a Mac (with the exact command). Note decisions you made that the roadmap left open, and anything you found that belongs in UPGRADES.md.
```

## Later

CLI-only conveniences, after phase 9. None blocks the port:

- `pic alias on|off`: add or remove a `pic` line in the shell's rc file, or
  print where the binary is and how to put it on `PATH`.
- Shell completion generated from the same option table as `--help`.
- `pic ps`, to list pi's running containers. It needs a recorded
  `container list` fixture first, which `pic migrate`'s running-agent check
  also wants.
- `pic sync` for interactive sessions into a fleet node
  ([UPGRADES.md](../pi-container/UPGRADES.md#fleet)).
- Per-agent-volume image provenance markers (UPGRADES review follow-ups).

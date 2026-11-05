# v5 candidate plan

Status: proposal. Not implemented. Candidates for the next container branch
(`container-bootstrap-v5`). Pick a subset; this is a menu, not a commitment.

## What the iterations have been

| branch | theme |
| --- | --- |
| v1 | core sandbox: `pi-locked` network, proxy MITM, volumes, run/clear |
| v2 | dev toolchain: pinned Zig/Neovim/ZLS, zigpeek, backups, multi-instance |
| v3 | enforcer hook, jq `container` JSON contract, CI test suite |
| v4 | image packs, tokenless runs, provenance announcements, clear.sh hardening |
| v5 (candidate) | backend selection, starting with a cloud agent backend |

Two existing artifacts feed the v5 theme:

- `docs/audit.md` (branch `audit-workflow-spec`) already defines a `--backend`
  seam: it takes an image reference, mounts, environment, network, and argv,
  and returns an exit status plus artifacts. Reuse that definition rather than
  inventing a second one.
- The deleted `modal-scratchpad.md` (recoverable at `e9bcb3e^`) already
  analysed what carries over to a cloud driver and what does not: the secret
  split, read-only settings, and per-instance state carry; the `container`
  CLI, `pi-locked` network, proxy container, host bind mounts, and the TUI do
  not.

## Candidate 1: cloud agent backend (Devin first)

A tool that submits a task to a cloud coding agent instead of starting a local
VM. Devin's session API is the first target: create a session with a prompt
and repo reference, poll for status, fetch the result. Batch/async only; no
TUI, no host bind mounts, no live edits.

**Where it lives:** a new top-level tool directory (one tool per directory),
not inside `pi-container/run.sh`. The network boundary in the root README says
shipped tools make no network requests and a separate process owns the network
layer; `run.sh` today only talks to the local `container` CLI. A Devin driver
is by definition that separate network-owning process, so it gets its own
directory with its own README, env file, and tests. `run.sh` gains nothing in
v5; a `--backend` dispatch is justified only when a second backend exists.

**What carries over:**

- The env-file conventions: mode-600 host file, filtered into per-consumer
  files, fail early when a required key is absent. The Devin API key never
  enters logs or argv.
- The contract-test pattern: record real session-API JSON responses as
  fixtures, parse only observed shapes with `jq`, fail on unknown shapes, fake
  the HTTP client in integration tests exactly like `test/fake-container.sh`
  fakes the `container` CLI. Unknown fake commands must fail.
- The least-privilege token rule: Devin has its own GitHub integration and
  model billing, so no `ghp_` token and no OpenRouter key cross to the cloud
  path. The secret-split invariant maps to "reference provider-side secrets by
  ID, never inline them in a prompt or request body."

**What does not carry over:** the `pi-locked` network, `pi-proxy`, volume
labels, the mount guard, and every `lib/inspect.sh` parser. Egress control on
the cloud path is the provider's sandbox, not ours. The docs must say so
plainly, the way the root README states the local boundary today.

**Doc work:** a per-backend invariant matrix (which of the AGENTS.md security
invariants each backend enforces locally, delegates to the provider, or cannot
provide). Without this, "backend" becomes a way to silently drop the sandbox.

**Risks to pin down at implementation time:** exact API version and payload
shapes (record fixtures before parsing), idempotency keys for safe retries,
spend caps where the API supports them, and session teardown on timeout.

Later candidates on the same seam: Modal batch jobs (analysis already in git
history), or a second cloud agent provider. Do not build seam machinery ahead
of the second backend.

## Candidate 2: proxy hardening

From UPGRADES.md, and it matters more once backends multiply the places keys
live:

- Authenticate proxy clients. Every instance on a profile's network can spend
  that profile's OpenRouter key today.
- Stop mounting `$cfg/private` read-write into the long-running proxy.
  Generate certificates in a short-lived container, mount runtime material
  read-only.

## Candidate 3: fail-closed `pi_physical_path`

`lib/paths.sh` can return an unresolved path when the leaf is missing under a
symlinked parent. The mount guard must refuse instead. Security-sensitive path
algebra: focused tests first, per the review follow-up.

## Candidate 4: profile isolation fixes

- `nuke all` in one profile still deletes the shared active `PI_IMAGE`. Scope
  image deletion per profile or refuse when other profiles exist.
- Instance-to-image provenance: a marker file in each agent volume recording
  the image that last wrote it, so `clear.sh list` can show it.

## Candidate 5: enforcer ergonomics

- A `run.sh` flag or pack-level default to auto-enable the hook for new
  instances, instead of the manual `enforcer on` round-trip.
- A rules file in place of the single `ghp_` substring, only if a second rule
  is actually wanted.

## Candidate 6: CI and checks

- Assert `ZLS_VERSION == ZIG_VERSION` and the Neovim/ZLS pins in CI.
- Wire up shellcheck after triaging existing warnings.
- If candidate 1 lands, the new tool's tests join `test/run-tests.sh`.

## Explicitly not in v5

- Multi-arch images. The aarch64-only guard stays until multi-arch handling is
  tested.
- `--manual` network hardening. It is documented as unsandboxed; do not blur
  that line incidentally.
- The audit workflow implementation (`audit-workflow-spec`). It shares the
  backend seam definition and can follow once the seam exists, but folding it
  into v5 makes the branch do two things.
- A TUI/PTY bridge to cloud backends. Cloud is submit-and-poll; interactivity
  stays local.

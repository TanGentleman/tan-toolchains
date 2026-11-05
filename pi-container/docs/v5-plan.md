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
| v5 (candidate) | open: hardening the existing local sandbox and the checks around it |

The candidates below are ordered by how much they protect what already exists.
The local sandbox is the product; nothing here changes the network boundary,
and no new egress host is added.

## Candidate 1: proxy hardening

From UPGRADES.md:

- Authenticate proxy clients. Every instance on a profile's network can spend
  that profile's OpenRouter key today.
- Stop mounting `$cfg/private` read-write into the long-running proxy.
  Generate certificates in a short-lived container, mount runtime material
  read-only.

## Candidate 2: fail-closed `pi_physical_path`

`lib/paths.sh` can return an unresolved path when the leaf is missing under a
symlinked parent. The mount guard must refuse instead. Security-sensitive path
algebra: focused tests first, per the review follow-up.

## Candidate 3: profile isolation fixes

- `nuke all` in one profile still deletes the shared active `PI_IMAGE`. Scope
  image deletion per profile or refuse when other profiles exist.
- Instance-to-image provenance: a marker file in each agent volume recording
  the image that last wrote it, so `clear.sh list` can show it.

## Candidate 4: enforcer ergonomics

- A `run.sh` flag or pack-level default to auto-enable the hook for new
  instances, instead of the manual `enforcer on` round-trip.
- A rules file in place of the single `ghp_` substring, only if a second rule
  is actually wanted.

## Candidate 5: CI and checks

- Assert `ZLS_VERSION == ZIG_VERSION` and the Neovim/ZLS pins in CI.
- Wire up shellcheck after triaging existing warnings.
- Run `test/run-tests.sh` on macOS as well as Linux, so the bash 3.2
  constraint is exercised rather than assumed.

## Explicitly not in v5

- Multi-arch images. The aarch64-only guard stays until multi-arch handling is
  tested.
- `--manual` network hardening. It is documented as unsandboxed; do not blur
  that line incidentally.
- The audit workflow implementation (`audit-workflow-spec`). It is its own
  proposal with its own runtime prerequisites; folding it into v5 makes the
  branch do two things.

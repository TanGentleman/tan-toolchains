# Before main: decisions

Decisions to settle before `container-bootstrap-8` becomes `main`. Each one
has the options, a recommendation, and what it cuts or costs. Answer each
with one line (`D3: B`, `D7: keep`). Once the answers have landed, delete
this file in the same pass as `docs/v8.md`, before the E2E run (see
[Order](#order)).

Facts this rests on (checked 2026-11-28):

- `main` is `3398edd` ("add a readme") and is an ancestor of the branch,
  which is 247 commits ahead: 155 files, about 24k lines.
- `v0.1.0` is an annotated tag on `83c007b` (container 1.6.1, v7 paths). It
  is an ancestor of the branch, 81 commits back, and not reachable from
  `main`. Its message records the gate: fresh 16, verify 93, manual 6,
  fleet 20 passed.
- Versions in the tree: enforcer `0.1.0` (`build.zig.zon`), zigpeek `0.6.0`
  (`build.zig.zon` and `src/version.zig`, checked equal in CI). `fleetd
  -version` prints the commit. pi-container has no version. No VERSION file,
  no CHANGELOG, no release workflow.
- `E2E.md` has 96 checkboxes; `fleet/docs/macos.md` step 8 has 8 more.
  `mac-e2e.sh auto` runs all but about 8 of the E2E ones.
- `spikes/local-model` is about 2k lines of Python and shell that CI does not
  run.

## Summary

| # | Decision | Recommendation |
|---|---|---|
| D1 | Image packs | Two: `pi` and `zig`. Drop `tools` and `editor`; merge `min` and `full`. |
| D2 | Enforcer in the images | Only in `zig`, until it is on by default. |
| D3 | `--manual` | Drop it. Mount the Neovim paths in normal `zig` runs. |
| D4 | `--allow-egress` | Keep as is for 0.2.0. |
| D5 | `PI_EXTRA_TUNNEL` | Delete it; use a custom egress profile. Fixes the Kranti issue too. |
| D6 | Egress profiles | Keep the format; no change. |
| D7 | Proxy forwards the real key to any openrouter.ai path | Allow only the methods and paths Pi uses. |
| D8 | fleetd trusts a header on loopback TCP | Try a unix socket behind `tailscale serve`; else document that every account on the Mac is an owner. |
| D9 | `pic migrate` and `overrides.env` | Keep `migrate` for 0.2.0 only; drop `overrides.env` now if your Mac has none. |
| D10 | `spikes/` | Move off main to a `local-model` branch. |
| D11 | `ISSUES.md` | Turn on GitHub issues and move it there. Keep `UPGRADES.md`. |
| D12 | E2E checklist | Script list plus about 10 by-hand checks; fresh account only on minor releases. |
| D13 | Gemini 402 (`max_tokens`) | Seed a read-only `models.json`; the proxy does not rewrite bodies. |
| D14 | Stale docs and branches | Delete `docs/v8.md` and this file before E2E; fold `container-1.7.1.md` into `operations.md`; delete merged remote branches after main moves. |
| R1 | What a version means | One repo tag `vX.Y.Z` for pi-container and fleet; enforcer and zigpeek keep their own numbers. |
| R2 | VERSION file, CHANGELOG | Neither. The tag is the version; the GitHub Release is the changelog. |
| R3 | Release workflow | Yes, small: on a `v*` tag, check it is annotated, on `main` and green, then create the Release. No artifacts. |
| R4 | Merge strategy | Fast-forward `main` to the tested SHA; tag `v0.2.0` on that SHA. |
| R5 | `v0.1.0` | Leave it; the fast-forward makes it reachable from main. Add a Release for it by hand. |

## Product surface

### D1. Image packs

Today: `min`, `full` (default), `zig`, `tools`, `editor`. `tools` and
`editor` have no Pi and run only with `--manual`. `full` is `min` plus `gh`
and an enforcer that ships off.

- **A.** Keep five.
- **B.** Drop `tools` and `editor`; keep `min`, `full`, `zig`.
- **C.** Two packs: `pi` (Pi, git, jq, rg, fd, `gh`) and `zig` (`pi` plus
  Zig, zigpeek, Neovim, ZLS, enforcer).

**Recommend C.** `gh` is the only real difference between `min` and `full`
once D2 moves enforcer, and `gh` without a token does nothing. Fleet's
scratch chats work on `pi` as they do on `min`.

Cuts: two pack names, two Dockerfile targets, `min`/`full` aliases after one
release, about 10 E2E lines (Build and keys), and the default image no
longer waits on the Zig stage. Costs: tags change (`pi-full:local` becomes
`pi-pi:local` or `pi:local`), so `PI_IMAGE=min` and `full` need a one-release
alias or a clear refusal; `test-images.sh`, `images.sh`, docs and playbooks
change.

### D2. Enforcer in the images

It is built into every pack but `min`, ships disabled, and its only rule is
the `ghp_` substring. `pi-ctr` already scans pushes for token patterns
itself.

- **A.** Keep as is.
- **B.** Turn it on by default for new instances.
- **C.** Build it only into `zig` (or nowhere) until B is wanted.

**Recommend C.** Installed-but-off costs a Zig build in the default image and
E2E lines, and blocks nothing. Cuts: the Zig stage from the default build,
three E2E lines unless `zig` is under test. Costs: `check` and `pi-ctr`
lose enforcer on the default image (`pi-ctr`'s own scan stays).

### D3. `--manual`

A shell on the default network, no lock, no proxy, no key. It exists for
Neovim/ZLS and plugin downloads, and it is one of two unlocked modes.

- **A.** Keep.
- **B.** Drop it; mount the Neovim paths in normal runs of the `zig` pack
  (`pic --image zig bash`, then `nvim`), behind the lock. Plugin downloads
  that need the internet use `--allow-egress`.

**Recommend B.** One unlocked mode is easier to state and test than two.
Cuts: `docs/manual.md`, the `--manual`-only refusals and flags, most of the
Neovim and ZLS E2E section (10 lines), the `UPGRADES.md` "promote the Neovim
paths" item. Costs: Mason and release-asset downloads need `--allow-egress`,
which carries the real key; a keyless unlocked shell is gone. If that
matters, keep A and say so; the port can revisit.

### D4. `--allow-egress`

**Recommend keep, unchanged, for 0.2.0.** It is the documented escape hatch
and the boundary docs describe it correctly. A per-mode key (a second,
low-limit key just for this mode) is new work; record it in `UPGRADES.md`
(it is already there) and let the port decide.

### D5. `PI_EXTRA_TUNNEL`

It is read from the shell, else from the env file. From the env file it
widens every run of that profile, including `offline`, whose point is that
only the model route is open. Its one user is Kranti, which also gets the
GitHub token today ([ISSUES.md](../ISSUES.md)).

- **A.** Keep as is.
- **B.** Shell only: stop reading it from the env file.
- **C.** Delete it. Kranti uses a profile:
  `$PI_CONFIG_DIR/egress/kranti.json` with
  `{"v":1,"tunnel":["NAME.convex.site"],"model_url":"any","github_token":false}`
  and `KRANTI_PIC_ARGS=--egress kranti`.

**Recommend C.** A profile already covers it, names the hosts in one file,
and drops the token, which closes the Kranti issue. Cuts: the env-file read,
the merge and source reporting in `run.sh config`, the
[extra tunnel hosts](../pi-container/docs/configuration.md#extra-tunnel-hosts)
section and its tests. Costs: a Convex deployment that changes host needs
the profile edited. If you want to keep a per-run knob, take B.

### D6. Egress profiles

Two built-ins plus `$PI_CONFIG_DIR/egress/NAME.json` with `tunnel`,
`model_url` (`any`/`private`) and `github_token`. **Recommend no change.**
With D5 it is the only way to widen the proxy, which is what it should be.

### D7. The proxy and openrouter.ai paths

`proxy.py` MITMs `openrouter.ai` and any `*.openrouter.ai`, refuses only
paths with `..`, and adds the real key to every request. Pi can therefore
send the key to any OpenRouter endpoint (key info, credits, generation
history, any subdomain), not only model calls.

- **A.** Keep.
- **B.** Exact host `openrouter.ai`, and an allowlist of method and path
  (start from what `pic proxy` logs during E2E: likely
  `POST /api/v1/chat/completions` and `GET /api/v1/models`). Anything else
  gets 403 and a `deny` log line.

**Recommend B, before main.** It is a short Python change with a test in
`go test ./agent` (real Pi behind real `proxy.py`). Costs: a Pi upgrade that
calls a new path fails until the list grows; the agent test catches that in
CI. The proxy is not part of the bash port, so this need not wait.

### D8. fleetd and the identity header

fleetd listens on `127.0.0.1:7433` and trusts `Tailscale-User-Login`.
`tailscale serve` strips a client's copy, but any process on the Mac,
including any other macOS account (the release gate creates one), can send
it and act as an owner. VMs cannot: they do not share the Mac's loopback.

- **A.** Keep and document: every account and process on this Mac is an
  owner.
- **B.** Listen on a unix socket in `$PIC_HOME/fleet` (mode 0700) and point
  `tailscale serve` at it. Check on the Mac first that `tailscale serve`
  takes a socket target and that the Tailscale app can open a socket in your
  home folder.
- **C.** Ask tailscaled who the peer is (LocalAPI whois). Rejected: fleetd
  would dial, and the boundary says it dials nothing.

**Recommend B if the Mac check passes, else A.** fleetd is Go, not part of
the port, so decide now. Costs for B: `pic serve --check`, the e2e harness
(curl `--unix-socket`), and `macos.md` step 8 change.

### D9. `pic migrate` and `overrides.env`

`overrides.env` exists only to hold paths `migrate` left in place
(`PI_BACKUP_DIR`, `PI_ENV_FILE`), and every entry point reads it. Only
Macs that ran v0.1.0 have v7 paths.

- **A.** Keep both.
- **B.** Keep `migrate` for 0.2.0; drop `overrides.env` now (`migrate`
  moves everything or stops). Delete `migrate` in 0.3.0.
- **C.** Delete both now.

**Recommend B** if `ls ~/.pic/overrides.env` finds nothing on the Macs that
migrated; else keep `overrides.env` until 0.3.0. Neither gets ported to
Zig. Cuts: the reader in three entry points, its validation and tests, a
section of `configuration.md`. The two open items in `docs/v8.md` (checking
for running `--manual`/`--allow-egress` sessions; allowing the old
`PI_CONFIG_DIR`) become "won't do".

### D10. `spikes/`

`spikes/local-model` serves a model for the `offline` playbook. It needs
`uv` (a row in the Setup table), and CI does not run it.

- **A.** Keep on main as is.
- **B.** Move it to a `local-model` branch (or its own repo). Playbook 3
  says "any OpenAI-compatible server on gateway port 8090" and links it.
- **C.** Keep and add CI.

**Recommend B.** `offline` needs only the endpoint contract, which
`configuration.md` already states. Cuts: 2k untested lines and the `uv` row
from main. Costs: the offline recipe is one link away. C is hard because
`mlx-lm` needs Apple silicon.

### D11. `ISSUES.md`

GitHub issues are off, so known problems live in `ISSUES.md` beside
`UPGRADES.md` (planned work).

- **A.** Keep both files.
- **B.** Turn on issues, move the four `ISSUES.md` entries, delete the file.
  Keep `UPGRADES.md` for design work agents read offline.
- **C.** Move both to issues.

**Recommend B.** Bugs need status and links; the backlog reads better in the
tree. Cost: AGENTS.md's pointer to `ISSUES.md` changes.

### D12. The E2E checklist

96 lines plus fleet's 8, and a release needs a new macOS account. Most lines
duplicate what `mac-e2e.sh auto` and the CI fake-CLI tests already check
(refusal exit codes, `config` output, invalid names, pack lists).

Essential on a real Mac, because CI cannot see them:

1. the egress lock: IPv4 and IPv6 blocked, `NET_ADMIN`/`NET_RAW` dropped, no
   DNS from `100.100.100.100` (scripted);
2. the real key never in a normal VM; placeholder in place (scripted);
3. `offline`: no token, GitHub refused, the local model answers (scripted,
   needs a model server);
4. `settings.json` unchanged after `/settings` and `Ctrl+S` saves (by hand);
5. the mount guard, clone and `git push` (scripted);
6. cleanup touches only its profile and instance (scripted);
7. fleet step 8: isolation, turns, abort, refusals (scripted), and
   `kill -9` and restart (by hand);
8. `/model`, `/quit`, and a session crossing instances only where expected
   (by hand);
9. README setup in a fresh account (release step 3).

- **A.** Keep the list.
- **B.** `E2E.md` lists the script phases (the script is the spec) and only
  the by-hand checks, about 10. Drop sections D1 to D3 remove. Drop "zigpeek
  offline" and "cross-compile" (zigpeek CI and `check` cover them). Move "when
  moving a pin" to the pin procedure in AGENTS.md. Run the fresh-account step
  only for a minor release or a change to Setup.

**Recommend B.** Cost: one rewrite of `E2E.md` and the list `mac-e2e.sh`
prints; nothing in the script changes.

### D13. Gemini 402 (`max_tokens`)

**Recommend** the Pi-native fix from `ISSUES.md`: `run.sh` seeds
`$PI_CONFIG_DIR/models.json` and mounts it read-only like `settings.json`.
It also covers `--allow-egress`, and the proxy keeps out of request bodies
(which D7 relies on). Alternatively defer it past 0.2.0: it affects one
model.

### D14. Stale docs and branches

- `docs/v8.md` says to delete it at merge. With a fast-forward the merge
  commit is the tested SHA, so delete it, and this file, before the E2E run.
- `pi-container/docs/container-1.7.1.md`: keep the reinstall steps in
  `operations.md`, delete the 1.6.1 diff.
- ISSUES.md's stale image fixture (Pi 1.6.0): re-record on the Mac before
  the E2E run; it is recorder-owned.
- After main moves: delete remote branches whose tip is in main
  (`container-bootstrap-*`, merged `devin/*`). List any others and decide
  per branch.

No file is deleted by this PR.

## Release

### R1. What a version means

- **`vX.Y.Z` on the repo** is the product: pi-container (`run.sh`,
  `clear.sh`, `build.sh`, images, proxy) and fleet, built from that one SHA.
  They ship together: `pic serve` runs a `fleetd` built from the checkout,
  and `pi-ctr` lives in pi-container.
- Before 1.0: `Y` for anything that changes paths, flags, env vars, image
  names or the on-disk layout, with the move in the release notes; `Z` for
  fixes. So this merge is `v0.2.0` (layout moved to `~/.pic`), as v8.md
  planned.
- **enforcer and zigpeek** keep their own versions in `build.zig.zon`
  (zigpeek also `src/version.zig`, which CI checks). Bump one only when its
  CLI or output changes. No per-tool tags unless one is published on its
  own. The release notes name the versions the images built.

### R2. VERSION file and CHANGELOG

Neither. The annotated tag is the version, and `fleetd -version` already
prints the commit. The GitHub Release for a tag holds the notes: the gate
results (as v0.1.0's tag message does) and a few bullets of what changed.
`UPGRADES.md` stays open-work only. A `pic version` that prints the tag can
be compiled into the Zig port; do not add one in bash.

### R3. Release workflow

Add `.github/workflows/release.yml`, about 30 lines, on `push: tags: v*`:

1. the tag is annotated, and its commit is on `main`;
2. `test.yml` passed on that commit (call it with `workflow_call`, or check
   the run);
3. `gh release create` with the tag message as notes.

It builds and uploads nothing: images and `fleetd` are built on the Mac.
Cost: one workflow with `contents: write`. Tagging stays a hand step after
the Mac gate, as in `E2E.md`'s Release section.

### R4. Merge strategy

- **A. Fast-forward** `main` to the tested SHA. History stays, `v0.1.0`
  becomes reachable, and main's tip is the SHA the Mac gate tested.
- **B. Squash.** One commit, but a new SHA nobody tested, and `v0.1.0` stays
  off main.
- **C. Merge commit.** Also a new SHA, and nothing to merge from main.

**Recommend A**, then protect `main` (PRs only, `test` required), and tag
`v0.2.0` on the same SHA.

### R5. `v0.1.0`

Leave the tag where it is; do not move or re-cut it. The fast-forward makes
it part of main's history. Create a GitHub Release for it by hand, with
its tag message as notes, so the Releases page starts at 0.1.0.

## Wait for the Zig port

Cut surface in bash now, so the port starts smaller; leave redesign to the
port:

- the env vars that override derived names (`PI_PROXY_NAME`,
  `PI_NETWORK_NAME`, `PI_PROXY_IMAGE`, `PI_LOCKED_SUBNET`,
  `PI_AGENT_VOLUME`): decide the config surface once, in the port;
- the command layout (`pic config`, `images`, `check`, `serve`) and the
  duplicated `require_*` helpers between `run.sh` and `clear.sh`;
- a version command (R2) and the image commit label;
- a shellcheck step (`UPGRADES.md`): skip for code that is going away;
- a per-mode key for `--allow-egress` (D4).

Do not wait:

- `pi_physical_path` returning an unresolved path (`UPGRADES.md`): the mount
  guard must fail closed, so fix it in bash with tests, or confirm the port
  lands before anyone relies on 0.2.0;
- D7 and D8: the proxy and fleetd are not part of the port.

## Order

1. Answer D1 to D14 and R1 to R5.
2. Land the cuts on `container-bootstrap-8`, one concern per commit, with
   docs and tests. Delete this file and `docs/v8.md`; re-record the image
   fixture.
3. On the final SHA: `E2E.md` (as D12 leaves it) and fleet step 8.
4. Fast-forward `main`, tag `v0.2.0`, push the tag; R3 creates the Release.
5. Release for `v0.1.0` by hand; delete merged branches.

# External sandboxes: findings (archived)

**Archived.** `pi-ctr` now runs Pi itself, not just its tools, in
pi-container's VM, so the `pi-sbx` harness and its test were removed. The
code is at commit 13f1542 (`fleet/sandbox/pi-v86.sh`, `fleet/e2e/sandbox.sh`).
The findings below are kept as they were when that commit was tested.

Notes from reading Prime Radiant's [External sandboxes for coding agents][post]
and its source, and from running one of its sandboxes under `fleetd`. The
pattern fit fleet with no change to `fleetd`, because a harness is already
any command.

Source read (commits as cloned on 2026-11-23): [external-sandbox][es] `0681c98`
(protocol and conformance runner), [external-sandbox-v86][v86] `4134917`,
[external-sandbox-container][ctr] `c4a9412`, [external-sandbox-pi][espi]
`91cfc06`, [agent-session-archiver][asa] `b1b5951`.

## The pattern

The agent stays on the host and keeps its model traffic, but every command
and file operation it makes goes over a local HTTP API into a Linux guest.
The guest sees only the folders you mount, read-only or read-write, and has
no network unless you turn on a managed proxy that allow-lists origins and
swaps placeholder credentials for real ones on the host ([post]). The three
servers (v86 in WebAssembly, Apple Containers, Quicksand on QEMU) implement
one protocol, revision 1 ([PROTOCOL.md][proto]): `GET /health`, `GET /mounts`,
`POST /exec`, `/exec/ws` for streaming, `/codex` for Codex's exec-server, and
optional `/proxy` management.

For Pi, the [external-sandbox-pi][espi] extension replaces `bash`, `read`,
`write`, `edit`, `grep`, `find`, `ls` and `!`/`!!`. With
`--no-builtin-tools`, nothing can run on the host if the extension fails to
load, and the extension never falls back to local execution ([espi README][espi]).

The post is clear about limits, and they apply here too: the servers are
unaudited prototypes, a read-write mount can still be wrecked, the guest is
Linux so a macOS `node_modules` or `.venv` may need reinstalling, and an
allowed host can echo a substituted credential back ([post]). The protocol
says conformance does not prove isolation ([PROTOCOL.md][proto]).

## How it maps onto fleet

| fleet | external sandbox |
|---|---|
| harness = one command per turn (`-harness name=cmd`) | `sandbox/pi-v86.sh` starts a guest, runs `fleetd agent pi` with the extension, stops the guest |
| `$FLEET_WORK`, not replicated | the only mount, read-write |
| `$FLEET_STATE`, checkpointed | never mounted; Pi's session file stays on the host side |
| network daemons are separate processes (`AGENTS.md`) | guest network is off; the managed proxy is a separate host process |
| `pi-container/proxy.py` keeps the key out of the agent | the guest never gets the key; Pi's own process still has it (see gaps) |

Because guest state is thrown away after each turn and only `$FLEET_WORK`
and `$FLEET_STATE` survive, handoff, fork and seal work unchanged. A peer
needs the same sandbox packages installed to resume a `pi-sbx` session.

## What was run

On the Linux dev VM (not a Mac), with Pi 1.6.0, external-sandbox-v86 0.4.0
and external-sandbox-pi 0.1.0, against a fake model that asks for one bash
call (`e2e/sandbox.sh`):

| Check | Result |
|---|---|
| Where the call ran | Alpine Linux guest, i686, uid 1000 (host is x86_64) |
| Write to `$FLEET_WORK` | file appears on the host |
| See `$FLEET_STATE`, `events.jsonl`, other sessions | no; only the empty parent folders of this session's `work` exist in the guest |
| See `OPENROUTER_API_KEY` | no |
| Network | none (`wget: bad address`) |
| Sandbox fails to start | harness exits 1 before Pi runs |
| Same test with plain `pi` (mutation check) | fails: the key and the state folder are visible |
| Turn time | about 14 s for a one-call turn, mostly v86 booting |

`pi-v86.sh` checks `/health` before starting Pi: status `ready`, `network`
false, and exactly one mount, `$FLEET_WORK` read-write. Anything else and the
turn fails.

## Gaps

- **Pi itself is not sandboxed.** The Pi process, its extensions and its model
  calls run on the host with `OPENROUTER_API_KEY` in the environment. The
  sandbox stops the model's tool calls from reading it, which is the main
  path, but not a malicious extension. `--no-approve` (already in
  `agent/agent.go`) stops repo `.pi/extensions` from loading.
- **The sandbox and the proxy are separate layers.** The sandbox limits
  what tool calls can see and reach. `pi-container/proxy.py` (step 11 of
  [macos.md](macos.md)) keeps the real key out of every process `fleetd`
  starts, Pi included. Neither one stops a `-spawner` or a `steer` share from
  running a plain `pi` session instead, and neither stops a process on the
  Mac from calling `fleetd` on loopback as the owner (README, "What access
  means").
- **The harness script is not sandboxed either.** `pi-v86.sh` gets
  `OPENROUTER_API_KEY` through `-harness-key pi-sbx` so Pi can use it, and
  starts the sandbox server with the key removed.
- **v86 is slow and 32-bit.** Fine for `git`, `rg` and scripts; poor for
  builds. Apple Containers run arm64 at native speed but are untested here.
- **Only Pi.** Claude Code's native Read/Edit are not redirected by its
  shell prefix ([container README, Scope][ctr]), so Claude would be only
  partly sandboxed. Codex goes through `/codex` with `include_local = false`.
- **No record of the sandbox in the log.** Events do not say a turn was
  sandboxed, with which backend, mounts or proxy policy.

## Next steps

None planned. If a host harness needs its tools sandboxed again, start from
13f1542 and the gaps above.

[post]: https://blog.primeradiant.com/external-sandboxes-for-coding-agents/
[es]: https://github.com/prime-radiant-inc/external-sandbox
[proto]: https://github.com/prime-radiant-inc/external-sandbox/blob/main/PROTOCOL.md
[escodex]: https://github.com/prime-radiant-inc/external-sandbox/blob/main/codex/README.md
[v86]: https://github.com/prime-radiant-inc/external-sandbox-v86
[v86proxy]: https://github.com/prime-radiant-inc/external-sandbox-v86/blob/main/docs/proxy.md
[ctr]: https://github.com/prime-radiant-inc/external-sandbox-container
[espi]: https://github.com/prime-radiant-inc/external-sandbox-pi
[asa]: https://github.com/prime-radiant-inc/agent-session-archiver

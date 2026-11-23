# fleet

Spawn and steer Pi sessions on one Mac from any device on your tailnet,
such as your phone. Each turn runs Pi inside pi-container's locked VM on a
fresh clone of a repo you pick, and pushes the result to a `fleet/<session>`
branch. `fleetd` records every line Pi prints. Go standard library only.

Setup on a Mac, every step: [docs/macos.md](docs/macos.md).

## Words

| Word | Means |
|---|---|
| `pic serve` | How you start a node: checks the Mac, then runs `fleetd` and `tailscale serve` in the foreground. Ctrl-C stops both. |
| `fleetd` | The daemon: sessions, event logs, API and phone UI, on `127.0.0.1:7433`. |
| `pi-ctr` | The one harness: `pi-container/pi-ctr` runs one turn of Pi in the VM. `fleetd` starts it through its own `fleetd pi-ctr` subcommand. |
| session | A transcript (Pi's session file, checkpointed after each turn) plus, with a repo, the branch `fleet/<sid>`. |
| turn | One prompt, one Pi run, one push. One at a time per session. |
| node | One Mac running `pic serve`. Nodes don't talk to each other. |

## A turn

1. You send a prompt (spawn, or the session page). `fleetd` records it.
2. `fleetd` rebuilds the session's state folder from the last checkpoint
   and runs `pi-ctr`, which starts a fresh VM on the `pi-locked` network
   with only that folder mounted.
3. With a repo: the VM clones it and checks out `fleet/<sid>`, or on the
   first turn (and a fork's first turn) the session's base.
4. Pi runs on the transcript so far. Every line it prints is stored as is.
5. With a repo: everything is staged, the push guardrails run (no file over
   10 MiB, nothing that looks like a GitHub token), and the turn commits and
   pushes to `fleet/<sid>`.
6. Only Pi's session file and `agent.json` are kept and checkpointed. The VM,
   its disk and the clone are gone.

A failed Pi turn is still pushed, since its transcript is kept. An aborted
turn (abort, or `fleetd` stopping) gets SIGTERM, then SIGKILL after 3 s,
pushes nothing, and the session goes back to its last checkpoint.

## Spawn

| Field | Empty means |
|---|---|
| prompt | Create the session without a first turn. |
| repo (`OWNER/REPO`) | **Scratch: no clone, and anything Pi writes is gone after each turn.** Only the transcript survives. |
| branch | The repo's default branch. Fixed at spawn; later turns continue `fleet/<sid>`. |
| model (OpenRouter id) | `defaultModel` in the profile's `settings.json` (`thinkingmachines/inkling-2-small` when `pic` creates it). |

The UI fills in a title from the prompt and a fresh retry key.

## Security model

- **The turn is the sandbox.** Pi and every command it runs are inside
  pi-container's VM, on `pi-locked`, whose only way out is `pi-proxy`:
  GitHub and `openrouter.ai`. Pi has the placeholder key; the proxy adds the
  real one. `fleetd` never has the real key: `pic serve` refuses to start
  with it in the environment, `fleetd` drops it for the turn anyway, and
  `pi-ctr` refuses a real one.
- **The VM gets one writable folder:** the session's state folder
  (transcript and `agent.json`), plus read-only `settings.json` and the
  proxy's CA. Not `~/.fleet`, not other sessions, not your home.
- **A turn can reach only `pi-proxy`:** the egress lock blocks the Mac,
  Tailscale's resolver, the tailnet and the internet
  ([network boundary](../README.md#network-boundary)).
  `pi-container/test/fleet-isolation.sh` checks this from a turn's VM.
- **The GitHub token is in the VM,** so anything a turn runs can use it. Use
  a fine-grained token with the scope in
  [configuration.md](../pi-container/docs/configuration.md#host-env-file).
  Without Workflows permission GitHub refuses a push that changes `.github/workflows`. A public repo's
  `fleet/<sid>` branches are public.
- **Owners only.** `fleetd -owner` logins (`pic serve` uses yours) can do
  everything; anyone else gets 403. An owner can run anything a turn can, so
  add only people you would give a shell. A friend who wants agents runs
  their own node.
- **Identity is a header.** `tailscale serve` sets `Tailscale-User-Login`
  and strips any the client sent. `fleetd` listens on loopback only, so any
  process on the Mac can send the header and act as an owner. That is safe
  only because a turn's VM can't reach the Mac at all, or the tailnet
  ([docs/macos.md step 8](docs/macos.md#8-verify-before-relying-on-it)).
- **A web page can't reach it.** Requests must carry `Host` of the `-url`
  name or the listen address (`421` otherwise, so DNS rebinding fails) and
  POSTs must be `application/json` (`415` otherwise, so a cross-site form
  fails).
- **`~/.fleet` is private:** 0700 folders, 0600 files.

## API

Every route needs an owner's `Tailscale-User-Login`. Bodies are JSON.

| Route | Does |
| ----- | ---- |
| `GET /v1/node` | name, URL, caller, harnesses |
| `GET /v1/sessions` | every session, newest first, with token `usage` |
| `POST /v1/sessions` | `{key,prompt,repo,branch,model,title}` spawn; a repeated `key` returns the same session |
| `GET /v1/sessions/{sid}` | folded state: `running`, `run`, `repo`, `branch`, `base`, `commit`, ... |
| `GET /v1/sessions/{sid}/events?after=N` | raw lines (JSONL; live SSE with `Accept: text/event-stream`) |
| `POST /v1/sessions/{sid}/inputs` | `{key,text}` run one turn; 409 while a turn runs |
| `POST /v1/sessions/{sid}/abort` | stop the running turn |
| `POST /v1/sessions/{sid}/fork` | `{key}` new session from the last checkpoint and the last pushed commit |

Pi's own lines arrive as `out` events. `fleetd pi-ctr` adds one
`{"type":"fleet.turn_end"}` per turn (turn number, exit code, Pi's session
id, token `usage`, `first_output_ms` from process start, so including the VM
start, and `ms`), and `pi-ctr` one `{"type":"pi_ctr.push"}` with the commit
or the reason a push was refused.

## Event log

Each session is `~/.fleet/sessions/<sid>/events.jsonl`, one JSON event per
line: `seq`, `sid`, `node`, `run` (turn), `t`, `by`, `kind`, `key`, `data`.
Kinds: `created`, `input`, `out` (or `out.b64` for bytes that are not
UTF-8), `checkpoint` (state files by SHA-256, stored in `~/.fleet/blobs`),
`exited` (code, reason, pushed `commit`). `core` holds the rules as two pure
functions, `Decide` (command to event) and `Apply` (fold an event into
state); each rule has a test:

- **Durable before visible.** A line is fsynced before any reader sees it.
  A crash can only leave a torn last line, which is cut on load. A complete
  line that breaks the rules (for example from an older `fleetd`) leaves
  that session out: nothing is cut or written, the other sessions load, and
  the session list names it as unreadable with the reason.
- **Retries are free.** Spawn, input and fork carry a caller key; a repeated
  key returns the original result.
- **One turn at a time.** Another input before `exited` gets 409, never a
  queue.
- **No silent re-run.** A turn that dies with `fleetd` is recorded as
  `exited` ("node restarted") when it starts again; its input is not re-sent.
  The orphaned turn kills itself and its container (`fleet-<sid>`) once
  `fleetd` is gone, and the restart removes that container again before
  recording the exit.
- **Fork, never merge.** A fork is a new session; the parent is untouched.

## Tests

No container, network or key needed. Go is only for running them yourself;
`./build.sh fleet` runs them in a pinned Go image, so the Mac needs no Go.
From `fleet/`:

```sh
test -z "$(gofmt -l .)" && go vet ./... && go test -race ./...
bash e2e/pi-ctr.sh      # also needs git, jq and curl
```

| Test | Covers |
|---|---|
| `core` | Each rule; 200 seeds of random commands where `Decide` never yields an event `Apply` refuses, the fold equals the live state, and a seed replays byte for byte; repo, branch and commit validation. |
| `store` | The log cut at every byte reopens to its complete lines; a rejected line makes open fail and changes nothing. |
| `node` | Spawn, retries, owners only, fork, restart, busy input, abort (SIGTERM, then SIGKILL, whole process group, last checkpoint kept), shutdown in parallel, private file modes, the turn's environment, `Host` and `Content-Type` refusals, the result file. |
| `agent` | Pi's arguments and resume by file; refusing a missing, changed or new session file; failed model calls. **With `pi` installed** (or `FLEET_PI_BIN`), real Pi behind the real `pi-container/proxy.py` and a fake OpenRouter: resume from a copied state folder, no traffic but model calls, the key never in output or state, a wrong key fails the turn. Without `pi`, `python3` or `openssl` these skip. |
| `fakeor` | The fake OpenRouter itself. |
| `e2e/pi-ctr.sh` | Real `fleetd`, real `run.sh` and `pi-ctr`, a fake `container` and fake Pi, a local bare repo as GitHub: turns, branch and base, failed and aborted turns, every push guardrail, what the checkpoint keeps, forks, the real key never reaching a turn, owners only, `kill -9` of `fleetd` mid-turn and restart. |

CI runs all of the above with Pi installed. Opt-in, never in CI:
`FLEET_LIVE=1 OPENROUTER_API_KEY=... go test -run TestLive ./agent` runs two
real turns against OpenRouter through `proxy.py` (`FLEET_LIVE_MODEL`
overrides the model). On a Mac, `./build.sh fleet` runs the Go tests before
building; what runs where, and the checks only a Mac can do (the real VM,
network and phone):
[docs/macos.md, step 8](docs/macos.md#8-verify-before-relying-on-it).

## Not here

- **No replication or handoff.** Code travels through git (`fleet/<sid>`);
  each node keeps its own sessions.
- **One repo per session.** A turn clones exactly one.
- **Scratch sessions keep no files.** Use a repo to keep work.
- **No long-lived Pi, steering mid-turn, or input queue.** A turn is a
  process; that is what makes every turn a checkpoint.
- **No compaction of the event log;** loading is linear in its size.

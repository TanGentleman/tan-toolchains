# fleet

`fleetd` runs coding-agent sessions on a machine, records every byte the
agent prints, and lets any of your tailnet devices view, prompt, resume, or
fork a session no matter where it started. Go standard library only.

## Quick start

```sh
cd fleet && go build -o fleetd ./cmd/fleetd
./fleetd -name laptop -url https://laptop.your-tailnet.ts.net -owner you@github \
  -harness 'mine=/path/to/adapter'   # built in: pi-ctr
tailscale serve --bg 7433          # tailnet HTTPS + identity header -> fleetd
```

Open `https://laptop.your-tailnet.ts.net` on your phone. On a Mac, `pic serve` does all of this; every step: [docs/macos.md](docs/macos.md).

`fleetd` listens on loopback only and refuses anything else: it trusts the
`Tailscale-User-Login` header, which `tailscale serve` sets and strips from
clients. Without serve (e.g. `curl` on the box) you must send the header
yourself.

## Model

Five pieces. Everything else is an adapter.

| Piece | Package | What it is |
| ----- | ------- | ---------- |
| Event log | `core` | One append-only JSONL file per session. Each line: `seq`, `sid`, `node` (writer), `run` (turn), `kind`, `data`. |
| Rules | `core` | `Decide(state, cmd) -> event` and `Apply(state, event)`. Pure, no I/O; the whole protocol. |
| Store | `store` | Append = write + fsync, then visible. Torn tails are cut on open. Blobs by SHA-256. |
| Harness | `node` | One process per turn: prompt on stdin, lines on stdout, exit code. `$FLEET_STATE` is its state dir. |
| Node | `node` | Owns sessions it writes, copies others over HTTP, serves the API and UI. |

Rules the code enforces, each with a test:

- **One writer.** Only the node named in the latest `created`/`sealed`
  event appends. Copies check every line with `Apply`, so a replica can lag
  but never accept a line its writer could not have written.
- **Raw first.** Each stdout line is stored as-is (`out`, or `out.b64` for
  bytes that are not UTF-8). Parsing Pi/ACP/AG-UI messages is a reader's
  job, so schemas can change without migrating logs.
- **Durable before visible.** Readers and peers only see fsynced lines.
- **Retries are free.** Spawn, input, and fork carry a caller key; a
  repeated key returns the original result.
- **One turn at a time.** An input starts a turn; another input before its
  `exited` gets 409, never a queue.
- **Checkpoint every turn.** After each turn the node stores `$FLEET_STATE`
  as blobs (`checkpoint`), and rebuilds the directory from the latest
  checkpoint before the next one. A copy can always continue from the last
  finished turn it holds.
- **No silent re-run.** A turn that dies with its node is recorded as
  `exited` on restart; its input is never re-sent and its partial state is
  dropped. The same goes for an aborted turn, including one stopped by
  fleetd shutting down: it gets SIGTERM, 3 s later SIGKILL, and no checkpoint.
- **Seal or fork, never merge.** Resume asks the writer to abort any turn
  and append `sealed{to,url}` after checking `url` answers as `to`; the new
  writer copies the log and checkpoint. If the writer is unreachable, fork
  from the newest checkpoint you hold instead.
- **Default deny.** Owners and spawners are flags; everyone else needs a
  per-session share (`view`, `steer`, `admin`).

## What access means

Harnesses run as the user running `fleetd`, with no sandbox unless the
harness adds one. `pi-ctr` runs Pi in pi-container's VM; a custom
`-harness` runs on the Mac. So:

- **A `-spawner` can run any command as you** and spend your OpenRouter key:
  a `pi-ctr` turn can do anything inside its container and push to
  `fleet/<sid>`; a host harness such as `fleetd agent pi` can do anything.
- **A `steer` or `admin` share of a session is the same,** for that session:
  its next turn runs whatever they ask. `view` is read only, but shows every
  file and command output the agent saw.
- **Loopback is the credential.** `fleetd` believes `Tailscale-User-Login`
  on any request to its loopback port that passes the `Host` check. Any
  process on the machine can send one, including an agent in a host
  harness's turn, so such a turn can act as the owner: spawn, read or share
  any session. A `pi-ctr` turn's network is pi-locked, which is meant to
  stop it reaching the Mac's port 7433 (checked on a Mac in
  pi-container/E2E.md). Give spawners and `steer` only to people you would
  give a shell.

## API

All routes need `Tailscale-User-Login` and a `Host` of the `-url` host or the
`-listen` address (`421` otherwise), so a DNS-rebinding page can't reach
`fleetd`. POSTs need `Content-Type: application/json` (`415` otherwise), so a
cross-site form can't either.

| Route | Does |
| ----- | ---- |
| `GET /v1/node` | name, caller, harnesses |
| `GET /v1/sessions` | sessions the caller can see |
| `POST /v1/sessions` | `{harness,model,repo,branch,title,key,prompt}` spawn; `model` (optional) is stored in the log and passed to the harness as `$FLEET_SESSION_MODEL` on every node; `repo` (`OWNER/REPO`) and `branch` likewise as `$FLEET_REPO` and `$FLEET_BRANCH` |
| `GET /v1/sessions/{sid}` | folded state |
| `GET /v1/sessions/{sid}/events?after=N` | raw lines (JSONL; live SSE with `Accept: text/event-stream`) |
| `POST /v1/sessions/{sid}/inputs` | `{key,text}` run one turn; 409 while a turn runs |
| `POST /v1/sessions/{sid}/abort` | kill the running turn |
| `POST /v1/sessions/{sid}/seal` | `{to,url}` abort, hand off to the node at `url` |
| `POST /v1/sessions/{sid}/resume` | `{from}` become writer |
| `POST /v1/sessions/{sid}/fork` | `{key}` new session from the newest checkpoint |
| `POST /v1/sessions/{sid}/share` | `{user,level}` |
| `GET /v1/blobs/{sha}` | checkpoint file |

A harness is any command (`-harness 'name=cmd args'`). Each turn it gets
the prompt on stdin and `$FLEET_SID`, `$FLEET_STATE`, `$FLEET_WORK`
(working directory, not replicated) and `$FLEET_SESSION_MODEL`. A session
with a repo also gets `$FLEET_REPO`, `$FLEET_BRANCH`, `$FLEET_BASE` (the
commit to start from when `$FLEET_PUSH` doesn't exist yet), `$FLEET_PUSH`
(`fleet/<sid>`) and `$FLEET_RESULT`, a file where it may write
`{"commit","base","error"}`: the commit it pushed, the base it started from
on the first turn, and a one-line reason for a failed turn. fleetd records
them in `exited` and ignores a malformed file. All of that comes with
fleetd's environment without `OPENROUTER_API_KEY` unless `-harness-key name`
is set. Every other variable in fleetd's environment does reach it.
A custom name can't reuse the built-in `pi-ctr`.
It must keep
everything it needs for the next turn under `$FLEET_STATE`: that directory
is what checkpoints carry to the next node. Abort sends its process group
SIGTERM, then SIGKILL after 3 s.

## pi-ctr

The built-in harness. Each turn runs `fleetd agent pi-ctr`, which is Pi's
adapter (resume by session file, session-id checks, failed-turn detection,
usage) with `pi-container/pi-ctr` in place of the `pi` binary. `pi-ctr` runs
Pi through `run.sh --fleet-state $FLEET_STATE`, pi-container's normal mode:
`pi-locked` network, proxy, placeholder key, read-only `settings.json`.

- **Key.** `fleetd` drops `OPENROUTER_API_KEY` for this harness and the
  adapter passes the placeholder; `pi-ctr` refuses a real one. The proxy
  reads the key from pi-container's env file. `pic serve` refuses to start
  `fleetd` with the key in its environment.
- **State.** Only `$FLEET_STATE` is mounted, read-write at the same path.
  Pi's agent dir and the clone live on the VM's disk. After the turn,
  `pi-ctr` deletes everything in `$FLEET_STATE` except `agent.json` and
  `pi/sessions/*.jsonl`, so a checkpoint never carries an extension or a
  symlink.
- **Code.** See [macos.md step 7](docs/macos.md#7-spawn-from-the-phone):
  fresh clone, `fleet/<sid>` or the base, push guardrails, failed turns
  pushed, aborted ones not. `created` records `repo`, `branch`, `base` and
  `sandbox: pi-container`; each `exited` records the pushed `commit`. Usage
  stays in the adapter's `fleet.turn_end` line, which also has
  `first_output_ms` (process start to Pi's first line, so it includes the
  VM start) and `ms`.

## Pi, Claude Code, Codex on the host

These run on the host and are not registered by default; add one with
`-harness "pi=/path/to/fleetd agent pi" -harness-key pi` (likewise `claude`,
`codex`). Each runs `fleetd agent KIND` (package `agent`) once per turn, which runs the CLI in its
headless JSON mode, forwards every stdout line unchanged, and keeps the CLI's
whole home under `$FLEET_STATE`, so a checkpoint carries the conversation.

```sh
export OPENROUTER_API_KEY=sk-or-...           # stays on the node; scrubbed from output
export FLEET_MODEL=deepseek/deepseek-v4.1-flash    # or FLEET_PI_MODEL, FLEET_CLAUDE_MODEL, ...
./fleetd -name laptop -owner you@github ...   # then spawn with harness "claude"
```

| CLI | OpenRouter wiring | Resume |
|---|---|---|
| Pi | `--provider openrouter`, `OPENROUTER_API_KEY` | `--session <file>` (`--session-id` only matches the same cwd and otherwise starts fresh) |
| Claude Code | `ANTHROPIC_BASE_URL=https://openrouter.ai/api`, `ANTHROPIC_AUTH_TOKEN=$key`, `ANTHROPIC_API_KEY=` (OpenRouter's documented setup); all model slots set to the chosen model | `--session-id` then `--resume` |
| Codex | `model_providers.openrouter` in `$CODEX_HOME/config.toml`, `wire_api = "responses"`, `env_key = "OPENROUTER_API_KEY"` | `codex exec resume <thread>` |

Each turn ends with `{"type":"fleet.turn_end","usage":{"input","output"}}`,
the model tokens the CLI reported for that turn (Codex reports a running
thread total; the adapter subtracts the previous one, kept in `agent.json`).
`GET /v1/sessions` sums these per session as `usage`, rebuilt from the log on
every node. Tokens, not dollars: each CLI prices OpenRouter models from its
own table, so their cost fields are not trusted.

The adapter refuses to continue (exit 3) if the native session file is
missing or the CLI reports a different session id, instead of letting the
conversation restart from nothing.

**Telemetry is off.** Measured with a refusing proxy (`fakeor.Trap`): with
these settings the only traffic is model calls.

- All: `DO_NOT_TRACK=1`; the child gets an allowlisted environment (no host
  credentials) and `HOME` inside `$FLEET_STATE`.
- Pi: `PI_TELEMETRY=0`, `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1`,
  `enableInstallTelemetry: false`.
- Claude Code: `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY`,
  `DISABLE_ERROR_REPORTING`, `DISABLE_AUTOUPDATER`, `DISABLE_UPDATES`,
  `DISABLE_FEEDBACK_COMMAND`, `DISABLE_BUG_COMMAND`, feedback survey,
  feature flags, marketplace auto-install and terminal-title calls off;
  `skipWebFetchPreflight: true`.
- Codex: `analytics`, `feedback`, `otel` exporters, update check and history
  off; `features.plugins`, `remote_plugin`, `apps`, `memories` and bundled
  skills off. Without those features Codex contacts github.com,
  api.github.com and chatgpt.com at startup.

Tested with pi 1.6.0, Claude Code 2.1.330, Codex 0.171.0.

### Behind the pi-container proxy

The adapters run unchanged behind `pi-container/proxy.py`, so the node never
holds the real key. Give `fleetd` what `run.sh` gives Pi:

```sh
OPENROUTER_API_KEY=sk-or-v1-placeholder   # proxy.py swaps in the real key
HTTPS_PROXY=http://<proxy>:8888 HTTP_PROXY=http://<proxy>:8888
NO_PROXY=localhost,127.0.0.1,::1          # never openrouter.ai
SSL_CERT_FILE=/etc/pi-proxy-ca/ca.pem NODE_EXTRA_CA_CERTS=/etc/pi-proxy-ca/ca.pem
```

The adapter passes the proxy and CA variables through (Codex reads
`SSL_CERT_FILE` or `CODEX_CA_CERTIFICATE`) and sets `NODE_USE_ENV_PROXY=1`
so Pi's fetch uses the proxy. Model calls are the only traffic: the proxy
log shows no GitHub tunnels and no denials. `TestBehindV5Proxy` runs the real
`proxy.py` on loopback against `fakeor`, which accepts only the key the proxy
holds; `TestLiveBehindV5Proxy` does the same against openrouter.ai.

### Pi with its tools in a sandbox (archived)

The experimental `pi-sbx` harness (Pi on the host, its tools in an
external-sandbox-v86 guest) was removed once `pi-ctr` put Pi itself in a VM.
Findings: [docs/sandbox.md](docs/sandbox.md); code: commit 13f1542.

## Tests

```sh
gofmt -l . && go vet ./... && go test -race ./...
bash e2e/smoke.sh   # two real fleetd processes, kill -9 mid-turn, restart
bash e2e/pi-ctr.sh  # pi-ctr turns through real run.sh, a fake container and a local bare repo
```

- `core`: rules table, plus a seeded simulation of 3 nodes running random
  commands and copying logs at random (200 seeds x 600 steps), checking
  after every step that no two copies of a session disagree and that the
  same seed replays byte for byte.
- `store`: the log cut at every byte offset reopens to exactly its complete
  lines.
- `node`: two nodes over `httptest` with the in-process fake harness: spawn,
  retry, share, bogus seal refused, resume (harness state continues), dead
  writer -> fork from its last finished turn, restart; busy input, abort,
  exit codes; abort stops an `Exec` harness's whole process group, lets it
  handle SIGTERM, and keeps the last checkpoint.
- `e2e/smoke.sh`: the same with two real `fleetd` processes, including
  `kill -9` in the middle of a turn.
- `agent`: each real CLI against `fakeor`, a fake OpenRouter serving the
  Anthropic, chat-completions and responses formats. The reply lists every
  `TOK...` word in the request, so a resumed turn proves it carried the
  history. Covers resume in a new directory, a two-node fleet handoff, a
  deleted native session (must refuse), no non-model traffic, and the key
  never in output, logs or state. Skips a CLI that is not installed
  (`FLEET_PI_BIN` etc. or `PATH`).
- Live, not in CI: `FLEET_LIVE=1 OPENROUTER_API_KEY=... go test -run TestLive ./agent`
  runs each CLI against OpenRouter: turn 1 on one node, turn 2 on a copy
  must recall a codeword; nothing but openrouter.ai may be contacted.

## Not here, on purpose

- No database, broker, or Tailscale library. `tailscale serve` supplies TLS
  and identity; a node could sit behind any proxy that sets the header.
- No harness-specific parsing in the node, except summing the optional
  `fleet.turn_end` usage line. The Pi/Claude/Codex adapter is a command the
  node treats like any other.
- No long-lived harness process, steering mid-turn, or input queue. A turn
  is a process; that is what makes every turn a checkpoint.
- No automatic failover. Two writers would need consensus; seal-or-fork
  keeps one writer without it.
- No compaction or snapshots of the event log; fold cost is linear.

`core` is the part to port (e.g. to Zig): about 300 lines of state machine
with no dependencies, and the simulation test is its spec.

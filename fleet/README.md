# fleet

`fleetd` runs coding-agent sessions on a machine, records every byte the
agent prints, and lets any of your tailnet devices view, steer, resume, or
fork a session no matter where it started. Go standard library only.

## Quick start

```sh
cd fleet && go build -o fleetd ./cmd/fleetd
./fleetd -name laptop -url https://laptop.your-tailnet.ts.net -owner you@github \
  -harness 'mine=/path/to/adapter'   # built in: fake, pi, claude, codex
tailscale serve --bg 7433          # tailnet HTTPS + identity header -> fleetd
```

Open `https://laptop.your-tailnet.ts.net` on your phone. A second machine runs
its own `fleetd` with `-peer https://laptop...` to keep copies of every
session it can see.

`fleetd` listens on loopback only and refuses anything else: it trusts the
`Tailscale-User-Login` header, which `tailscale serve` sets and strips from
clients. Without serve (e.g. `curl` on the box) you must send the header
yourself.

## Model

Five pieces. Everything else is an adapter.

| Piece | Package | What it is |
| ----- | ------- | ---------- |
| Event log | `core` | One append-only JSONL file per session. Each line: `seq`, `sid`, `node` (writer), `run`, `kind`, `data`. |
| Rules | `core` | `Decide(state, cmd) -> event` and `Apply(state, event)`. Pure, no I/O; the whole protocol. |
| Store | `store` | Append = write + fsync, then visible. Torn tails are cut on open. Blobs by SHA-256. |
| Harness | `node` | A process that reads JSON lines on stdin and writes lines on stdout. `$FLEET_STATE` is its state dir. |
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
- **No silent re-run.** A run that dies with its node is recorded as
  `exited` on restart; its inputs are never re-sent.
- **Seal or fork, never merge.** Resume asks the writer to stop, checkpoint,
  and append `sealed{to}`; the new writer copies and continues. If the writer
  is unreachable, fork from the newest checkpoint you hold instead.
- **Default deny.** Owners and spawners are flags; everyone else needs a
  per-session share (`view`, `steer`, `admin`).

## API

All routes need `Tailscale-User-Login`. Bodies are JSON.

| Route | Does |
| ----- | ---- |
| `GET /v1/node` | name, caller, harnesses |
| `GET /v1/sessions` | sessions the caller can see |
| `POST /v1/sessions` | `{harness,model,title,key,prompt}` spawn; `model` (optional) is stored in the log and passed to the harness as `$FLEET_SESSION_MODEL` on every node |
| `GET /v1/sessions/{sid}` | folded state |
| `GET /v1/sessions/{sid}/events?after=N` | raw lines (JSONL, `wait=1` long-polls; SSE with `Accept: text/event-stream`) |
| `POST /v1/sessions/{sid}/inputs` | `{key,kind,text}`, kind `prompt`/`steer`/`abort` |
| `POST /v1/sessions/{sid}/seal` | `{to}` stop, checkpoint, hand off |
| `POST /v1/sessions/{sid}/resume` | `{from}` become writer and start |
| `POST /v1/sessions/{sid}/fork` | `{key}` new session from the newest checkpoint |
| `POST /v1/sessions/{sid}/share` | `{user,level}` |
| `GET /v1/blobs/{sha}` | checkpoint file |

Inputs reach the harness as `{"type":kind,"id":seq,"message":text}`, which
is Pi's RPC shape. Other harnesses get a small wrapper process.

A harness must keep everything it needs to continue under `$FLEET_STATE`:
that directory is what checkpoints carry to the next node.

## Pi, Claude Code, Codex

`fleetd` registers `pi`, `claude` and `codex` as harnesses. Each runs
`fleetd agent KIND` (package `agent`), which runs the CLI once per turn in its
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

## Tests

```sh
gofmt -l . && go vet ./... && go test -race ./...
bash e2e/smoke.sh   # two real fleetd processes, kill -9, restart
```

- `core`: rules table, plus a seeded simulation of 3 nodes running random
  commands and copying logs at random (200 seeds x 600 steps), checking
  after every step that no two copies of a session disagree and that the
  same seed replays byte for byte.
- `store`: the log cut at every byte offset reopens to exactly its complete
  lines.
- `node`: two nodes over `httptest` with the in-process fake harness: spawn,
  retry, share, resume (harness state continues), dead writer -> fork,
  restart -> interrupted run.
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
- No harness-specific parsing in the node. The Pi/Claude/Codex adapter is
  a stdin/stdout process the node treats like any other.
- No automatic failover. Two writers would need consensus; seal-or-fork
  keeps one writer without it.
- No compaction or snapshots of the event log; fold cost is linear.

`core` is the part to port (e.g. to Zig): about 300 lines of state machine
with no dependencies, and the simulation test is its spec.

# fleet

`fleetd` runs coding-agent sessions on a machine, records every byte the
agent prints, and lets any of your tailnet devices view, steer, resume, or
fork a session no matter where it started. Go standard library only.

## Quick start

```sh
cd fleet && go build -o fleetd ./cmd/fleetd
./fleetd -name laptop -url https://laptop.your-tailnet.ts.net -owner you@github \
  -harness 'mine=/path/to/adapter'   # the built-in `fake` harness is always there
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
| `POST /v1/sessions` | `{harness,title,key,prompt}` spawn |
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
that directory is what checkpoints carry to the next node. Real CLIs need
an adapter for this; Pi, Claude, and Codex resume silently start fresh when
their session file is not where (and named how) they expect. No real-CLI
adapter ships here yet.

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

## Not here, on purpose

- No database, broker, or Tailscale library. `tailscale serve` supplies TLS
  and identity; a node could sit behind any proxy that sets the header.
- No harness-specific parsing in the node. A Pi/Claude/Codex/ACP adapter is
  a stdin/stdout process.
- No automatic failover. Two writers would need consensus; seal-or-fork
  keeps one writer without it.
- No compaction or snapshots of the event log; fold cost is linear.

`core` is the part to port (e.g. to Zig): about 300 lines of state machine
with no dependencies, and the simulation test is its spec.

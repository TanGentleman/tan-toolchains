# fleet implementation

## Model

- **Node:** a machine running `fleetd`. Laptop, friend's machine, or cloud box;
  all run the same binary.
- **Runner/harness:** how a node runs an agent. `fake` (deterministic, no key)
  and `pi` (`pi --mode rpc`) exist today. A container or cloud sandbox is a
  runner under a node, not a node.
- **Session:** an append-only event log with exactly one writer node at a time.
- **Run:** one harness process lifetime inside a session. A session moves
  between nodes by ending one run and starting the next on another node.

## Invariants

These are what the tests lock in; dependencies may change underneath them.

1. One writer per session. Only the node named by the last `run.started` (or
   the `sealed_to` target of a sealed run) appends. Replicas copy lines
   verbatim and reject any line that differs from what they hold.
2. Raw first. Harness stdout is appended to `raw-<run>.log` and fsynced before
   the event that points at it. Normalized events are a projection.
3. Durable before visible. Readers, peers, and SSE only see fsynced events, and
   a request returns only after its event is fsynced.
4. Retry-safe inputs. Spawn, fork, and inputs carry a client key. Dedupe uses
   `(kind, principal, key)` stored in the log itself, so it survives restarts
   and replication.
5. No silent retry of unknown effects. If a node restarts mid-turn it appends
   `run.interrupted` listing inputs and tool calls whose outcome is unknown.
   Nothing re-sends them.
6. Seal or fork, never merge. Handoff asks the writer to seal to the target.
   If the writer is unreachable you fork a new session from the latest
   checkpoint you hold; the old one is untouched.
7. Default deny. Every request is identified (tailnet WhoIs) and must pass
   both the tailnet capability ceiling and the session's shares.
8. Keys stay home. Model credentials live in the node's harness environment;
   nothing in the log or API carries them.

## Layout

| Path | Role |
| ---- | ---- |
| `internal/journal` | JSONL log + raw log per session, fsync batching, torn-tail repair, dedupe, replica append |
| `internal/authz` | `Principal`, `Cap`, `Decide`; no Tailscale types |
| `internal/tailnet` | the only Tailscale import: tsnet listener, WhoIs → `Principal`, tsnet HTTP client for peers |
| `internal/harness` | `Harness`/`Proc` contract, `fake`, `pi` |
| `internal/node` | sessions, runs, checkpoints, peers (pull replication, relay), HTTP API, phone UI |
| `cmd/fleetd` | flags and wiring |

On disk under `-data` (default `~/.fleet`):

```
sessions/<sid>/events.jsonl   one event per line, seq 1..N
sessions/<sid>/raw-<run>.log  exact harness stdout for that run
sessions/<sid>/native/        harness files (e.g. pi.jsonl) of the current run
sessions/<sid>/work/          harness working directory (not replicated)
blobs/<sha256>                checkpointed native files
```

## Events

Each line: `{"v":1,"sid","seq","run","node","t","by","kind","key","data","raw":{"run","off","len"}}`.

| Kind | Meaning |
| ---- | ------- |
| `session.created` | owner, harness, title, optional `forked_from`/`forked_at` |
| `run.started` | node that now writes |
| `input` | `prompt`, `steer`, or `cancel` with its client key |
| `turn.start`, `turn.end` | harness turn boundaries |
| `message`, `tool.call`, `tool.result` | normalized harness output |
| `harness.raw` | raw bytes with no normalized event |
| `checkpoint` | native files as `{name, sha, size}`, written after each turn and on seal |
| `run.interrupted` | run ended unexpectedly; `unknown` lists unresolved inputs/tool calls |
| `run.sealed` | run ended for handoff; `to` names the next writer |
| `share` | `{user, level}` with level `view`, `steer`, or `admin` |

## API

All routes need a tailnet identity. Node-to-node calls use the node's own
identity (`tag:fleet`, archive capability); a relay names the original caller
in `X-Fleet-As`, which is only honored from archive-capable peers.

| Route | |
| ----- | - |
| `GET /` | phone UI |
| `GET /v1/node` | node name, peers, and who you are |
| `GET /v1/sessions` | sessions you may read |
| `POST /v1/sessions` | `{harness, title, key, prompt}`; same key returns the same session |
| `GET /v1/sessions/{sid}` | folded metadata |
| `GET /v1/sessions/{sid}/events?after=N` | JSONL, or SSE with `Accept: text/event-stream` / `Last-Event-ID` |
| `GET /v1/sessions/{sid}/raw/{run}?off=N` | raw bytes up to the durable length |
| `POST /v1/sessions/{sid}/inputs` | `{key, kind, text}`; relayed to the writer if this node is a replica |
| `POST /v1/sessions/{sid}/seal` | `{to}`; writer ends its run for handoff |
| `POST /v1/sessions/{sid}/resume` | make this node the writer (seals the old writer first) |
| `POST /v1/sessions/{sid}/fork` | `{key}`; new session from the latest local checkpoint |
| `POST /v1/sessions/{sid}/share` | `{user, level}` |
| `GET /v1/blobs/{sha}` | checkpoint file |

A relay to an unreachable writer fails with 503; the UI then offers fork.

## Replication

Nodes listed with `-peer` are pulled every few seconds: session list, then
`events?after=<our head>`, then raw bytes and checkpoint blobs. Pull only, so
an archive box needs no credentials on other nodes and laptops never push.

## Tailnet policy

Tailscale grants set the ceiling; session shares narrow it. Example for a
Tailscale SaaS tailnet (Headscale version: `e2e/hs/policy.hujson`):

```hujson
"tagOwners": { "tag:fleet": ["autogroup:admin"] },
"grants": [
  { "src": ["autogroup:member", "tag:fleet"], "dst": ["tag:fleet"], "ip": ["tcp:7433"] },
  { "src": ["you@github"], "dst": ["tag:fleet"],
    "app": { "github.com/TanGentleman/cap/fleet": [{ "role": "owner", "read": "all", "spawn": true }] } },
  { "src": ["friend@github"], "dst": ["tag:fleet"],
    "app": { "github.com/TanGentleman/cap/fleet": [{ "role": "friend", "read": "own", "spawn": true, "slots": 2, "runners": ["fake", "pi"] }] } },
  { "src": ["tag:fleet"], "dst": ["tag:fleet"],
    "app": { "github.com/TanGentleman/cap/fleet": [{ "archive": true }] } },
]
```

Register each node with a `tag:fleet` auth key (`TS_AUTHKEY=... fleetd -tsnet ...`)
so peers see it as a node, not as you. Users are keyed by stable tailnet user
ID, not login string. Funnel traffic carries no identity and is denied.

`-host-tailscale` uses the machine's own `tailscaled` instead of tsnet.
`-dev-policy` trusts an `X-Fleet-User` header and refuses non-loopback
addresses; it exists for `e2e/smoke.sh`.

## Pi

`-pi` is the command, `-pi-args` extra flags, `-pi-env KEY=VALUE` its
environment (for example `HOME` of a profile holding the key). The adapter
checks that a resumed Pi session actually loaded its history, because some
resume paths silently start fresh. `e2e/smoke.sh` runs Pi when `PI` is set
and expects a model that answers `TOOL` and `RECALL`; the CI job uses only the
fake harness.

## Tests

| Check | Covers |
| ----- | ------ |
| `go test -race ./...` | journal durability/dedupe/torn tail/replica divergence; authz matrix; two-node integration (handoff, relay, SSE, fork, restart) |
| `e2e/smoke.sh` | real processes: kill -9 writer, 503 relay, fork while down, restart → outcome-unknown, byte-equal replicas |
| `e2e/tailnet.sh` | Headscale + tsnet containers: WhoIs roles, shares, LAN rejection, laptop → server handoff over the tailnet |

## Limits

- Only native harness files move on handoff. The working directory does not;
  a resumed Pi session sees its history but not files written on the old node.
- Not run on macOS yet: fsync semantics (`F_FULLFSYNC`), laptop sleep, and
  Apple `container` runners are untested.
- Not tried on a Tailscale SaaS tailnet or a real phone; only Headscale.
- No SQLite index: listing folds every log at startup.
- No ACP adapter, Slack ingress, or Convex catalog yet.

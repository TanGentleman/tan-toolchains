# Modal scratchpad

Notes from the "spawn jobs through an authenticated API instead of keeping my
laptop running" discussion. Not a plan of record, and not a promise that the
current scaffold works there.

## The reframing

Modal is not a host for `run.sh`; Modal **is** the container runtime. `run.sh`
orchestrates Apple's macOS-only `container` CLI: named volumes with labels, a
host-only `pi-locked` network, a separate `pi-proxy` container, `inspect` JSON,
and host bind mounts. None of that exists on Modal.

So "deploy this scaffold" really means: write a second driver against Modal's
primitives. The bash scaffold stays the local driver and the behavioural
reference; `pi-container/ASSUMPTIONS.md` plus the fixtures and integration tests
are the contract the Modal driver has to reproduce.

## What carries over

- The agent image (`pi-container/Dockerfile`), with an architecture caveat.
- The secret split: the agent sees `sk-or-v1-placeholder`, the proxy holds the
  real OpenRouter key, and the GitHub token only reaches Pi.
- `settings.json` mounted read-only so Pi cannot persist preference changes.
- Per-instance agent state, per-profile clone volumes, session backups.
- The mount/repo allowlist idea, even if the mechanism differs.

## What does not carry over

- The `container` CLI and every `lib/inspect.sh` parser. Modal's SDK returns
  typed objects, so the JSON-shape work simply disappears on that path.
- The host-only `pi-locked` network and the separate proxy container. Modal has
  its own networking model.
- Host bind mounts (`$PWD:$PWD`) and live host edits.
- The mkdir + pid host lock.
- The interactive TUI, unless a PTY/websocket bridge is built separately.

## Architecture sketch (batch jobs)

One sandbox per job, behind a small FastAPI app:

- `POST /jobs` with a JSON spec (repo, ref, prompt/command, model, instance).
  Return a job id immediately.
- The handler creates a `modal.Sandbox` from the agent image with:
  - a Modal Volume for the repo/checkout (or clone inside the sandbox),
  - a Modal Volume for agent state (sessions, `auth.json`),
  - Modal Secrets injected only into the process that needs them,
  - the placeholder OpenRouter key for the agent,
  - a read-only settings file baked into the image or mounted from a volume.
- Start the proxy as a background process in the same sandbox, then run
  `pi -p "..."`. Stream stdout/stderr to a log volume or `modal.Queue`.
- `GET /jobs/{id}` for status/logs; `DELETE /jobs/{id}` terminates the sandbox.
- Auth: `requires_proxy_auth=True` at minimum; add a per-user bearer check in
  the handler if jobs need per-tenant scoping.

This is additive. Local `pic` stays the interactive path; Modal is for "submit
work, get logs/results".

## Prerequisites and risks

- **Architecture.** The Dockerfile hard-fails unless `uname -m` is `aarch64` and
  downloads arm64 Zig/Neovim/ZLS. Confirm the plan's Modal sandboxes are arm64;
  otherwise generalize the Dockerfile to x86_64 artifact names.
- **Egress.** The host-only network guarantee does not translate. An in-sandbox
  proxy still relies on the agent honouring `HTTP(S)_PROXY`; a raw-socket agent
  could bypass it. Decide this before real keys enter the picture.
- **Volumes.** Modal Volumes have writer/concurrency semantics. One agent
  volume per instance and one clone volume per job is the natural mapping, but
  jobs sharing a volume must serialize or be rejected.
- **Cold start and cost.** The image is large (Zig, Neovim, gh, Pi). Measure
  `Sandbox.create` time and per-job cost before committing to the design. A
  slimmer runner image or a warm pool may be necessary.
- **Headless Pi.** The current UX is a TUI. Batch mode needs `pi -p` and a
  streaming log story; interactive over Modal is separate work.

## Spike order

1. Build the image for Modal's arm64 (or generalize the Dockerfile) and start
   one sandbox by hand.
2. Mount one Modal Volume and inject one Secret; run `pi -p "..."` against a
   cloned repo.
3. Measure cold start, wall time, and cost. This answers the go/no-go question.
4. Reproduce the two security properties in the sandbox: placeholder key for
   the agent, read-only settings.
5. Only then write the endpoint and job-status surface.

## Open questions

- Per-user auth, or is Modal proxy auth enough?
- Batch only, or is an interactive terminal required?
- Session backups: Modal Volume, or S3/R2 object storage?
- Keep the proxy in-sandbox (weaker isolation, simpler) or invest in real
  egress enforcement?

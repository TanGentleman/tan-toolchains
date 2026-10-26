# enforcer

A small prompt gate for Pi. One static binary, one substring rule, no network.

`enforcer on` installs a Pi input hook at
`$PI_CODING_AGENT_DIR/extensions/enforcer.ts`. The hook sends each submitted
prompt to `enforcer hook`. A blocking verdict exits 2, Pi shows the reason, and
the prompt is not sent.

```sh
enforcer on       # register the Pi input hook
enforcer off      # remove it
enforcer hook     # run as the hook: read stdin, exit 2 to block
enforcer --help
```

The image ships `enforcer` disabled. To enable it in a normal Pi container:

```sh
./run.sh bash
enforcer on
exit
./run.sh
```

The extension lives in the instance's agent volume, so it survives restarts and
is removed with `enforcer off`.

## Policy

One case-sensitive check for the GitHub classic-token prefix `ghp_`. A prompt
containing it is blocked; `GHP_` and `github_pat_` are not matched. Keep the rule
small on purpose: it is a speed bump against accidental token pastes, not a
secret scanner.

`enforcer hook` reads at most 256 KiB from stdin. It accepts
`{"prompt":"..."}` or any JSON object with a string `prompt`; anything else is
treated as the raw prompt text. stdout is always empty; a block reason goes to
stderr.

Exit codes:

| Code | `on` / `off` | `hook` |
| --- | --- | --- |
| 0 | done or already in that state | allow |
| 1 | bad usage, IO error, no agent | internal error, fail open |
| 2 | - | blocked |

## What `on` writes

Pi is the only implemented agent. `enforcer on` writes
`extensions/enforcer.ts` under `$PI_CODING_AGENT_DIR` (default
`~/.pi/agent`). It creates `extensions/` only when the Pi agent directory
already exists; it never bootstraps an agent.

The generated shim calls `spawnSync` with a 5 second timeout and passes
`{"prompt": event.text}`. It consumes the prompt on exit 2 and continues
otherwise. Regenerating is idempotent, and `off` deletes the file only when its
first line is the generated header.

Claude is detected but not implemented here; `enforcer on` points at
[TanGentleman/enforcer](https://github.com/TanGentleman/enforcer) instead. This
rewrite focuses on Pi.

## Safety

- One write path: an atomic temp file, fsync, rename, then a re-read check.
- A lock file (`.enforcer.lock`) is held across read, write, and verification.
  It stays behind by design.
- Existing file modes survive replacement. Symlinked targets and a symlinked
  `extensions/` directory are refused.
- A no-op does not touch the file, so `on` twice leaves the mtime alone.
- The binary makes no network requests.

Environment variables:

| Variable | Effect |
| --- | --- |
| `PI_CODING_AGENT_DIR` | Pi agent directory; default `$HOME/.pi/agent`. |
| `ENFORCER_HOME` | Override `$HOME` for tests and unusual layouts. |
| `ENFORCER_SELF` | Path written into the shim; defaults to the running binary. |

## Build and test

```sh
cd enforcer
zig build test          # unit and CLI tests
zig build check         # zig fmt --check plus tests
zig build --release=small
bash test/pi-integration.sh ./zig-out/bin/enforcer   # needs pi on PATH
```

The integration script installs the hook with `enforcer on`, then runs the real
`pi -p` headless with an empty environment. It asserts a `ghp_` prompt is
consumed before the missing-auth check, a clean prompt reaches that check, and
`enforcer off` restores the old behavior. CI runs it against the Pi version in
`pi-container/Dockerfile`.

The Pi container builds the aarch64 static binary from this directory. There is
no checked-in binary.

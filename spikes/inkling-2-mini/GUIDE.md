# Guide: Inkling 2 Mini in a Pi container

Pi runs in its normal sandbox (locked network, `pi-proxy` as the only way
out) with `PI_EGRESS=offline`: `pi-proxy` forwards model calls only to this
Mac, refuses openrouter.ai and GitHub, and Pi gets no GitHub token. For GitHub
access with the local model, use `PI_EGRESS=normal $S/pi.sh`.

```
Pi VM (pi-locked) -> pi-proxy -> 192.168.64.1:8090 gateway.py -> 127.0.0.1:8091 mlx_lm.server
```

No image rebuild is needed. `run.sh` recreates `pi-proxy` by itself when the
upstream or the egress mode changes, and back again when you stop using `pi.sh`.

Run everything from the repo root. `$S` is short for the spike folder:

```sh
S=spikes/inkling-2-mini
```

## 0. Once

- [uv](https://docs.astral.sh/uv/), Apple `container` (`container system start`), `jq`.
- pi-container already works: `pi-container/run.sh check` passes. If the
  images are missing: `pi-container/build.sh` (Pi) — the proxy image builds on
  first run.
- `OPENROUTER_API_KEY` stays set in Pi's env file. `run.sh` still requires it,
  and `pi-proxy` still sends it, but no request goes to openrouter.ai.

## 1. Install and download (asks first)

```sh
$S/inkling install
```

Answer `y` at the prompt to download 17.3 GB from huggingface.co
(`mlx-community/Inkling-2-Mini-4bit`). The repo is public; a token only
raises rate limits. `export HF_TOKEN=...` first, or an existing `hf auth login`
token is used. Nothing else in these scripts contacts Hugging Face; serving
runs offline.

## 2. Serve

```sh
$S/inkling up pi       # background; returns once the model is loaded
$S/inkling serve pi    # or: foreground in a terminal of its own; Ctrl-C stops it
```

Listens on `127.0.0.1:8090` and on the container network's host address
(`192.168.64.1:8090`, read from `container network inspect default`), not on
your LAN. macOS adds that address only while a container runs, so the gateway
waits for it and binds when `pi.sh` starts `pi-proxy`. If macOS asks whether
Python may accept incoming connections, allow it. `up` waits up to
`INKLING_UP_TIMEOUT` (600 s) for the model to load
(`$HOME/.local/share/inkling-2-mini/logs/mlx.log`); `up` again is a no-op
while it runs. `serve.sh` refuses to start a second server.

```sh
$S/inkling status          # state, pid, port, batching, uptime
$S/inkling status --json   # the same for scripts; exits 0 in every state
```

`state` is `up`, `loading`, `down`, or `orphaned` (`serve.sh` was killed
but `mlx_lm.server` or the gateway still runs; `inkling down` stops them).
The JSON keys are `v` (1), `state`, `pid` (`serve.sh`, or the leftover
process), `port`, `pi`, `uptime_s`, `batch` (from `run/serve.json`), `home`
and `log`. The pid files in `run/` hold each process's start time, so a pid
the OS has since given to another process is ignored, never killed.

`$S/inkling down` stops the server either way and returns after
`mlx_lm.server` has exited, so the model is out of memory. A server that has
not exited after `INKLING_DOWN_TIMEOUT` (60 s) gets KILL. `down` again is a
no-op.

## 3. Check

```sh
$S/inkling check    # host -> gateway -> model: one tool call, one stream
$S/pi.sh check      # mode offline; OpenRouter line passes via the gateway, GitHub refused
```

## 4. Use Pi

`pi.sh` takes the same arguments as `pi-container/run.sh`:

```sh
$S/pi.sh                         # interactive Pi on the current folder
$S/pi.sh pi -p "list the files here"   # Pi's own flags go after `pi`
```

Pi still asks for its configured model (`inkling-2-small` by default). The
gateway ignores the name and answers with Inkling 2 Mini.

## 5. Evals

```sh
$S/eval.sh                       # every task in $S/evals/
$S/eval.sh $S/evals/fix-add.json
```

For each task, Pi (`pi --mode json -p`) works in a fresh folder,
`$HOME/.local/share/inkling-2-mini/evals/<time>-<id>/work`, that holds only
the task's files. Then `eval.py` reads the files Pi left and checks them. It
never runs anything Pi wrote. Each run folder also holds `pi.jsonl` (Pi's
events), `pi.log` and `result.json`. Exit status 0 means every task passed.

Model calls go only to this Mac. `pi-proxy` still tunnels GitHub, but the
tasks don't need it.

`--jobs N` (1 to 8) runs up to N tasks at once. Each running task has its
own Pi container (`pi.sh --instance eval-1` .. `eval-N`, 2 GB each unless
`PI_MEMORY` is set) and its own run folder. A task's `requests` in
`result.json` are the gateway log lines with its Pi session id (Pi sends it
as `x-session-id`; the gateway logs it as `session`). If Pi's output has no
session id, the task counts its time window, and counts nothing when another
task ran at the same time. Set `INKLING_DECODE_CONCURRENCY` to at least N
(see Memory), or requests above that wait at the model.

```sh
$S/eval.sh --jobs 2
```

Task files and `result.json` carry `"v": 1`. `eval.py` refuses unknown keys,
other versions, and paths that are absolute or contain `..`. It reads no file
through a symlink. Check types: `file_equals` (ignores surrounding
whitespace), `file_contains`, `file_matches` (regex, multiline),
`file_unchanged` (same as the seeded file).

## 5b. Benchmark

`bench.sh` runs the eval set (twice per level, `--repeat`) at `--jobs 1`,
then 2, then 4, against the `serve.sh` that is running. For each level it
prints tasks/hour, prompt, output and total tokens, and the median time to
first token (p50 TTFT) of that level's requests. It writes everything to
`$HOME/.local/share/inkling-2-mini/bench/<time>/` (`bench.json`, `"v": 1`,
and the run folders under `jobs-N/`). Levels above serve.sh's decode
concurrency only queue at the model, so start the server for the highest level:

```sh
INKLING_DECODE_CONCURRENCY=4 $S/inkling up pi
$S/bench.sh                                     # or --jobs 1,2 --repeat 1
```

Pick the level with the most tasks/hour that does not swap (watch Activity
Monitor's memory pressure), then use it for `INKLING_DECODE_CONCURRENCY` and
`eval.sh --jobs`.

## 6. Back to OpenRouter

`$S/inkling down` (or Ctrl-C on `inkling serve`) and run plain `pi-container/run.sh`. It sees the
upstream is gone and recreates `pi-proxy` pointing at openrouter.ai.

## 7. Uninstall

```sh
$S/inkling uninstall             # stops the server; --keep-model keeps the 17.3 GB of weights
```

Then run `pi-container/run.sh check` once so the proxy points at OpenRouter
again.

## Memory

`serve.sh` reads these when it starts (`inkling down`, then `inkling up pi`
to change them):

| Variable | Default | `mlx_lm.server` flag |
|---|---|---|
| `INKLING_DECODE_CONCURRENCY` | 2 | `--decode-concurrency`: requests decoded as one batch |
| `INKLING_PROMPT_CONCURRENCY` | 1 | `--prompt-concurrency`: prompts prefilled as one batch |
| `INKLING_PROMPT_CACHE_SIZE` | 4 | `--prompt-cache-size`: cached prompts kept |
| `INKLING_PROMPT_CACHE_GB` | 4 | `--prompt-cache-bytes`: cap for the cache and the active batch |

Defaults for a 30 GB Mac: 17.3 GB of weights, up to 4 GB of prompt cache and
batch, two eval VMs at 2 GB, 1 GB for the proxy: about 26 GB, which leaves
some for macOS. Two decodes at once cost little memory beyond the cache cap,
and keep two tasks moving. Prefill stays at 1: a batched prefill holds two
long prompts in memory at once, and it is not measured yet (try
`INKLING_PROMPT_CONCURRENCY=2` with `bench.sh`). Four cache entries hold
two prompts for each of two Pi sessions, so the next turn of each only
prefills its new messages.

At `--jobs 4` the VMs alone take 8 GB (about 30 GB in all); use
`PI_MEMORY=1G` if the Mac swaps. Interactive `pi.sh` keeps its 4 GB VM:
`PI_MEMORY=2G $S/pi.sh` if the Mac swaps.

## Try it with a small model first

Any local MLX folder works in place of Inkling, with no download:

```sh
export INKLING_MODEL_DIR=$HOME/.models/lm-studio/lmstudio-community/LFM2.5-1.2B-Instruct-MLX-8bit
$S/inkling up pi
```

## Security notes

- The gateway listens only on loopback and the container network's host
  address, not on your LAN. Containers on the default network can reach it;
  it serves only the model.
- Offline, `pi-proxy` sends the placeholder key, so your OpenRouter key never
  leaves the proxy. With `PI_EGRESS=normal` it adds the real key, which then
  goes to the gateway over the host-only bridge; the gateway does not read or
  log it.
- Request logs hold timings and token counts, not prompts or replies.

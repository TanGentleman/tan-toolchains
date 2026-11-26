# Guide: a local model for Pi in a container

```
Pi VM -> pi-proxy (--egress offline) -> gateway:8090 gateway.py -> 127.0.0.1:8091 backend (mlx_lm.server)
```

With `--egress offline`, `pi-proxy` sends model calls only to `--model-url`,
refuses GitHub and openrouter.ai, and Pi gets no GitHub token. `gateway` is
the Mac's address on the container network (e.g. 192.168.64.1); `run.sh`
resolves it. Run everything from the repo root, with `S=spikes/local-model`.

## 0. Once

- [uv](https://docs.astral.sh/uv/), `jq`, Apple `container` (`container system start`).
- `pi-container/run.sh check` passes. The eval uses the `min` image:
  `pi-container/build.sh agent-min` builds it if missing.

### Migrate weights from the old `inkling-2-mini` spike (no 17 GB download)

```sh
mkdir -p ~/.local/share/local-model/models
mv ~/.local/share/inkling-2-mini/model ~/.local/share/local-model/models/inkling-2-mini
rm -rf ~/.local/share/inkling-2-mini   # the old venv, caches and logs
```

The folder keeps its `.complete` file (the pinned revision), so `install`
sees the weights and skips the download.

## 1. Install

```sh
$S/model install
```

Runs `uv sync`, then shows the `hf download` command and asks before running
it. The weights repo is public; `HF_TOKEN` or an existing `hf auth login`
token only raises rate limits. Serving never contacts Hugging Face.

## 2. Serve

```sh
$S/model up --containers      # background; returns once the model is loaded (up to 600 s)
$S/model serve --containers   # or: foreground in a second terminal; Ctrl-C stops it
```

Without `--containers` it listens only on `127.0.0.1:8090`. With it, also on
the container network's host address (not your LAN); macOS adds that address
only while a container runs, so the gateway waits for it. If macOS asks
whether Python may accept incoming connections, allow it. `up` again is a
no-op; `up --containers` refuses while a loopback-only server runs (`down` first).

```sh
$S/model status          # model_url line has the run.sh command to use
$S/model status --json   # {"v": 1, "state", "pid", "model", "backend", "url", "model_url", ...}
```

`state` is `up`, `loading`, `down` or `orphaned` (the `serve` process died but
the backend or gateway still runs; `down` stops them). `model_url` is
`http://gateway:8090` when serving for containers, else null. Pid files in
`run/` hold each process's start time, so a pid the OS reused is never killed.

`$S/model down` returns after the backend has exited, so the model is out of
memory; after 60 s it sends KILL. `down` again is a no-op.

## 3. Check and use Pi

```sh
$S/model check                                                     # host -> gateway -> model
pi-container/run.sh --egress offline --model-url http://gateway:8090 check
pi-container/run.sh --egress offline --model-url http://gateway:8090 pi -p "list the files here"
```

Pi still asks for its configured model name; the gateway answers with the
served model. To make it the default, set `"egress": "offline"` and
`"model_url": "http://gateway:8090"` in `$PI_CONFIG_DIR/config.json`.

## 4. Evals

```sh
$S/eval.sh                        # every task in $S/evals/, one at a time
$S/eval.sh $S/evals/fix-add.json
```

Needs `model up --containers`. Each task runs
`pi-container/run.sh --egress offline --model-url http://gateway:8090 --image min --instance eval pi --mode json -p ...`
in a fresh folder, `~/.local/share/local-model/evals/<time>-<id>/work`, that
holds only the task's files; then `eval.py` checks the files Pi left. It never
runs anything Pi wrote. Each run folder has `pi.jsonl`, `pi.log` and
`result.json`; `requests` there are the gateway log lines with Pi's session id.
Exit status 0 means every task passed.

Task files and `result.json` carry `"v": 1`. `eval.py` refuses unknown keys,
other versions, and paths that are absolute or contain `..`, and reads no file
through a symlink. Checks: `file_equals` (ignores surrounding whitespace),
`file_contains`, `file_matches` (regex, multiline), `file_unchanged`.

## 5. Models

`models/<name>.json` says what to serve; `config.py` refuses anything else:

```json
{"v": 1, "backend": "mlx-lm", "parser": "inkling",
 "weights": {"repo": "ORG/NAME", "revision": "<40-hex commit>", "exclude": ["GLOB"]},
 "server_args": ["--temp", "1.0"]}
```

- `backend`: `mlx-lm` (Apple silicon). Another backend (llama.cpp, vLLM) is
  another class in `config.py`'s `BACKENDS`.
- `server_args` go to the backend as they are, after the flags the CLI owns
  (`--model`, `--host`, `--port`). Edit them here, then `down` and `up`.
- `parser`: `inkling` translates Inkling's markup; `none` passes replies through.

With more than one model file, pick one in `~/.config/local-model/config.json`:
`{"v": 1, "model": "<name>"}`. `install` downloads its weights to
`models/<name>/`.

Environment: `LOCAL_MODEL_HOME` (default `~/.local/share/local-model`),
`LOCAL_MODEL_PORT` (gateway, 8090), `LOCAL_MODEL_BACKEND_PORT` (loopback, 8091).
Pi's `--model-url` must use the same port as `LOCAL_MODEL_PORT`.

## 6. Uninstall

```sh
$S/model uninstall               # stops the server; --keep-model keeps the weights
```

It deletes only what `install` made (venv, Python, caches, logs, run, evals,
models) and refuses a folder without its `.local-model-spike` marker.

## Security notes

- The gateway listens on loopback and, with `--containers`, the container
  network's host address, not your LAN. It serves only the model.
- Offline, `pi-proxy` sends a placeholder key; the gateway reads and logs no key.
- Request logs hold timings and token counts, not prompts or replies.

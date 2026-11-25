# Guide: Inkling 2 Mini in a Pi container

Pi runs in its normal sandbox (locked network, `pi-proxy` as the only way
out). The only change: `pi-proxy` forwards model calls to this Mac instead of
openrouter.ai. GitHub still goes through the proxy as usual.

```
Pi VM (pi-locked) -> pi-proxy -> 192.168.64.1:8090 gateway.py -> 127.0.0.1:8091 mlx_lm.server
```

No image rebuild is needed. `run.sh` recreates `pi-proxy` by itself when the
upstream changes, and back again when you stop using `pi.sh`.

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
$S/install.sh
```

Answer `y` at the prompt to download 17.3 GB from huggingface.co
(`mlx-community/Inkling-2-Mini-4bit`). The repo is public; a token only
raises rate limits. `export HF_TOKEN=...` first, or an existing `hf auth login`
token is used. Nothing else in these scripts contacts Hugging Face; serving
runs offline.

## 2. Serve (terminal 1)

```sh
$S/serve.sh pi
```

Listens on `127.0.0.1:8090` and on the container network's host address
(`192.168.64.1:8090`, read from `container network inspect default`), not on
your LAN. macOS adds that address only while a container runs, so the gateway
waits for it and binds when `pi.sh` starts `pi-proxy`. If macOS asks whether
Python may accept incoming connections, allow it. Wait for the
model to load (`$HOME/.local/share/inkling-2-mini/logs/mlx.log`).

## 3. Check (terminal 2)

```sh
$S/serve.sh check   # host -> gateway -> model: one tool call, one stream
$S/pi.sh check      # Pi VM -> pi-proxy -> gateway; OpenRouter line should pass
```

## 4. Use Pi

`pi.sh` takes the same arguments as `pi-container/run.sh`:

```sh
$S/pi.sh                         # interactive Pi on the current folder
$S/pi.sh -p "list the files here"
```

Pi still asks for its configured model (`inkling-2-small` by default). The
gateway ignores the name and answers with Inkling 2 Mini.

## 5. Back to OpenRouter

Stop `serve.sh` (Ctrl-C) and run plain `pi-container/run.sh`. It sees the
upstream is gone and recreates `pi-proxy` pointing at openrouter.ai.

## 6. Uninstall

```sh
$S/uninstall.sh                  # or --keep-model to keep the 17.3 GB of weights
```

Then run `pi-container/run.sh check` once so the proxy points at OpenRouter
again.

## Memory

About 17.3 GB of weights plus up to 4 GB of prompt cache, 4 GB for the Pi VM (`PI_MEMORY`) and 1 GB for
the proxy: close to 30 GB. Use `PI_MEMORY=2G $S/pi.sh` if the Mac swaps.

## Try it with a small model first

Any local MLX folder works in place of Inkling, with no download:

```sh
export INKLING_MODEL_DIR=$HOME/.models/lm-studio/lmstudio-community/LFM2.5-1.2B-Instruct-MLX-8bit
$S/serve.sh pi
```

## Security notes

- The gateway listens only on loopback and the container network's host
  address, not on your LAN. Containers on the default network can reach it;
  it serves only the model.
- `pi-proxy` still adds your OpenRouter key to each request, so the key goes to
  the gateway over the host-only bridge. The gateway does not read or log it.
- Request logs hold timings and token counts, not prompts or replies.

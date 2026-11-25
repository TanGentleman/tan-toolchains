# Inkling 2 Mini on MLX (spike)

Runs [thinkingmachines/Inkling-2-Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini)
on an Apple silicon Mac (32 GB+), as an OpenAI-compatible endpoint on
`http://127.0.0.1:8090/v1`. Peak memory is about 20–25 GB.

```sh
spikes/inkling-2-mini/install.sh     # uv sync, then asks before the 20 GB download
spikes/inkling-2-mini/serve.sh       # foreground; Ctrl-C stops both processes
spikes/inkling-2-mini/serve.sh check # in a second terminal
spikes/inkling-2-mini/uninstall.sh   # [--keep-model]
```

Needs only [uv](https://docs.astral.sh/uv/). Everything goes in
`~/.local/share/inkling-2-mini` (`INKLING_HOME`): Python, uv cache, venv,
Hugging Face cache, weights, logs. Uninstall deletes that directory.
`INKLING_MODEL_DIR=/path/to/mlx-model` serves another local MLX folder
instead, read only and with no download.

## Choices

| | Choice | Why |
|---|---|---|
| Runtime | `mlx-lm` at [ml-explore/mlx-lm#2086](https://github.com/ml-explore/mlx-lm/pull/2086), pinned commit, in `uv.lock` | Inkling support is not in a release yet. Move to the release when it ships. |
| Weights | Official checkpoint, pinned revision, `mtp.safetensors` skipped | The model authors' own NVFP4/MXFP8 mix (~20 GB). mlx-lm does not use the MTP head. Community 4-bit conversions save ~3 GB but are a second quantization. |
| Server | `mlx_lm.server`, loopback, 1 request at a time, prompt cache capped at 4 GB | One agent turn at a time fits in 30 GB. `server_v2` has no image input. |
| Sampling | temperature 1.0, top-p 0.95, top-k 20, max 32768 tokens | Model's `generation_config` and the PR's benchmark. The server's defaults (0.0, 512) are wrong for this model. |
| Front | `gateway.py` (stdlib, ~320 lines) on port 8090 | See below. |

`mlx_lm.server` returns Inkling's markup (`<|message_model|>…<|content_invoke_tool_json|>…`)
as plain text, so agent clients get no `tool_calls` and see the thinking.
`gateway.py` parses it into `reasoning_content`, `content` and `tool_calls`
(streaming too), maps `reasoning_effort` / `reasoning.effort` to the chat
template, accepts OpenRouter paths (`/api/v1/...`), and writes one JSON line
per request (latency, time to first token, tokens, finish reason; no text) to
`logs/requests.jsonl`. LiteLLM would not parse this markup either, so it would
add a dependency tree and still need this parser. Remove the gateway when
mlx-lm parses Inkling output itself.

If the server fails to load the weights on a 32 GB Mac, macOS's GPU memory
limit is too low. `sudo sysctl iogpu.wired_limit_mb=28672` raises it until
reboot.

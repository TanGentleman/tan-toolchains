# Local model server (spike)

Serves a local model on an Apple silicon Mac as an OpenAI-compatible endpoint,
`http://127.0.0.1:8090/v1` (plus `/health`), for Pi in a container with no
internet. The first model is Inkling 2 Mini (17.3 GB of weights, 32 GB+ Mac).

```sh
spikes/local-model/model install                 # uv sync, then asks before downloading the weights
spikes/local-model/model serve [--containers]    # in its own tab; Ctrl-C or closing the tab unloads the model
spikes/local-model/model status [--json]         # state, model, backend, url, model_url
spikes/local-model/model check                   # one tool call and one stream through the gateway
spikes/local-model/model uninstall [--keep-model]
spikes/local-model/eval.sh [TASK.json ...]       # small tasks for Pi, checked on the host
```

`--containers` also listens on the Apple container network's host address,
so Pi can use it: `pi-container/run.sh --egress offline --model-url http://gateway:8090`.
Guide: [GUIDE.md](GUIDE.md).

Needs [uv](https://docs.astral.sh/uv/) (`curl -LsSf https://astral.sh/uv/install.sh | sh`);
`jq` ships with macOS 26. uv installs Python 3.12 itself. Everything goes in
`~/.local/share/local-model` (`LOCAL_MODEL_HOME`): Python, uv cache, venv,
Hugging Face cache, weights (`models/<name>/`), logs, evals.

## Layout

| File | What |
|---|---|
| `model` | the CLI; `lib.sh` holds paths and ports |
| `models/<name>.json` | what to serve: backend, pinned weights, response parser, backend flags |
| `config.py` | reads and checks those files; one class per backend (`mlx-lm` only, for now) |
| `gateway.py` | OpenAI-compatible front on port 8090; logs one line per request, never prompt or reply text |
| `eval.py`, `eval.sh`, `evals/` | offline evals through `pi-container/run.sh --image min` |

## Choices for Inkling 2 Mini

| | Choice | Why |
|---|---|---|
| Runtime | `mlx-lm` at [ml-explore/mlx-lm#2086](https://github.com/ml-explore/mlx-lm/pull/2086), pinned in `uv.lock` | Inkling support is not in a release yet. |
| Weights | [mlx-community/Inkling-2-Mini-4bit](https://huggingface.co/mlx-community/Inkling-2-Mini-4bit), pinned revision | Converted with the same PR; 17.3 GB vs 20.2 GB for the official checkpoint. |
| `server_args` | temperature 1.0, top-p 0.95, top-k 20, max 32768 tokens; 2 decodes batched, 1 prefill, prompt cache 4 entries / 4 GB | The model's `generation_config`; the server's defaults (0.0, 512) are wrong for it. Fits 30 GB with two Pi VMs. |
| `parser: inkling` | `gateway.py` parses `<\|message_model\|>…<\|content_invoke_tool_json\|>…` | `mlx_lm.server` returns Inkling's markup as plain text, so clients would get no `tool_calls`. Use `"none"` once the backend parses it. |

If the backend fails to load the weights on a 32 GB Mac, macOS's GPU memory
limit is too low: `sudo sysctl iogpu.wired_limit_mb=28672` raises it until reboot.

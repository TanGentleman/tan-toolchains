# Lens smoke run

`e2e/lens.sh` runs the [Lens CLI](https://github.com/BerriAI/lens/tree/main/src/cli) with two targets on the
fake OpenRouter, so it needs no API key and costs nothing:

- `litellm/pi`: Pi driven by LiteLLM's own Pi harness
- `fleet/pi`: Pi driven by a real `fleetd` over its HTTP API (`FleetPi` in `evals.py`). The `two-turns` task spawns a
  session and sends a second input, so it covers checkpoint and resume

The Lens CLI is a source-only preview. Build it once (about 5 minutes for the Rust part):

```bash
git clone https://github.com/BerriAI/lens && cd lens
CARGO_NET_GIT_FETCH_WITH_CLI=true uv sync --project src/sdk --extra agent-evals --frozen
source src/sdk/.venv/bin/activate
```

Then, from the same shell, run `fleet/e2e/lens.sh`. `TRIALS=5` repeats every task more times

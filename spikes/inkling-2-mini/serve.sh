#!/usr/bin/env bash
# serve.sh        mlx_lm.server on 127.0.0.1:$mlx_port, gateway on $host:$port
# serve.sh pi     same, and also listen on the container network for pi.sh
# serve.sh check  one tool call and one streamed reply through the gateway
# No network: Hugging Face is forced offline and the model is a local path.
set -euo pipefail
. "$(dirname "$0")/env.sh"
[ -x "$venv/bin/python" ] || die "run install.sh first"

if [ "${1:-}" = check ]; then
  exec "$venv/bin/python" "$spike_dir/gateway.py" --check "http://127.0.0.1:$port"
fi
if [ -n "${INKLING_MODEL_DIR:-}" ]; then
  [ -f "$model_dir/config.json" ] || die "no config.json in $model_dir"
else
  [ -f "$model_dir/.complete" ] || die "weights missing; run install.sh"
fi
listen=(--listen "$host:$port")
if [ "${1:-}" = pi ]; then listen+=(--listen "$(container_gateway):$port"); fi

pids=()
stop() { for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done; rm -f "$INKLING_HOME"/run/*.pid "$INKLING_HOME/run/pi"; }
trap stop EXIT
trap 'exit 130' INT TERM

# One agent turn at a time; the prompt cache is capped so weights (17.3 GB)
# plus cache and activations stay under ~30 GB. Sampling follows the model's
# generation_config (temperature 1.0) and the mlx-lm PR's benchmark.
HF_HUB_OFFLINE=1 "$venv/bin/mlx_lm.server" --model "$model_dir" \
  --host 127.0.0.1 --port "$mlx_port" \
  --temp 1.0 --top-p 0.95 --top-k 20 --max-tokens 32768 \
  --decode-concurrency 1 --prompt-concurrency 1 \
  --prompt-cache-size 2 --prompt-cache-bytes $((4 * 1024 * 1024 * 1024)) \
  >>"$INKLING_HOME/logs/mlx.log" 2>&1 &
pids+=($!); echo $! > "$INKLING_HOME/run/mlx.pid"
echo "mlx_lm.server pid $! loading $model_dir (log: $INKLING_HOME/logs/mlx.log)"

"$venv/bin/python" "$spike_dir/gateway.py" "${listen[@]}" \
  --upstream "127.0.0.1:$mlx_port" --log "$INKLING_HOME/logs/requests.jsonl" &
pids+=($!); echo $! > "$INKLING_HOME/run/gateway.pid"
if [ "${1:-}" = pi ]; then touch "$INKLING_HOME/run/pi"; fi
# macOS /bin/bash is 3.2, which has no wait -n.
while kill -0 "${pids[0]}" 2>/dev/null && kill -0 "${pids[1]}" 2>/dev/null; do sleep 1; done

#!/usr/bin/env bash
# serve.sh        mlx_lm.server on 127.0.0.1:$mlx_port, gateway on $host:$port
# serve.sh pi     same, and also listen on the container network for pi.sh
# serve.sh check  one tool call and one streamed reply through the gateway
# INKLING_DECODE_CONCURRENCY, INKLING_PROMPT_CONCURRENCY, INKLING_PROMPT_CACHE_SIZE
# and INKLING_PROMPT_CACHE_GB set batching and the prompt cache (GUIDE.md, Memory).
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
for v in decode_concurrency prompt_concurrency prompt_cache_size prompt_cache_gb; do
  case ${!v} in ''|0*|*[!0-9]*) die "INKLING_$(echo "$v" | tr a-z A-Z) must be a positive integer, got '${!v}'" ;; esac
done
listen=(--listen "$host:$port")
if [ "${1:-}" = pi ]; then listen+=(--listen "$(container_gateway):$port"); fi

pids=()
# Stopping waits for mlx_lm.server to exit, so the model is unloaded when it returns.
stop() {
  for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done
  for p in ${pids[@]+"${pids[@]}"}; do wait "$p" 2>/dev/null || true; done
  rm -f "$INKLING_HOME"/run/*.pid "$INKLING_HOME/run/pi" "$INKLING_HOME/run/serve.json"
}
trap stop EXIT
trap 'exit 130' INT TERM

# Requests from several Pi containers are decoded as one batch; the prompt
# cache cap (bytes) counts the active batch too, so weights (17.3 GB) plus
# cache stay under ~30 GB with the defaults. Sampling follows the model's
# generation_config (temperature 1.0) and the mlx-lm PR's benchmark.
HF_HUB_OFFLINE=1 "$venv/bin/mlx_lm.server" --model "$model_dir" \
  --host 127.0.0.1 --port "$mlx_port" \
  --temp 1.0 --top-p 0.95 --top-k 20 --max-tokens 32768 \
  --decode-concurrency "$decode_concurrency" --prompt-concurrency "$prompt_concurrency" \
  --prompt-cache-size "$prompt_cache_size" --prompt-cache-bytes $((prompt_cache_gb * 1024 * 1024 * 1024)) \
  >>"$INKLING_HOME/logs/mlx.log" 2>&1 &
pids+=($!); echo $! > "$INKLING_HOME/run/mlx.pid"
echo "mlx_lm.server pid $! loading $model_dir (log: $INKLING_HOME/logs/mlx.log)"
echo "batch: decode $decode_concurrency, prompt $prompt_concurrency; prompt cache: $prompt_cache_size entries, $prompt_cache_gb GB"
printf '{"decode_concurrency": %d, "prompt_concurrency": %d, "prompt_cache_size": %d, "prompt_cache_gb": %d}\n' \
  "$decode_concurrency" "$prompt_concurrency" "$prompt_cache_size" "$prompt_cache_gb" > "$INKLING_HOME/run/serve.json"

"$venv/bin/python" "$spike_dir/gateway.py" "${listen[@]}" \
  --upstream "127.0.0.1:$mlx_port" --log "$INKLING_HOME/logs/requests.jsonl" &
pids+=($!); echo $! > "$INKLING_HOME/run/gateway.pid"
if [ "${1:-}" = pi ]; then touch "$INKLING_HOME/run/pi"; fi
# macOS /bin/bash is 3.2, which has no wait -n.
while kill -0 "${pids[0]}" 2>/dev/null && kill -0 "${pids[1]}" 2>/dev/null; do sleep 1; done

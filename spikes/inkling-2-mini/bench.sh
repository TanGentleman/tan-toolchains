#!/usr/bin/env bash
# bench.sh [--jobs 1,2,4] [--repeat R] [TASK.json ...]   eval.sh's tasks at each
# --jobs level in turn; prints tasks/hour, tokens and p50 time to first token.
# Needs `inkling up pi`. Output: $INKLING_HOME/bench/<time>/bench.json
set -euo pipefail
. "$(dirname "$0")/env.sh"
[ -x "$venv/bin/python" ] || die "run install.sh first"
mkdir -p "$INKLING_HOME/bench"
export PI_MEMORY=${PI_MEMORY:-$eval_pi_memory}
exec "$venv/bin/python" "$spike_dir/bench.py" "$@" \
  --out "$INKLING_HOME/bench" --requests-log "$INKLING_HOME/logs/requests.jsonl" \
  --serve-info "$INKLING_HOME/run/serve.json" \
  --model "${INKLING_MODEL_DIR:-$model_repo@$model_rev}" \
  -- "${eval_pi[@]}"

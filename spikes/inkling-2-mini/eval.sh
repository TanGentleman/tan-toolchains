#!/usr/bin/env bash
# eval.sh [--jobs N] [TASK.json ...]   Pi does each task (default: evals/*.json)
# in a fresh folder through pi.sh, up to N at once, each in its own container
# instance; the files it leaves are checked on the host.
# Needs `inkling up pi`. Runs: $INKLING_HOME/evals/<time>-<id>/
set -euo pipefail
. "$(dirname "$0")/env.sh"
[ -x "$venv/bin/python" ] || die "run install.sh first"
mkdir -p "$INKLING_HOME/evals"
export PI_MEMORY=${PI_MEMORY:-$eval_pi_memory}
exec "$venv/bin/python" "$spike_dir/eval.py" "$@" \
  --out "$INKLING_HOME/evals" --requests-log "$INKLING_HOME/logs/requests.jsonl" \
  --model "${INKLING_MODEL_DIR:-$model_repo@$model_rev}" \
  -- "${eval_pi[@]}"

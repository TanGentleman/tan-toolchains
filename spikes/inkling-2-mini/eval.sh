#!/usr/bin/env bash
# eval.sh [TASK.json ...]   Pi does each task (default: evals/*.json) in a
# fresh folder through pi.sh; the files it leaves are checked on the host.
# Needs `serve.sh pi` running. Runs: $INKLING_HOME/evals/<time>-<id>/
set -euo pipefail
. "$(dirname "$0")/env.sh"
[ -x "$venv/bin/python" ] || die "run install.sh first"
mkdir -p "$INKLING_HOME/evals"
# Same flags as fleet's turns: JSON events on stdout, prompt on stdin, and no
# repo extensions or skills.
exec "$venv/bin/python" "$spike_dir/eval.py" "$@" \
  --out "$INKLING_HOME/evals" --requests-log "$INKLING_HOME/logs/requests.jsonl" \
  --model "${INKLING_MODEL_DIR:-$model_repo@$model_rev}" \
  -- "$spike_dir/pi.sh" pi --mode json -p --no-approve --no-skills

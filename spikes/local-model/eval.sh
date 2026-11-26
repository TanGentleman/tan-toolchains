#!/usr/bin/env bash
# eval.sh [TASK.json ...]   Pi does each task (default: evals/*.json) in a fresh
# folder, one at a time, in pi-container's min image with offline egress; the
# files it leaves are checked on the host. Needs `model up --containers`.
# Runs: $LOCAL_MODEL_HOME/evals/<time>-<id>/
set -euo pipefail
. "$(dirname "$0")/lib.sh"
command -v jq >/dev/null || die "needs jq"
[ -x "$venv/bin/python" ] || die "run install first: $spike_dir/model install"
status=$("$spike_dir/model" status --json)
model_url=$(jq -r '.model_url // empty' <<<"$status")
[ "$(jq -r .state <<<"$status")" = up ] && [ -n "$model_url" ] ||
  die "needs the model server on the container network; run: $spike_dir/model up --containers"
info=$(model_info)
mkdir -p "$home/evals"
# Same Pi flags as fleet's turns: JSON events on stdout, prompt on stdin, no
# repo extensions or skills.
exec "$venv/bin/python" "$spike_dir/eval.py" "$@" \
  --out "$home/evals" --requests-log "$home/logs/requests.jsonl" \
  --model "$(jq -r '.weights.repo + "@" + .weights.revision' <<<"$info")" \
  -- "$spike_dir/../../pi-container/run.sh" --egress offline --model-url "$model_url" --image min \
  --instance eval pi --mode json -p --no-approve --no-skills

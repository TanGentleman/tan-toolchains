# Sourced by every script here. Every file this spike
# creates lives under $INKLING_HOME, so uninstall is one directory.
spike_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INKLING_HOME=${INKLING_HOME:-$HOME/.local/share/inkling-2-mini}
marker="$INKLING_HOME/.inkling-2-mini-spike"

# MLX 4-bit build of the official checkpoint, pinned. Converted with the same
# mlx-lm PR as uv.lock; routed experts keep the official NVFP4/MXFP8.
model_repo=mlx-community/Inkling-2-Mini-4bit
model_rev=9c0e2960609ba7cb40daf92c6f7bf8ed56e1dd62
# INKLING_MODEL_DIR serves another local MLX model folder instead (read only).
model_dir=${INKLING_MODEL_DIR:-$INKLING_HOME/model}
venv="$INKLING_HOME/venv"

mlx_port=${INKLING_MLX_PORT:-8091}     # mlx_lm.server, loopback only
port=${INKLING_PORT:-8090}             # gateway.py, what clients call
host=${INKLING_HOST:-127.0.0.1}

# serve.sh: mlx_lm.server batching and prompt cache (see GUIDE.md, Memory).
decode_concurrency=${INKLING_DECODE_CONCURRENCY:-2}
prompt_concurrency=${INKLING_PROMPT_CONCURRENCY:-1}
prompt_cache_size=${INKLING_PROMPT_CACHE_SIZE:-4}
prompt_cache_gb=${INKLING_PROMPT_CACHE_GB:-4}

# eval.sh and bench.sh: the Pi command (same flags as fleet's turns: JSON
# events on stdout, prompt on stdin, no repo extensions or skills). eval.py
# puts the worker's slot (eval-1..eval-N) in {instance}. Eval VMs get 2 GB.
eval_pi=("$spike_dir/pi.sh" --instance '{instance}' pi --mode json -p --no-approve --no-skills)
eval_pi_memory=2G

# Keep uv, Python and Hugging Face out of their default ~/.cache homes.
export UV_CACHE_DIR="$INKLING_HOME/uv-cache"
export UV_PYTHON_INSTALL_DIR="$INKLING_HOME/python"
export UV_PYTHON_PREFERENCE=only-managed
export UV_PROJECT_ENVIRONMENT="$venv"
export HF_HOME="$INKLING_HOME/hf"
# HF_HOME moves the token file too; read an existing `hf auth login` token in
# place (never written or deleted here). HF_TOKEN still wins when set.
export HF_TOKEN_PATH=${HF_TOKEN_PATH:-$HOME/.cache/huggingface/token}
export HF_HUB_DISABLE_TELEMETRY=1
export PYTHONDONTWRITEBYTECODE=1

# Host side of Apple container's default network. pi-proxy sits on that
# network, so `serve.sh pi` also listens here and pi.sh points the proxy here.
container_gateway() {
  command -v container >/dev/null || die "needs Apple container"
  command -v jq >/dev/null || die "needs jq"
  local gw
  gw=$(container network inspect default 2>/dev/null | jq -r '.[0].status.ipv4Gateway // empty') || true
  [ -n "$gw" ] || die "no default container network; run: container system start"
  printf '%s\n' "$gw"
}

die() { echo "${0##*/}: $*" >&2; exit 1; }
confirm() { # prompt
  [ -t 0 ] || die "needs a terminal to confirm: $1"
  local a; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]
}

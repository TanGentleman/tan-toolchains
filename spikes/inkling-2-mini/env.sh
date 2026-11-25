# Sourced by install.sh, serve.sh and uninstall.sh. Every file this spike
# creates lives under $INKLING_HOME, so uninstall is one directory.
spike_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INKLING_HOME=${INKLING_HOME:-$HOME/.local/share/inkling-2-mini}
marker="$INKLING_HOME/.inkling-2-mini-spike"

# Official weights, pinned. Commits after ed40e7d change only README/evals.
model_repo=thinkingmachines/Inkling-2-Mini
model_rev=c9d028302cd0f035fdf8e7e91f089a4ce94d2195
# INKLING_MODEL_DIR serves another local MLX model folder instead (read only).
model_dir=${INKLING_MODEL_DIR:-$INKLING_HOME/model}
venv="$INKLING_HOME/venv"

mlx_port=${INKLING_MLX_PORT:-8091}     # mlx_lm.server, loopback only
port=${INKLING_PORT:-8090}             # gateway.py, what clients call
host=${INKLING_HOST:-127.0.0.1}

# Keep uv, Python and Hugging Face out of their default ~/.cache homes.
export UV_CACHE_DIR="$INKLING_HOME/uv-cache"
export UV_PYTHON_INSTALL_DIR="$INKLING_HOME/python"
export UV_PYTHON_PREFERENCE=only-managed
export UV_PROJECT_ENVIRONMENT="$venv"
export HF_HOME="$INKLING_HOME/hf"
export HF_HUB_DISABLE_TELEMETRY=1
export PYTHONDONTWRITEBYTECODE=1

# Host side of Apple container's default network. pi-proxy sits on that
# network, so `serve.sh pi` also listens here and pi.sh points the proxy here.
# Apple container's default network: "GATEWAY SUBNET". The host gets the
# gateway address only while a container runs, so serve.sh pi binds 0.0.0.0.
container_net() {
  command -v container >/dev/null || die "needs Apple container"
  command -v jq >/dev/null || die "needs jq"
  local net
  net=$(container network inspect default 2>/dev/null | jq -r '.[0] |
    [.status.ipv4Gateway, (.status.ipv4Subnet // .configuration.ipv4Subnet)] |
    select(all(. != null)) | join(" ")') || true
  [ -n "$net" ] || die "no default container network; run: container system start"
  printf '%s\n' "$net"
}

die() { echo "${0##*/}: $*" >&2; exit 1; }
confirm() { # prompt
  [ -t 0 ] || die "needs a terminal to confirm: $1"
  local a; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]
}

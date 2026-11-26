# Sourced by model and eval.sh. Everything install makes lives under
# $LOCAL_MODEL_HOME; models/<name>.json says what to serve (config.py).
spike_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOCAL_MODEL_HOME=${LOCAL_MODEL_HOME:-$HOME/.local/share/local-model}
home=$LOCAL_MODEL_HOME
marker="$home/.local-model-spike"
venv="$home/venv"
run="$home/run"
port=${LOCAL_MODEL_PORT:-8090}                  # gateway.py, what clients call
backend_port=${LOCAL_MODEL_BACKEND_PORT:-8091}  # the backend server, loopback only
up_timeout=600    # up waits this long for the model to load
down_timeout=60   # down waits this long for a clean exit, then sends KILL

# Keep uv, Python and Hugging Face out of their default ~/.cache homes.
export UV_CACHE_DIR="$home/uv-cache"
export UV_PYTHON_INSTALL_DIR="$home/python"
export UV_PYTHON_PREFERENCE=only-managed
export UV_PROJECT_ENVIRONMENT="$venv"
export HF_HOME="$home/hf"
# HF_HOME moves the token file too; read an existing `hf auth login` token in
# place (never written or deleted here). HF_TOKEN still wins when set.
export HF_TOKEN_PATH=${HF_TOKEN_PATH:-$HOME/.cache/huggingface/token}
export HF_HUB_DISABLE_TELEMETRY=1
export PYTHONDONTWRITEBYTECODE=1

die() { echo "${0##*/}: $*" >&2; exit 1; }
confirm() { # prompt
  [ -t 0 ] || die "needs a terminal to confirm: $1"
  local a; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]
}
py() { if [ -x "$venv/bin/python" ]; then "$venv/bin/python" "$@"; else python3 "$@"; fi; }
model_info() { py "$spike_dir/config.py" show; }  # the selected model, as JSON

# Host side of Apple container's default network: what run.sh calls `gateway`.
container_gateway() {
  command -v container >/dev/null || die "needs Apple container"
  local gw
  gw=$(container network inspect default 2>/dev/null | jq -r '.[0].status.ipv4Gateway // empty') || true
  [ -n "$gw" ] || die "no default container network; run: container system start"
  printf '%s\n' "$gw"
}

# run/*.pid hold a pid and that process's start time, so a pid that the OS
# has reused for another process is never taken for ours.
pid_start() { # pid; prints its start time, spaces collapsed
  local s
  s=$(ps -p "$1" -o lstart= 2>/dev/null) || return 1
  [ -n "$s" ] || return 1
  # Unquoted on purpose: lstart pads with spaces ("Nov  5"); no glob characters.
  echo $s
}
pid_alive() { # pid; a zombie (exited, not yet reaped) counts as gone
  local st
  st=$(ps -p "$1" -o stat= 2>/dev/null) || return 1
  st=${st//[[:space:]]/}
  [ -n "$st" ] && [ "${st#Z}" = "$st" ]
}
pid_write() { # file pid
  printf '%s\n%s\n' "$2" "$(pid_start "$2" || true)" > "$1"
}
pid_live() { # file; prints the pid if the process that wrote it still runs
  local pid="" start="" now
  [ -f "$1" ] || return 1
  { read -r pid; read -r start; } < "$1" || true
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$start" ] || return 1
  now=$(pid_start "$pid") || return 1
  [ "$now" = "$start" ] && pid_alive "$pid" || return 1
  printf '%s\n' "$pid"
}

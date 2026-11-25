#!/usr/bin/env bash
# Read-only probe for the Inkling 2 Mini spike. Installs, starts and writes
# nothing. Prints your home directory as $HOME.
#   bash spikes/inkling-2-mini/probe.sh 2>&1 | pbcopy
set -u

probe() {
  sec() { printf '\n== %s\n' "$1"; }
  have() { command -v "$1" >/dev/null 2>&1; }
  ver() { # name, version args...
    local n=$1; shift
    if have "$n"; then printf '%-14s %s | %s\n' "$n" "$(command -v "$n")" "$("$n" "$@" 2>&1 | head -n 1)"
    else printf '%-14s -\n' "$n"; fi
  }
  du_h() { [ -e "$1" ] && printf '%-60s %s\n' "$1" "$(du -sh "$1" 2>/dev/null | cut -f1)"; }

  sec machine
  sw_vers 2>/dev/null
  printf 'arch %s\n' "$(uname -m)"
  sysctl -n hw.model machdep.cpu.brand_string 2>/dev/null
  printf 'cpus %s (perf %s)\n' "$(sysctl -n hw.ncpu 2>/dev/null)" "$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null)"
  printf 'ram_gb %s\n' "$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))"
  printf 'iogpu.wired_limit_mb %s (0 = macOS default)\n' "$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo n/a)"
  sysctl -n vm.swapusage 2>/dev/null
  memory_pressure -Q 2>/dev/null | tail -n 1
  vm_stat 2>/dev/null | head -n 6
  system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset Model|Total Number of Cores|Metal' | sed 's/^ *//'

  sec disk
  df -h "$HOME" | tail -n 1

  sec tools
  ver brew --version
  ver container --version
  ver jq --version
  ver git --version
  ver curl --version
  ver python3 --version
  ver uv --version
  ver pipx --version
  ver hf version
  ver huggingface-cli version
  ver ollama --version
  ver llama-server --version
  ver llama-cli --version
  ver mlx_lm.server --help
  ver lms version
  ver tailscale version
  have xcode-select && printf 'xcode-select %s\n' "$(xcode-select -p 2>&1)"
  have brew && { printf 'brew prefix %s\n' "$(brew --prefix)"; brew list --formula 2>/dev/null | grep -Ei 'llama|ollama|mlx|python@|uv$|huggingface' || true; brew list --cask 2>/dev/null | grep -Ei 'ollama|lm-studio|llama' || true; }
  ls -d /Applications/Ollama.app /Applications/LM\ Studio.app /Applications/Llama*.app 2>/dev/null

  sec model-caches
  du_h "$HOME/.cache/huggingface"
  du_h "$HOME/.cache/huggingface/hub"
  ls -d "$HOME"/.cache/huggingface/hub/models--*[Ii]nkling* 2>/dev/null
  du_h "$HOME/.ollama"
  du_h "$HOME/.lmstudio"
  du_h "$HOME/Library/Caches/llama.cpp"
  du_h "$HOME/.local/share/inkling-2-mini"
  printf 'HF_HOME=%s HF_HUB_CACHE=%s OLLAMA_MODELS=%s\n' "${HF_HOME:-}" "${HF_HUB_CACHE:-}" "${OLLAMA_MODELS:-}"

  sec listening-ports
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR==1 || /:(1234|8000|8080|8081|11434|52415)/' | awk '{print $1, $2, $9, $10}'

  sec container
  if have container; then
    container system status 2>&1 | head -n 8
    container system property list 2>&1 | head -n 30
    echo '-- networks'; container network ls 2>&1
    echo '-- containers'; container ls -a 2>&1
    echo '-- container memory'
    container ls -a --format json 2>/dev/null | jq -r '.[] | "\(.configuration.id // .id) cpus=\(.configuration.resources.cpus // "?") mem=\((.configuration.resources.memoryInBytes // 0) / 1073741824)G"' 2>/dev/null
    echo '-- images'; container image ls 2>&1 | head -n 20
  fi
  echo '-- host interfaces'
  ifconfig 2>/dev/null | awk '/^[a-z]/{i=$1} /inet /{print i, $2}' | grep -v '^lo0'

  sec pi-container-profiles
  for d in "$HOME/.config/pi-container" "$HOME"/.config/pi-container-*; do
    [ -d "$d" ] || continue
    echo "-- $d"
    ls -A "$d" 2>/dev/null | tr '\n' ' '; echo
    [ -f "$d/private/proxy.addr" ] && printf 'proxy.addr %s\n' "$(cat "$d/private/proxy.addr")"
    [ -f "$d/env" ] && printf 'env keys: %s\n' "$(grep -oE '^[A-Z_]+=.' "$d/env" | sed 's/=.$//' | tr '\n' ' ')"
    find "$d" -maxdepth 4 -name settings.json -print 2>/dev/null | while read -r s; do printf '%s defaultModel=%s\n' "$s" "$(jq -r '.defaultModel // empty' "$s" 2>/dev/null)"; done
    find "$d" -maxdepth 4 -name models.json -print 2>/dev/null
  done

  sec repo
  if r=$(git rev-parse --show-toplevel 2>/dev/null); then
    printf '%s %s %s\n' "$r" "$(git branch --show-current)" "$(git rev-parse --short HEAD)"
    git status --short | head -n 10
  fi
}

probe 2>&1 | sed -e "s|$HOME|\$HOME|g" -e "s|/Users/$USER|\$HOME|g"

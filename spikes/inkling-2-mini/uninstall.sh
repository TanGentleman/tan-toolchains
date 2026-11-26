#!/usr/bin/env bash
# Remove everything install.sh and serve.sh created: stop their processes,
# then delete $INKLING_HOME. --keep-model keeps the 17.3 GB of weights.
set -euo pipefail
. "$(dirname "$0")/env.sh"
keep_model=0; [ "${1:-}" = --keep-model ] && keep_model=1

# A plain `uv sync` in this folder (without env.sh) makes .venv here.
if [ -d "$spike_dir/.venv" ] && confirm "Delete $spike_dir/.venv?"; then rm -rf "$spike_dir/.venv"; fi
if [ ! -e "$INKLING_HOME" ]; then echo "nothing at $INKLING_HOME"; exit 0; fi
case $(cd "$INKLING_HOME" && pwd -P) in /|"$(cd "$HOME" && pwd -P)") die "refusing to delete $INKLING_HOME" ;; esac
[ -f "$marker" ] || die "$INKLING_HOME has no $(basename "$marker"); not deleting it"

for f in "$INKLING_HOME"/run/*.pid; do
  if pid=$(pid_live "$f"); then
    echo "stopping pid $pid ($(basename "$f" .pid))"; kill "$pid" 2>/dev/null || true
  fi
done

du -sh "$INKLING_HOME"/* "$INKLING_HOME"/.[!.]* 2>/dev/null || true
if [ "$keep_model" = 1 ]; then
  confirm "Delete $INKLING_HOME except model/?" || exit 1
  find "$INKLING_HOME" -mindepth 1 -maxdepth 1 ! -name model ! -name "$(basename "$marker")" -exec rm -rf {} +
else
  confirm "Delete $INKLING_HOME?" || exit 1
  # uv marks cache files read-only.
  chmod -R u+w "$INKLING_HOME" 2>/dev/null || true
  rm -rf "$INKLING_HOME"
fi
echo "removed. Not touched: uv itself, and macOS's own Metal shader cache."

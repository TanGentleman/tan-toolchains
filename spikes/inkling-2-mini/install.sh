#!/usr/bin/env bash
# Install Inkling 2 Mini for MLX under $INKLING_HOME (default
# ~/.local/share/inkling-2-mini). Network: uv sync (PyPI, github.com) and,
# only after you confirm, huggingface.co for the weights.
set -euo pipefail
. "$(dirname "$0")/env.sh"

[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || die "needs an Apple silicon Mac"
command -v uv >/dev/null || die "needs uv: https://docs.astral.sh/uv/getting-started/installation/"
ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
[ "$ram_gb" -ge 32 ] || die "needs 32 GB of RAM or more (have $ram_gb GB)"

mkdir -p "$INKLING_HOME"
[ -f "$marker" ] || [ -z "$(ls -A "$INKLING_HOME")" ] ||
  die "$INKLING_HOME exists and was not made by this spike"
printf 'created by tan-toolchains spikes/inkling-2-mini\n' > "$marker"
mkdir -p "$INKLING_HOME/logs" "$INKLING_HOME/run"

echo "== 1/2 Python env (uv sync --frozen into $venv)"
(cd "$spike_dir" && uv sync --frozen)

echo "== 2/2 weights"
if [ -n "${INKLING_MODEL_DIR:-}" ]; then
  echo "INKLING_MODEL_DIR is set; not downloading"
elif [ -f "$model_dir/.complete" ] && [ "$(cat "$model_dir/.complete")" = "$model_rev" ]; then
  echo "already at $model_rev"
else
  free_gb=$(df -g "$INKLING_HOME" | awk 'NR==2 {print $4}')
  cmd=("$venv/bin/hf" download "$model_repo" --revision "$model_rev"
       --local-dir "$model_dir" --exclude '.eval_results/*')
  echo "This downloads about 17.3 GB from huggingface.co ($free_gb GB free):"
  printf '  %q' "${cmd[@]}"; echo
  confirm "Run it now?" || { echo "Skipped. Re-run install.sh to download."; exit 0; }
  # A partial or older download (another repo or revision) must not mix in.
  rm -rf "$model_dir"
  "${cmd[@]}"
  printf '%s\n' "$model_rev" > "$model_dir/.complete"
fi

echo
echo "Installed in $INKLING_HOME ($(du -sh "$INKLING_HOME" | cut -f1))."
echo "Serve:     $spike_dir/inkling up"
echo "Check:     $spike_dir/inkling check"
echo "Uninstall: $spike_dir/inkling uninstall"

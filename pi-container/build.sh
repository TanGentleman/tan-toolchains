#!/usr/bin/env bash
# Build an image pack from the repo root context.
#   build.sh [PACK] [container build options...]
# PACK is one of: tools editor agent agent-gh full all (default: full).
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/images.sh"
cli="${CONTAINER_CLI:-container}"

usage() {
  cat <<'EOF'
Build a pi-container image pack from the repo root context.

  build.sh [PACK] [container build options...]

Packs:
  tools      Zig, zigpeek, enforcer, jq, git, ripgrep, fd
  editor     tools + Neovim + ZLS
  agent      tools + Pi
  agent-gh   agent + gh
  full       agent-gh + Neovim + ZLS (default)
  all        build every pack

Tags: pi-tools:local, pi-editor:local, pi-agent-lite:local,
      pi-agent-gh:local, pi-agent:local.
EOF
}

case ${1:-} in
  --help|-h|help) usage; exit 0 ;;
esac

command -v "$cli" >/dev/null 2>&1 || {
  echo "build.sh: '$cli' not found; install Apple container and run 'container system start'" >&2
  exit 1
}

pack=${1:-full}
shift || true
if [ $# -gt 0 ]; then
  case $1 in
    -*) ;;
    *) echo "build.sh: unexpected argument '$1'; pass container build options after the pack" >&2; exit 2 ;;
  esac
fi

build_pack() { # pack, [container build options...]
  local pack=$1 target tag
  shift
  target=$(pi_pack_target "$pack") || { echo "build.sh: unknown pack '$pack'" >&2; exit 2; }
  tag=$(pi_pack_tag "$pack")
  printf 'build.sh: %s -> %s (target %s)\n' "$pack" "$tag" "$target" >&2
  "$cli" build "$@" -t "$tag" --target "$target" -f "$here/Dockerfile" "$here/.."
}

if [ "$pack" = all ]; then
  for p in $pi_pack_names; do
    build_pack "$p" "$@"
  done
else
  build_pack "$pack" "$@"
fi

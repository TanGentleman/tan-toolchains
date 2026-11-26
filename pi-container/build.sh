#!/usr/bin/env bash
# Build an image pack from the repo root context.
#   build.sh [PACK] [container build options...]
# PACK is one of: tools editor agent-min agent full zig all (default: full).
#   build.sh fleet
# runs fleet's go vet and tests, then cross-compiles fleetd for macOS
# (arm64), all in a pinned Go image, so the Mac needs no Go. A failing check
# builds nothing. The binary lands in fleet/bin/fleetd.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/images.sh"
cli="${CONTAINER_CLI:-container}"
# Must be at least fleet/go.mod's go version; GOTOOLCHAIN=local refuses to
# download a newer one.
fleet_go_image=golang:1.27.4-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea

usage() {
  cat <<'EOF'
Build a pi-container image pack from the repo root context.

  build.sh [PACK] [container build options...]

Packs:
  agent-min  Pi, jq, git, ripgrep, fd; no enforcer, gh or Zig build stage
  agent      Pi, enforcer, jq, git, ripgrep, fd; no gh
  full       agent + gh (default); no Zig, Neovim or ZLS
  zig        full + Zig, zigpeek, Neovim, ZLS
  tools      Zig, zigpeek, enforcer, jq, git, ripgrep, fd; no Pi
  editor     tools + Neovim + ZLS
  all        build every pack
  fleet      not an image: cross-compile fleetd for macOS arm64 into
             fleet/bin/fleetd, inside a pinned Go image

Tags: pi-agent-min:local, pi-agent-lite:local, pi-agent:local,
      pi-agent-zig:local, pi-tools:local, pi-editor:local.
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

if [ "$pack" = fleet ]; then
  [ $# -eq 0 ] || { echo "build.sh: fleet takes no options" >&2; exit 2; }
  src=$(CDPATH= cd -- "$here/../fleet" && pwd -P)
  want=$(sed -n 's/^go //p' "$src/go.mod")
  have=${fleet_go_image#golang:}
  have=${have%%-*}
  if [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n 1)" != "$want" ]; then
    echo "build.sh: $fleet_go_image is Go $have; fleet/go.mod needs $want" >&2
    exit 1
  fi
  mkdir -p "$src/bin"
  # fleetd -version prints this; the release gate compares it to HEAD.
  commit=$(git -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)
  [ -z "$(git -C "$src/.." status --porcelain 2>/dev/null)" ] || commit="$commit-dirty"
  printf 'build.sh: fleet: go vet and go test, then %s/bin/fleetd %s (darwin/arm64, Go %s)\n' "$src" "$commit" "$have" >&2
  exec "$cli" run --rm -e GOTOOLCHAIN=local -e GOPROXY=off -e GOFLAGS=-mod=readonly -e CGO_ENABLED=0 \
    -e GOCACHE=/tmp/go-cache -e FLEETD_COMMIT="$commit" \
    -v "$src:/src:ro" -v "$src/bin:/out" -w /src \
    "$fleet_go_image" sh -c 'go vet ./... && go test -count=1 ./... &&
      GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-X main.commit=$FLEETD_COMMIT" -o /out/fleetd ./cmd/fleetd'
fi
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

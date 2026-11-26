#!/usr/bin/env bash
# Unit tests for the image pack catalog and build.sh argument handling.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
. "$root/images.sh"

eq tools "$(pi_pack_target tools)" "tools target"
eq editor "$(pi_pack_target editor)" "editor target"
eq agent-min "$(pi_pack_target agent-min)" "agent-min target"
eq agent "$(pi_pack_target agent)" "agent target"
eq full-zig "$(pi_pack_target zig)" "zig target"
eq full "$(pi_pack_target full)" "full target"
eq pi-tools:local "$(pi_pack_tag tools)" "tools tag"
eq pi-editor:local "$(pi_pack_tag editor)" "editor tag"
eq pi-agent-min:local "$(pi_pack_tag agent-min)" "agent-min tag"
eq pi-agent-lite:local "$(pi_pack_tag agent)" "agent tag"
eq pi-agent-zig:local "$(pi_pack_tag zig)" "zig tag"
eq pi-agent:local "$(pi_pack_tag full)" "full tag"
eq "tools editor agent-min agent full zig" "$pi_pack_names" "all pack names"
eq tools "$(pi_pack_for_tag pi-tools:local)" "tools tag maps back to pack"
eq agent-min "$(pi_pack_for_tag pi-agent-min:local)" "agent-min tag maps back to pack"
eq agent "$(pi_pack_for_tag pi-agent-lite:local)" "agent tag maps back to pack"
eq full "$(pi_pack_for_tag pi-agent:local)" "full tag maps back to pack"
eq zig "$(pi_pack_for_tag pi-agent-zig:local)" "zig tag maps back to pack"
rc 1 "the removed agent-gh pack is unknown" pi_pack_target agent-gh
rc 1 "unknown target rejected" pi_pack_target nope
rc 1 "unknown tag rejected" pi_pack_tag nope
rc 1 "unknown tag has no pack" pi_pack_for_tag nope:local
contains '--target agent' "$(pi_build_hint container pi-agent-lite:local /repo)" "build hint preserves pack target"
contains '--target agent-min' "$(pi_build_hint container pi-agent-min:local /repo)" "build hint preserves the agent-min target"
not_contains '--target' "$(pi_build_hint container custom:local /repo)" "unknown tag uses the default final stage"
rc 0 "build help needs no container" env CONTAINER_CLI=missing-container bash "$root/build.sh" --help
rc 2 "unknown pack rejected" env CONTAINER_CLI=true bash "$root/build.sh" nope

# The catalog and Dockerfile must name the same targets, with full as the last
# stage so a plain `container build` keeps producing the default image.
for p in $pi_pack_names; do
  target=$(pi_pack_target "$p")
  if grep -q "^FROM .* AS $target$" "$root/Dockerfile"; then pass; else fail "Dockerfile is missing target $target"; fi
done
last_from=$(awk '/^FROM /{line=$0} END{print line}' "$root/Dockerfile")
contains ' AS full' "$last_from" "full is the final Dockerfile stage"
# Only the zig-bearing packs carry Zig, zigpeek, Neovim or ZLS.
stage_body() { awk -v t="$1" '/^FROM /{on = ($NF == t)} on' "$root/Dockerfile"; }
for t in core agent agent-gh full; do
  body=$(stage_body "$t")
  not_contains "/opt/zig" "$body" "$t stage has no Zig"
  not_contains "nvim" "$body" "$t stage has no Neovim"
  not_contains "zls" "$body" "$t stage has no ZLS"
done
contains "enforcer" "$(stage_body core)" "core stage has enforcer"
contains "FROM agent-gh AS full" "$last_from" "full is agent-gh: Pi, gh and enforcer"
for t in tools full-zig; do
  contains "COPY --from=zig /opt/zig" "$(stage_body "$t")" "$t stage has Zig"
  contains "skills/zigpeek" "$(stage_body "$t")" "$t stage has the zigpeek skill"
done
contains 'PI_CONTAINER_CAPABILITIES="enforcer,netlock,pi,gh"' "$(stage_body agent-gh)" "full capabilities have no zig"
eq 6 "$(for p in $pi_pack_names; do pi_pack_tag "$p"; done | sort -u | wc -l | tr -d ' ')" "pack tags are unique"

# A target's stage chain: itself, then each FROM parent that is a stage.
stage_parent() { awk -v t="$1" '/^FROM /{ if ($NF == t) print $2 }' "$root/Dockerfile"; }
stage_chain() {
  local t=$1
  while grep -q "^FROM .* AS $t$" "$root/Dockerfile"; do
    printf '%s\n' "$t"
    t=$(stage_parent "$t")
  done
}
chain_body() { local t; for t in $(stage_chain "$1"); do stage_body "$t"; done; }
# The nearest PI_CONTAINER_CAPABILITIES in the chain is what the image records.
chain_caps() { chain_body "$1" | sed -n 's/.*PI_CONTAINER_CAPABILITIES="\([^"]*\)".*/\1/p' | head -n 1; }

eq "agent-min base" "$(stage_chain agent-min | tr '\n' ' ' | sed 's/ $//')" "agent-min is built FROM base only"
min=$(chain_body agent-min)
not_contains "COPY --from" "$min" "agent-min copies from no other stage, so it never waits for the zig stage"
not_contains "enforcer" "$min" "agent-min has no enforcer"
not_contains " gh" "$min" "agent-min has no gh"
not_contains "/opt/zig" "$min" "agent-min has no Zig"
contains "pi-coding-agent@" "$min" "agent-min installs Pi"
for tool in git jq ripgrep fd-find iptables curl; do
  contains " $tool " "$min" "agent-min has $tool"
done
eq "netlock,pi" "$(chain_caps agent-min)" "agent-min capabilities"
contains "COPY --from=zig /usr/local/bin/enforcer" "$(chain_body agent)" "agent still copies enforcer from the zig stage"

# Capabilities match contents for every pack.
for p in $pi_pack_names; do
  t=$(pi_pack_target "$p")
  body=$(chain_body "$t")
  caps=",$(chain_caps "$t"),"
  has_cap() { case $caps in *",$1,"*) return 0 ;; esac; return 1; }
  has_body() { printf '%s' "$body" | grep -qF -- "$1"; }
  for pair in "enforcer|/usr/local/bin/enforcer" "pi|pi-coding-agent@" "gh|install -y --no-install-recommends gh" \
              "zig|/opt/zig /opt/zig" "netlock|iptables" "nvim|/opt/nvim-linux-arm64 /opt/nvim-linux-arm64" "zls|/opt/zls /opt/zls"; do
    cap=${pair%%|*} needle=${pair#*|}
    if has_cap "$cap"; then
      has_body "$needle" && pass || fail "$p lists $cap but does not install it"
    else
      has_body "$needle" && fail "$p installs $cap but does not list it" || pass
    fi
  done
done

stages=" $(awk '/^FROM /{for(i=1;i<=NF;i++) if($i=="AS") print $(i+1)}' "$root/Dockerfile" | tr '\n' ' ') "
for ref in $(sed -n 's/.*COPY --from=\([^ ]*\).*/\1/p' "$root/Dockerfile" | sort -u); do
  case $stages in
    *" $ref "*) pass ;;
    *) fail "COPY --from=$ref names no Dockerfile stage" ;;
  esac
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/container" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$BUILD_LOG"
EOF
chmod +x "$tmp/container"
BUILD_LOG="$tmp/log" CONTAINER_CLI="$tmp/container" bash "$root/build.sh" agent --no-cache >/dev/null 2>&1
built=$(cat "$tmp/log" 2>/dev/null || true)
contains 'build --no-cache -t pi-agent-lite:local --target agent' "$built" "build.sh passes target and tag"
contains "-f $root/Dockerfile $root/.." "$built" "build.sh uses the repo root context"

fleet=$(cd "$root/../fleet" && pwd -P)
rm -f "$tmp/log"
BUILD_LOG="$tmp/log" CONTAINER_CLI="$tmp/container" bash "$root/build.sh" fleet >/dev/null 2>&1
built=$(cat "$tmp/log" 2>/dev/null || true)
contains "run --rm -e GOTOOLCHAIN=local -e GOPROXY=off" "$built" "fleet build never fetches a toolchain or module"
contains "GOOS=darwin GOARCH=arm64 go build" "$built" "fleet build targets macOS arm64"
contains "-v $fleet:/src:ro -v $fleet/bin:/out" "$built" "fleet source is read-only; only bin is written"
contains "golang:" "$built" "fleet build uses the Go image"
contains "@sha256:" "$built" "fleet Go image is pinned by digest"
contains 'go build -trimpath -ldflags "-X main.commit=$FLEETD_COMMIT" -o /out/fleetd ./cmd/fleetd' "$built" "fleet build compiles fleetd"
contains "-e FLEETD_COMMIT=$(git -C "$root/.." rev-parse HEAD)" "$built" "fleet build stamps the commit"
contains "go vet ./... && go test -count=1 ./... &&" "$built" "fleet build runs vet and tests first, and stops if they fail"
rc 2 "fleet takes no options" env CONTAINER_CLI="$tmp/container" BUILD_LOG="$tmp/log" bash "$root/build.sh" fleet --no-cache
image_go=$(sed -n 's/^fleet_go_image=golang:\([0-9.]*\)-.*/\1/p' "$root/build.sh")
mod_go=$(sed -n 's/^go //p' "$fleet/go.mod")
eq "$mod_go" "$(printf '%s\n%s\n' "$mod_go" "$image_go" | sort -V | head -n 1)" "the Go image ($image_go) is at least go.mod's Go ($mod_go)"

finish

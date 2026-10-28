#!/usr/bin/env bash
# Unit tests for the image pack catalog and build.sh argument handling.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
. "$root/images.sh"

eq tools "$(pi_pack_target tools)" "tools target"
eq editor "$(pi_pack_target editor)" "editor target"
eq agent "$(pi_pack_target agent)" "agent target"
eq agent-gh "$(pi_pack_target agent-gh)" "agent-gh target"
eq full "$(pi_pack_target full)" "full target"
eq pi-tools:local "$(pi_pack_tag tools)" "tools tag"
eq pi-editor:local "$(pi_pack_tag editor)" "editor tag"
eq pi-agent-lite:local "$(pi_pack_tag agent)" "agent tag"
eq pi-agent-gh:local "$(pi_pack_tag agent-gh)" "agent-gh tag"
eq pi-agent:local "$(pi_pack_tag full)" "full tag"
eq "tools editor agent agent-gh full" "$pi_pack_names" "all pack names"
eq tools "$(pi_pack_for_tag pi-tools:local)" "tools tag maps back to pack"
eq agent "$(pi_pack_for_tag pi-agent-lite:local)" "agent tag maps back to pack"
eq full "$(pi_pack_for_tag pi-agent:local)" "full tag maps back to pack"
rc 1 "unknown target rejected" pi_pack_target nope
rc 1 "unknown tag rejected" pi_pack_tag nope
rc 1 "unknown tag has no pack" pi_pack_for_tag nope:local
contains '--target agent' "$(pi_build_hint container pi-agent-lite:local /repo)" "build hint preserves pack target"
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
eq 5 "$(for p in $pi_pack_names; do pi_pack_tag "$p"; done | sort -u | wc -l | tr -d ' ')" "pack tags are unique"
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

finish

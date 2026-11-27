#!/usr/bin/env bash
# On a Mac: record the container install, kernel, networks, volume labels,
# parser results and VM netfilter that pi-container depends on. Run it before
# and after a `container` upgrade and diff the outputs (docs/container-1.7.1.md
# has the 1.6.1 -> 1.7.1 results). Changes nothing except one throwaway `--rm`
# VM.
#
#   test/container-probe.sh > ~/probe-$(container --version | awk '{print $NF}').txt
#
# Output is redacted: $HOME and the account name are replaced, and strings
# that look like API keys or tokens are masked. Only volume labels are read,
# never volume contents, env files or auth.json.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(CDPATH= cd -- "$here/.." && pwd -P)
. "$root/names.sh"
. "$root/lib/inspect.sh"
cli=${CONTAINER_CLI:-container}
cfg="${PI_CONFIG_DIR:-$(pi_default_config_dir)}"
net="${PI_NETWORK_NAME:-$(pi_network_name "$cfg")}"
proxy="${PI_PROXY_NAME:-$(pi_proxy_name "$cfg")}"
app="$HOME/Library/Application Support/com.apple.container"
for c in "$cli" jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "container-probe.sh: $c not found" >&2; exit 2; }
done

# A name shorter than 3 characters would mangle unrelated output. The host
# name is left alone: it is often a prefix of the GitHub owner in repo labels.
who=$(id -un)
[ ${#who} -ge 3 ] || who='\$USER'
redact() {
  sed -E \
    -e "s|$HOME|\$HOME|g" \
    -e "s|$who|\$USER|g" \
    -e 's/(gh[pousr]_|github_pat_|sk-or-v1-|sk-ant-|sk-|hf_|tskey-)[A-Za-z0-9_-]{6,}/\1REDACTED/g' \
    -e 's/([A-Za-z_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Za-z_]*=)[^[:space:]]+/\1REDACTED/g'
}

section() { printf '\n== %s\n' "$*"; }

probe() {
  section host
  sw_vers 2>&1 | tr '\n' ' '; echo
  echo "arch $(uname -m), cpus $(sysctl -n hw.ncpu), mem $(( $(sysctl -n hw.memsize) / 1073741824 ))G"
  echo "container --version: $("$cli" --version 2>&1)"
  type -a container 2>&1
  for p in /usr/local/bin/container /opt/homebrew/bin/container /usr/local/bin/update-container.sh /usr/local/bin/uninstall-container.sh; do
    [ -e "$p" ] && echo "present: $p$( [ -L "$p" ] && echo " -> $(readlink "$p")")"
  done
  pkgutil --pkgs 2>/dev/null | grep -i container | while read -r p; do
    echo "pkg: $p $(pkgutil --pkg-info "$p" 2>/dev/null | awk '/^version/ {print $2}')"
  done
  command -v brew >/dev/null 2>&1 && echo "brew container: $(brew list --versions container 2>/dev/null || echo none)"

  section system
  "$cli" system version 2>&1
  "$cli" system status 2>&1
  "$cli" system property list 2>&1
  echo "--- kernels (default is what VMs boot; an upgrade does not replace it)"
  ls -l "$app/kernels" 2>&1
  echo "--- user config.toml files"
  for f in "$HOME/.config/container/config.toml" "$app/config.toml"; do
    [ -f "$f" ] && { echo "# $f"; grep -v '^[[:space:]]*#' "$f"; }
  done
  echo "--- app root"
  ls "$app" 2>&1 | tr '\n' ' '; echo
  du -sh "$app"/* 2>/dev/null
  echo "--- Time Machine exclusion (1.7.1 excludes containers/ and snapshots/ when it creates them)"
  for d in containers volumes snapshots content; do
    [ -d "$app/$d" ] && echo "$d: $(tmutil isexcluded "$app/$d" 2>/dev/null | awk '{print $1}')"
  done
  "$cli" system df 2>&1

  section builder
  "$cli" builder status 2>&1

  section containers
  "$cli" list --all 2>&1

  section "volumes (labels only)"
  "$cli" volume list 2>&1 | head -n 1
  "$cli" volume list -q 2>/dev/null | while read -r v; do
    printf '%s ' "$v"
    "$cli" volume inspect "$v" 2>/dev/null | jq -c '.[0] | {labels: (.configuration.labels // {}), keys: (.configuration | keys)}' 2>&1
  done
  echo "--- raw shape of the first volume"
  first=$("$cli" volume list -q 2>/dev/null | head -n 1)
  [ -n "$first" ] && "$cli" volume inspect "$first" 2>&1 | jq 'paths(scalars) | map(tostring) | join(".")' 2>&1 | head -n 40

  section networks
  "$cli" network list 2>&1
  "$cli" network list -q 2>/dev/null | while read -r n; do
    "$cli" network inspect "$n" 2>/dev/null | jq -c '.[0] | {id, mode: .configuration.mode, cfg: .configuration.ipv4Subnet, status: .status.ipv4Subnet, gw: .status.ipv4Gateway, keys: (.configuration | keys)}' 2>&1
  done
  echo "host-only verdict for $net: $("$cli" network inspect "$net" 2>/dev/null | pi_network_host_only_verdict 2>&1 || echo '?')"
  echo "default gateway (parser): $("$cli" network inspect default 2>/dev/null | pi_network_gateway_from_json 2>&1 || echo '?')"

  section images
  "$cli" image list 2>&1
  tag=$(bash "$root/run.sh" config --json 2>/dev/null | jq -r '.tag // empty')
  echo "active tag: ${tag:-?}"
  if [ -n "$tag" ] && json=$("$cli" image inspect "$tag" 2>/dev/null); then
    echo "version (parser): $(printf '%s\n' "$json" | pi_image_version_from_json 2>&1)"
    echo "capabilities (parser): $(printf '%s\n' "$json" | pi_image_capabilities_from_json 2>&1 | tr '\n' ' ')"
    printf '%s\n' "$json" | jq -c '.[0] | {keys: keys, variants: (.variants | length), platforms: [.variants[].platform | "\(.os)/\(.architecture)"]}' 2>&1
  fi

  section proxy
  if json=$("$cli" inspect "$proxy" 2>/dev/null); then
    echo "$proxy state (parser): $(printf '%s\n' "$json" | pi_proxy_state_from_json 2>&1)"
    printf '%s\n' "$json" | jq -c '.[0] | {keys: keys, status: .status, image: .configuration.image.reference, labels: .configuration.labels}' 2>&1
  else
    echo "$proxy: none"
  fi
  echo "--- lifecycle on a missing name (1.7.1 routes these through a plugin-aware lookup)"
  for c in stop start kill delete; do
    out=$("$cli" "$c" pi-probe-missing-$$ 2>&1); echo "$c: exit $? $(printf '%s' "$out" | head -n 1)"
  done

  section "CLI flags we pass"
  "$cli" run --help 2>&1 | grep -oE -- '--(cap-add|cap-drop|cpus|memory|dns[a-z-]*|init|network|label|rm|volume|env-file)' | sort -u | tr '\n' ' '; echo
  "$cli" network create --help 2>&1 | grep -oE -- '--(internal|subnet[a-z-]*|label)' | sort -u | tr '\n' ' '; echo
  "$cli" volume create --help 2>&1 | grep -oE -- '--(label|opt)' | sort -u | tr '\n' ' '; echo
  [ -z "$tag" ] || echo "--cpus above host cores: $("$cli" run --rm --cpus 999 "$tag" true 2>&1 | grep -i -m 1 error || echo accepted)"

  section "VM kernel and netfilter (one --rm VM on the default network, no proxy)"
  if [ -n "$tag" ]; then
    "$cli" run --rm --cap-add NET_ADMIN --network default --cpus 1 --memory 1G "$tag" sh -c '
      echo "uname: $(uname -r)"
      head -c 200 /proc/version; echo
      for t in iptables-legacy ip6tables-legacy iptables; do
        if command -v $t >/dev/null 2>&1; then
          $t -w -S OUTPUT >/dev/null 2>&1 && echo "$t: ok" || echo "$t: FAIL"
        else echo "$t: missing"; fi
      done
      [ -e /proc/net/nf_conntrack ] && echo "nf_conntrack: yes" || echo "nf_conntrack: no"
      grep -h "^CapEff" /proc/self/status
      echo "nproc $(nproc)"
      grep -v "^#" /etc/resolv.conf
    ' 2>&1
  fi
}

probe 2>&1 | redact

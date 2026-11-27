#!/usr/bin/env bash
# On a Mac: check the container 1.7.1 migration (docs/container-1.7.1.md)
# and print one PASS, WARN or FAIL line per check, ready to paste. Run it
# before the nuke too: then only the version and kernel lines should fail.
#
#   test/migrate-check.sh [EXPORT_DIR]
#
# EXPORT_DIR is what `clear.sh export` wrote; the default is the newest
# export-* in the backup dir. Each exported volume's labels and file counts
# are compared with the live volume. Changes nothing but throwaway `--rm`
# VMs. Paths print as $HOME/...; env files and file contents are never read.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(CDPATH= cd -- "$here/.." && pwd -P)
. "$root/names.sh"
. "$root/lib/paths.sh"
. "$root/lib/config.sh"
. "$root/lib/inspect.sh"
cli=${CONTAINER_CLI:-container}
want_version=${PI_WANT_CONTAINER:-1.7.1}
want_kernel=${PI_WANT_KERNEL:-6.18.56}
app="$HOME/Library/Application Support/com.apple.container"
pic=$(pi_pic_home)
pi_overrides_load "$pic/overrides.env" || true
cfg=${PI_CONFIG_DIR:-$(pi_default_config_dir)}
backups=${PI_BACKUP_DIR:-$(pi_backup_dir)}
net=${PI_NETWORK_NAME:-$(pi_network_name "$cfg")}
export_dir=${1:-$(ls -d "$backups"/export-* 2>/dev/null | sort | tail -n 1)}
for c in "$cli" jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "migrate-check.sh: $c not found" >&2; exit 2; }
done

fails=0 warns=0
pass() { echo "PASS $*"; }
warn() { warns=$((warns + 1)); echo "WARN $*"; }
fail() { fails=$((fails + 1)); echo "FAIL $*"; }

who=$(id -un)
[ ${#who} -ge 3 ] || who='\$USER'
redact() {
  sed -E \
    -e "s|$HOME|\$HOME|g" \
    -e "s|$who|\$USER|g" \
    -e 's/(gh[pousr]_|github_pat_|sk-or-v1-|sk-ant-|sk-|hf_|tskey-)[A-Za-z0-9_-]{6,}/\1REDACTED/g' \
    -e 's/([A-Za-z_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Za-z_]*=)[^[:space:]]+/\1REDACTED/g'
}

check_cli() {
  local v server n
  v=$("$cli" --version 2>&1 | head -n 1)
  case $v in *" $want_version "*|*" $want_version") pass "cli: $v" ;; *) fail "cli: $v (want $want_version)" ;; esac
  server=$("$cli" system version 2>/dev/null | awk '$1 == "container-apiserver" {print $2}')
  [ "$server" = "$want_version" ] && pass "apiserver: $server" || fail "apiserver: ${server:-not running} (want $want_version; container system start)"
  n=$(type -a container 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = 1 ] && pass "one container on PATH" || fail "$n container binaries on PATH: $(type -a container 2>&1 | tr '\n' ' ')"
  if command -v brew >/dev/null 2>&1 && brew list --versions container >/dev/null 2>&1; then
    warn "Homebrew container is also installed (brew uninstall container)"
  fi
}

check_kernel() {
  local k
  k=$(readlink "$app/kernels/default.kernel-arm64" 2>/dev/null)
  case ${k##*/} in
    vmlinux-"$want_kernel"*) pass "default kernel: ${k##*/}" ;;
    '') fail "no default kernel (container system kernel set --recommended)" ;;
    *) fail "default kernel: ${k##*/} (want $want_kernel; container system kernel set --recommended)" ;;
  esac
  k=$("$cli" system property list 2>/dev/null | sed -n 's/^image = "\(.*vminit.*\)"$/\1/p' | head -n 1)
  echo "INFO vminit: ${k:-?}"
}

check_layout() {
  local legacy m
  if [ -d "$pic" ]; then
    m=$(pi_file_mode "$pic")
    [ "$m" = 700 ] && pass "$pic mode 700" || warn "$pic mode $m (want 700)"
  else
    fail "$pic missing (run.sh migrate)"
  fi
  legacy=$(pi_legacy_message "$backups")
  [ -z "$legacy" ] && pass "no v7 paths left" || fail "$legacy"
  if [ -f "$cfg/env" ]; then
    m=$(pi_file_mode "$cfg/env")
    [ "$m" = 600 ] && pass "$cfg/env mode 600" || fail "$cfg/env mode $m (want 600)"
  else
    fail "$cfg/env missing"
  fi
  [ -f "$cfg/settings.json" ] && pass "$cfg/settings.json present" || warn "$cfg/settings.json missing (run.sh recreates it)"
  [ ! -e "$pic/overrides.env" ] || echo "INFO overrides.env: $(grep -v '^#' "$pic/overrides.env" | cut -d= -f1 | tr '\n' ' ')"
}

check_volumes() { # image
  local img=$1 f vol want got counts tar_n tar_j vol_n vol_j n=0
  if [ -z "$export_dir" ] || [ ! -d "$export_dir" ]; then
    warn "no export found in $backups (clear.sh export, or pass EXPORT_DIR)"
    return
  fi
  echo "INFO export: $export_dir ($(du -sh "$export_dir" 2>/dev/null | awk '{print $1}'))"
  for f in "$export_dir"/*.labels.json; do
    [ -f "$f" ] || continue
    vol=$(basename "$f" .labels.json)
    n=$((n + 1))
    if ! got=$("$cli" volume inspect "$vol" 2>/dev/null); then
      fail "$vol: not imported (clear.sh import $export_dir)"
      continue
    fi
    want=$(jq -c '{k: ."pi.kind", i: ."pi.instance", p: ."pi.profile", r: ."pi.repo", m: ."pi.managed"}' "$f")
    got=$(printf '%s\n' "$got" | jq -c '.[0].configuration.labels // {} | {k: ."pi.kind", i: ."pi.instance", p: ."pi.profile", r: ."pi.repo", m: ."pi.managed"}')
    [ "$want" = "$got" ] || { fail "$vol: labels $got, exported $want"; continue; }
    case $("$cli" volume inspect "$vol" | jq -r '.[0].configuration.labels."pi.config" // ""') in
      # v8 reads default-profile volumes either way; only clear.sh import rewrites labels.
      "${HOME%/}/.config/pi-container"*) echo "INFO $vol: pi.config still names the v7 path (fine; import rewrites it)" ;;
    esac
    tar_n=$(tar -tf "$export_dir/$vol.tar" 2>/dev/null | grep -vc '^\./$')
    tar_j=$(tar -tf "$export_dir/$vol.tar" 2>/dev/null | grep -c '\.jsonl$')
    if [ -z "$img" ]; then
      warn "$vol: labels match; no image to count files with"
      continue
    fi
    counts=$("$cli" run --rm --user 0 -v "$vol:/v:ro" "$img" sh -c \
      'cd /v && find . -mindepth 1 ! -path ./auth.json | wc -l; find . -name "*.jsonl" | wc -l' 2>/dev/null | tr -d ' ' | tr '\n' ' ')
    read -r vol_n vol_j <<<"$counts"
    if [ "${vol_n:-}" = "$tar_n" ] && [ "${vol_j:-}" = "$tar_j" ]; then
      pass "$vol: labels, $vol_n entries, $vol_j sessions"
    elif [ "${vol_j:-x}" -ge "$tar_j" ] 2>/dev/null && [ "${vol_n:-0}" -ge "$tar_n" ]; then
      warn "$vol: $vol_n entries, $vol_j sessions; export had $tar_n, $tar_j (new since import?)"
    else
      fail "$vol: $vol_n entries, $vol_j sessions; export had $tar_n, $tar_j"
    fi
  done
  [ "$n" -gt 0 ] || fail "no *.labels.json in $export_dir"
  [ "$n" -eq 0 ] || echo "INFO exported volumes: $n, pi-managed now: $("$cli" volume list -q 2>/dev/null | while read -r v; do "$cli" volume inspect "$v" | jq -r '.[0].configuration.labels."pi.managed" // empty'; done | grep -c true)"
}

check_runtime() { # image
  local img=$1 out
  if "$root/clear.sh" list >/tmp/pic-list.$$ 2>&1; then
    grep -q '(missing)' /tmp/pic-list.$$ && warn "clear.sh list shows (missing)" || pass "clear.sh list"
  else
    fail "clear.sh list: $(tail -n 1 /tmp/pic-list.$$)"
  fi
  rm -f /tmp/pic-list.$$
  if out=$("$cli" network inspect "$net" 2>/dev/null); then
    case $(printf '%s\n' "$out" | pi_network_host_only_verdict) in
      ok) pass "$net is host-only" ;;
      *) fail "$net is not host-only" ;;
    esac
  else
    echo "INFO $net not created yet (the first run.sh creates it)"
  fi
  [ -n "$img" ] || { fail "no agent image (build.sh full)"; return; }
  out=$("$cli" run --rm --cap-add NET_ADMIN --network default --cpus 1 --memory 1G "$img" sh -c '
    echo "uname $(uname -r)"
    for t in iptables-legacy ip6tables-legacy; do
      $t -w -S OUTPUT >/dev/null 2>&1 && echo "$t ok" || echo "$t FAIL"
    done' 2>&1 | grep -E '^(uname|ip6?tables-legacy) ')
  case $(printf '%s\n' "$out" | awk '$1 == "uname" {print $2}') in
    "$want_kernel"*) pass "VM kernel $(printf '%s\n' "$out" | awk '$1 == "uname" {print $2}')" ;;
    *) fail "VM kernel $(printf '%s\n' "$out" | awk '$1 == "uname" {print $2}') (want $want_kernel)" ;;
  esac
  for t in iptables-legacy ip6tables-legacy; do
    printf '%s\n' "$out" | grep -qx "$t ok" && pass "VM $t" || fail "VM $t: egress lock cannot load"
  done
  if out=$(bash "$root/run.sh" check 2>&1); then
    pass "run.sh check"
  else
    fail "run.sh check:"
    printf '%s\n' "$out" | tail -n 15 | sed 's/^/  /'
  fi
}

main() {
  local img
  echo "migrate-check $(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo ?)"
  check_cli
  check_kernel
  check_layout
  img=$(bash "$root/run.sh" config --json 2>/dev/null | jq -r '.tag // empty')
  [ -z "$img" ] || "$cli" image inspect "$img" >/dev/null 2>&1 || img=""
  check_volumes "$img"
  check_runtime "$img"
  echo "fails=$fails warns=$warns"
}

main 2>&1 | redact

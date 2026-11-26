#!/usr/bin/env bash
# The release gate (E2E.md "Release"). Each stage records its checks in
# $PI_RELEASE_DIR/<sha>/<stage>.json (default /Users/Shared/pi-release, so
# the test account and your main account share it). Output is redacted:
# keys, tokens, emails, tailnet names and tailnet IPs never print.
#
#   test/release.sh                        what passed for HEAD, and the
#                                          next command to run
#   test/release.sh fleet --repo R         main account, `pic serve` up:
#                                          fleet/docs/macos.md step 8
#   test/release.sh tester NAME --env FILE --repo O/R
#                                          main account (admin), after
#                                          stopping `pic serve`: recreate
#                                          the test account NAME with FILE,
#                                          O/R and a clone at HEAD in it
#   test/release.sh account                test account: fresh, then the
#                                          README setup, verify and manual;
#                                          reruns only what has not passed
#   test/release.sh fresh                  the account stages one at a
#   test/release.sh verify --repo O/R      time: fresh before any setup,
#   test/release.sh manual                 verify (script tests and
#                                          mac-e2e.sh build auto) after it,
#                                          manual (the TUI checks) last
#   test/release.sh report                 merge the stages into
#                                          release.json and print the gate
#   test/release.sh publish TAG [--push]   main account: refuse unless the
#                                          gate passes for HEAD, then tag;
#                                          --push pushes the tag and makes
#                                          a GitHub release with release.json
#
# Every stage checks out the same SHA: HEAD of a clean tree. E2E.md lists
# what else closes the gate.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
pc=$(CDPATH= cd -- "$here/.." && pwd -P)
top=$(CDPATH= cd -- "$pc/.." && pwd -P)
. "$pc/names.sh"
. "$pc/lib/release.sh"
. "$pc/lib/paths.sh"

die() { echo "release.sh: $*" >&2; exit 2; }
upstream=TanGentleman/tan-toolchains

# A fresh standard account has no Homebrew on PATH; use the shared install
# for this run and tell the user how to make it permanent.
brew_bin=""
for b in "$(command -v brew 2>/dev/null)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -n "$b" ] && [ -x "$b" ] && { brew_bin=$b; break; }
done
brew_on_path=0
command -v brew >/dev/null 2>&1 && brew_on_path=1
[ -z "$brew_bin" ] || [ "$brew_on_path" = 1 ] || eval "$("$brew_bin" shellenv)"
command -v jq >/dev/null 2>&1 || die "jq not found; run the README's 'brew install container jq' first"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
stage=${1:-status}
case $stage in -h | --help | help) usage; exit 0 ;; esac
shift || true

sha=$(git -C "$top" rev-parse HEAD 2>/dev/null) || die "$top is not a git checkout"
dir=${PI_RELEASE_DIR:-/Users/Shared/pi-release}/$sha
mkdir -p "$dir" 2>/dev/null || die "cannot create $dir"
chmod 1777 "${dir%/*}" "$dir" 2>/dev/null || true

# Values to redact: every key-like value in the env files this user has.
tester_env=""
if [ "$stage" = tester ]; then
  prev=""
  for a in "$@"; do [ "$prev" = --env ] && tester_env=$a; prev=$a; done
fi
secrets=()
# The tester stage stages its env file at ~/.pi-release/env in the test account.
staged=$HOME/.pi-release
for f in "${PI_ENV_FILE:-}" "${PI_CONFIG_DIR:+$PI_CONFIG_DIR/env}" "$(pi_default_config_dir)/env" "$HOME/.cache/pi-e2e/cfg/env" "$staged/env" \
  ${tester_env:+"$tester_env"}; do
  [ -n "$f" ] && [ -r "$f" ] || continue
  for k in OPENROUTER_API_KEY GITHUB_TOKEN GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL; do
    v=$(rel_env_value "$f" "$k")
    [ -n "$v" ] && secrets+=("$v")
  done
done
[ -n "${OPENROUTER_API_KEY:-}" ] && secrets+=("$OPENROUTER_API_KEY")
[ -n "${GITHUB_TOKEN:-}" ] && secrets+=("$GITHUB_TOKEN")
redact() { rel_redact ${secrets[@]+"${secrets[@]}"}; }

results=$(mktemp "${TMPDIR:-/tmp}/release.XXXXXX")
trap 'rm -f "$results"' EXIT
nfail=0
rec() {
  printf '%s\t%s\n' "$1" "$2" >>"$results"
  case $1 in
    pass) echo "  ok    $2" ;;
    fail) nfail=$((nfail + 1)); echo "  FAIL  $2${3:+ ($3)}" ;;
    skip) echo "  skip  $2${3:+ ($3)}" ;;
  esac
}
is() { [ "$1" = "$2" ]; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then rec pass "$d"; else rec fail "$d"; fi; }
first_line() { "$@" 2>/dev/null | head -n 1; }
pin() { sed -n "s/^ARG $1=//p" "$pc/Dockerfile" | head -n 1; }

facts() {
  local clt
  clt=$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | sed -n 's/^version: //p')
  jq -n \
    --arg macos "$(sw_vers -productVersion 2>/dev/null)" \
    --arg build "$(sw_vers -buildVersion 2>/dev/null)" \
    --arg arch "$(uname -m)" \
    --arg admin "$(id -Gn | tr ' ' '\n' | grep -qx admin && echo true || echo false)" \
    --arg brew "$(rel_semver "$(first_line "${brew_bin:-false}" --version)")" \
    --arg brew_prefix "$( [ -n "$brew_bin" ] && "$brew_bin" --prefix 2>/dev/null)" \
    --arg brew_writable "$( [ -n "$brew_bin" ] && [ -w "$("$brew_bin" --prefix)" ] && echo true || echo false)" \
    --arg container "$(rel_semver "$(first_line container --version)")" \
    --arg jq "$(jq --version 2>/dev/null)" \
    --arg git "$(rel_semver "$(first_line git --version)")" \
    --arg bash "$BASH_VERSION" \
    --arg clt "$clt" \
    --arg xcode_path "$(xcode-select -p 2>/dev/null)" \
    --arg tailscale "$(rel_semver "$(first_line tailscale version)")" \
    '{macos: $macos, macos_build: $build, arch: $arch, admin: ($admin == "true"),
      homebrew: $brew, homebrew_prefix: $brew_prefix,
      homebrew_writable: ($brew_writable == "true"), container: $container,
      jq: $jq, git: $git, bash: $bash, clt: $clt, xcode_path: $xcode_path,
      tailscale: $tailscale}'
}

pins() {
  jq -n \
    --arg base "$(sed -n 's/^FROM \(node:[^ ]*\) AS base$/\1/p' "$pc/Dockerfile")" \
    --arg pi "$(pin PI_VERSION)" --arg zig "$(pin ZIG_VERSION)" \
    --arg nvim "$(pin NVIM_VERSION)" --arg zls "$(pin ZLS_VERSION)" \
    --arg go "$(sed -n 's/^fleet_go_image=//p' "$pc/build.sh")" \
    --arg contract "$pi_release_container_version" \
    '{base_image: $base, pi: $pi, zig: $zig, nvim: $nvim, zls: $zls,
      fleet_go_image: $go, container_contract: $contract}'
}

# gh when it is logged in (unauthenticated API calls are rate-limited).
ci_status() {
  local api=repos/$upstream/commits/$sha/check-runs?per_page=100 json
  if command -v gh >/dev/null 2>&1 && json=$(gh api "$api" 2>/dev/null); then :
  elif json=$(curl -fsS --max-time 15 "https://api.github.com/$api" 2>/dev/null); then :
  else echo unknown; return; fi
  printf '%s\n' "$json" | rel_ci_conclusion 2>/dev/null || echo unknown
}

tree_checks() {
  check "the tree is clean" sh -c '[ -z "$(git -C "$1" status --porcelain)" ]' sh "$top"
  check "HEAD $sha is on $upstream" sh -c \
    'git -C "$1" ls-remote "https://github.com/$2" | cut -f1 | grep -qx "$3" ||
     git -C "$1" fetch -q "https://github.com/$2" "$3"' sh "$top" "$upstream" "$sha"
}

# The test account's id from tester, so a record from an earlier account
# with the same name never counts for this one. Empty in other accounts.
account_id=$(cat "$staged/id" 2>/dev/null || true)

# new_file PATH: PATH is empty and this account can write it. A file left by
# another account (the sticky release dir) refuses, so stale output is never
# read back as this run's.
new_file() {
  rm -f "$1" 2>/dev/null
  : 2>/dev/null >"$1" || die "cannot write $1 (left by another account?); remove it with sudo rm"
}

save() {
  local extra=${1:-'{}'}
  new_file "$dir/$stage.json.$$"
  rel_checks_json "$stage" "$(id -un)" <"$results" |
    jq --arg sha "$sha" --arg id "$account_id" --argjson extra "$extra" \
      '. + {sha: $sha, account_id: $id} + $extra' | redact >"$dir/$stage.json.$$"
  chmod 644 "$dir/$stage.json.$$"
  mv -f "$dir/$stage.json.$$" "$dir/$stage.json" || die "cannot replace $dir/$stage.json; remove it with sudo rm"
  echo "release.sh: $stage: $(jq -r '"\(.pass) passed, \(.fail) failed, \(.skip) skipped"' "$dir/$stage.json") -> $dir/$stage.json"
  [ "$nfail" = 0 ]
}

stage_fresh() {
  echo "== Fresh account ($sha)"
  tree_checks
  local f uid mac_major
  uid=$(id -u)
  mac_major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
  check "macOS $pi_release_macos_major (have $(sw_vers -productVersion 2>/dev/null))" is "$mac_major" "$pi_release_macos_major"
  check "Apple silicon" is "$(uname -m)" arm64
  check "Xcode command-line tools (xcode-select -p)" xcode-select -p
  if [ -z "$brew_bin" ]; then
    rec fail "Homebrew is installed" "install it from https://brew.sh as an admin"
  elif /bin/zsh -lc 'command -v brew' </dev/null >/dev/null 2>&1; then
    rec pass "brew is on PATH in a login shell"
  else
    rec fail "brew is on PATH in a login shell" \
      "add it: echo 'eval \"\$($brew_bin shellenv)\"' >> ~/.zprofile"
  fi
  check "container is installed" sh -c 'command -v container'
  local cv
  cv=$(rel_semver "$(first_line container --version)")
  if [ "$cv" = "$pi_release_container_version" ]; then
    rec pass "container $cv is the observed JSON contract"
  else
    rec fail "container ${cv:-?} is the observed JSON contract $pi_release_container_version" \
      "record fixtures with test/record-fixtures.sh and update AGENTS.md first"
  fi
  # Also state a new account lacks that would hide a dependency on it.
  for f in "$(pi_default_config_dir)" "$HOME/.fleet" "$HOME/pi-backups" "$HOME/.cache/pi-e2e" \
    "$HOME/Library/Application Support/com.apple.container" \
    "$HOME/.gitconfig" "$HOME/.config/git" "$HOME/.config/gh" "$HOME/.ssh"; do
    check "no ~/${f#"$HOME"/}" test ! -e "$f"
  done
  # comm is the executable, so these never match their own command line.
  check "container system not started in this account" sh -c \
    '! ps -axo uid=,comm= | awk -v u="$1" "\$1 == u" | grep -q "container-apiserver$"' sh "$uid"
  check "no other account runs container (stop it there: container system stop)" sh -c \
    '! ps -axo uid=,comm= | awk -v u="$1" "\$1 != u" | grep -q "container-apiserver$"' sh "$uid"
  check "no fleetd running (stop pic serve)" sh -c '! ps -axo comm= | grep -q "/fleetd$"'
  [ "$brew_on_path" = 1 ] || echo "release.sh: brew was not on PATH; used $brew_bin for this run"
  save "$(jq -n --argjson facts "$(facts)" --argjson pins "$(pins)" '{facts: $facts, pins: $pins}')"
}

stage_verify() {
  local repo="" log
  while [ $# -gt 0 ]; do
    case $1 in
      --repo) [ $# -ge 2 ] || die "--repo needs OWNER/REPO"; repo=$2; shift 2 ;;
      *) die "verify: unknown argument '$1'" ;;
    esac
  done
  [ -n "$repo" ] || die "verify needs --repo OWNER/REPO (the throwaway repo)"
  echo "== Script checks ($sha)"
  tree_checks
  log=$dir/verify-run-tests.log
  new_file "$log"
  (cd "$pc" && ./test/run-tests.sh) >"$log" 2>&1
  check "test/run-tests.sh" grep -q "run-tests.sh: all tests passed" "$log"
  local f bad=""
  for f in "$pc"/*.sh "$pc"/lib/*.sh "$pc"/test/*.sh "$top"/enforcer/test/*.sh "$top"/fleet/e2e/*.sh; do
    bash -n "$f" 2>/dev/null || bad="$bad ${f#$top/}"
  done
  check "bash -n on every script" is "$bad" ""
  check "proxy.py compiles" env PYTHONDONTWRITEBYTECODE=1 python3 -c \
    'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$pc/proxy.py"
  echo "== test/mac-e2e.sh build auto (this takes a while)"
  log=$dir/verify-mac-e2e.log
  new_file "$log"
  "$here/mac-e2e.sh" --repo "$repo" build auto 2>&1 | redact | tee "$log"
  rel_e2e_lines <"$log" >>"$results"
  nfail=$((nfail + $(grep -c '^fail' "$results")))
  grep -q '^mac-e2e.sh: [0-9]* passed' "$log" || rec fail "mac-e2e.sh ran to the end" "see $log"
  digest() { container image inspect "$1" 2>/dev/null | jq -r '.[0].configuration.descriptor.digest // empty' 2>/dev/null; }
  save "$(jq -n --arg d "$(digest pi-full:local)" --arg z "$(digest pi-zig:local)" --arg r "${repo%%/*}/<throwaway>" \
    '{images: {"pi-full:local": $d, "pi-zig:local": $z}, repo: $r}')"
}

ask() {
  local a
  while :; do
    printf '%s\n  [y]es / [n]o / [s]kip: ' "$1" >/dev/tty
    read -r a </dev/tty || a=s
    case $a in
      y | Y) rec pass "$1"; return ;;
      n | N) printf '  note: ' >/dev/tty; read -r a </dev/tty; rec fail "$1" "$a"; return ;;
      s | S) printf '  why: ' >/dev/tty; read -r a </dev/tty; rec skip "$1" "$a"; return ;;
    esac
  done
}

stage_manual() {
  [ -r /dev/tty ] || die "manual needs a terminal"
  echo "== E2E.md checks that need the Pi TUI (in the e2e profile: see E2E.md)"
  ask "/model lists OpenRouter models; /quit exits; no /login needed"
  ask "settings.json hash unchanged after /settings and Ctrl+S saves"
  ask "a host settings.json edit applies on the next run"
  ask "the enforcer warns on a ghp_ prompt in the TUI"
  ask "pi in --manual reports no models"
  ask "./run.sh proxy follows the proxy logs"
  save
}

stage_fleet() {
  local repo="" pid log exe fleetd_commit="" proxy n0 why cfg served
  while [ $# -gt 0 ]; do
    case $1 in
      --repo) repo=${2:-}; shift 2 || shift ;;
      *) die "fleet: unknown argument $1" ;;
    esac
  done
  case $repo in */*) ;; *) die "usage: test/release.sh fleet --repo OWNER/REPO" ;; esac
  echo "== fleet/docs/macos.md step 8 ($sha)"
  tree_checks
  check "tailscale is installed" sh -c 'command -v tailscale'
  check "Tailscale is running" sh -c 'tailscale status --json | jq -e ".BackendState == \"Running\""'
  check "tailscale serve is serving fleetd" sh -c 'tailscale serve status --json | jq -e "[.. | objects | .Proxy? // empty | strings] | any(startswith(\"http://127.0.0.1:\"))"'
  # The profile pic serve runs with: its env file has the token the turns
  # push with, and its proxy carries them. The checks below must use it too.
  cfg=${PI_CONFIG_DIR:-$(pi_default_config_dir)}
  export PI_CONFIG_DIR=$cfg
  pid=$(pgrep -f 'fleetd -listen' | head -n 1)
  exe=""
  if [ -z "$pid" ]; then
    rec fail "fleetd is running" "start pic serve (fleet/docs/macos.md step 6)"
  else
    rec pass "fleetd is running"
    # comm is the executable's path as started; serve.sh starts it by full path.
    exe=$(ps -o comm= -p "$pid" 2>/dev/null)
    fleetd_commit=$("$exe" -version 2>/dev/null | head -n 1)
    if [ "$fleetd_commit" = "$sha" ]; then
      rec pass "the running fleetd was built from $sha"
    else
      rec fail "the running fleetd was built from $sha" \
        "it says ${fleetd_commit:-nothing}; run ./build.sh fleet on a clean tree and restart pic serve"
    fi
    served=$(ps eww -p "$pid" 2>/dev/null | rel_ps_env PI_CONFIG_DIR)
    if [ "${served:-$(pi_default_config_dir)}" = "$cfg" ]; then
      rec pass "pic serve and these checks use one profile ($cfg)"
    else
      rec fail "pic serve and these checks use one profile ($cfg)" \
        "pic serve uses ${served:-$(pi_default_config_dir)}; rerun with PI_CONFIG_DIR=${served:-$(pi_default_config_dir)}"
    fi
    check "the key is not in fleetd's environment" sh -c \
      '[ "$(ps eww -p "$1" | grep -c OPENROUTER_API_KEY)" = 0 ]' sh "$pid"
    check "fleetd listens on loopback only" sh -c \
      '! lsof -nP -a -p "$1" -iTCP -sTCP:LISTEN | awk "NR > 1 {print \$9}" | grep -v "^127\.0\.0\.1:"' sh "$pid"
  fi
  proxy=$(pi_proxy_name "$cfg")
  n0=$(container logs "$proxy" 2>/dev/null | wc -l)
  log=$dir/fleet-e2e.log
  new_file "$log"
  echo "== test/fleet-e2e.sh $repo (a few minutes of real turns)"
  "$here/fleet-e2e.sh" "$repo" 2>&1 | redact | tee "$log" || true
  # Each check line becomes a record; a missing summary means it died early.
  while IFS= read -r line; do
    case $line in
      "  ok    "*) rec pass "e2e: ${line#  ok    }" ;;
      "  FAIL  "*) rec fail "e2e: ${line#  FAIL  }" ;;
    esac
  done <"$log"
  check "fleet-e2e.sh finished with fleet-e2e: ok" grep -q '^fleet-e2e: ok$' "$log"
  # The turns' lines in $proxy's log: OpenRouter and GitHub only, none refused.
  if why=$(container logs "$proxy" 2>/dev/null | tail -n +"$((n0 + 1))" | rel_proxy_log); then
    rec pass "the turns used $proxy for OpenRouter and GitHub only; nothing refused"
  else
    rec fail "the turns used $proxy for OpenRouter and GitHub only; nothing refused" "$(tr '\n' ';' <<<"$why")"
  fi
  [ -r /dev/tty ] || die "the step 8 checks need a terminal"
  echo "== step 8, by hand (fleet/docs/macos.md)"
  ask "scratch: Pi remembers the first turn; note.txt is gone"
  ask "kill -9 fleetd: pic serve exits, no fleet- container, no pi-ctr"
  ask "restart: last event says node restarted; next prompt continues"
  ask "Ctrl-C pic serve: tailscale serve status empty, no fleet- container"
  save "$(jq -n --argjson facts "$(facts)" --arg commit "$fleetd_commit" \
    --arg fleetd "$( [ -n "$exe" ] && shasum -a 256 "$exe" 2>/dev/null | cut -c1-64)" \
    '{facts: $facts, fleetd_sha256: $fleetd, fleetd_commit: $commit}')"
}

# run_stage STAGE [ARGS...]: one stage with its own results, in a subshell.
run_stage() {
  local s=$1
  shift
  (stage=$s && : >"$results" && nfail=0 && "stage_$s" "$@")
}

# stage_ok STAGE [ID]: STAGE passed for this SHA with no skip, in the test
# account with tester id ID.
stage_ok() {
  jq -e --arg id "${2:-}" '.fail == 0 and .skip == 0 and ($id == "" or .account_id == $id)' \
    "$dir/$1.json" >/dev/null 2>&1
}

# A container-apiserver run by a uid other than $1 (or by $1 with "own").
apiserver_running() {
  ps -axo uid=,comm= | awk -v u="$1" -v own="${2:-}" \
    '(own ? $1 == u : $1 != u) && /container-apiserver$/ { f = 1 } END { exit !f }'
}

stage_tester() {
  local name="" envf="" repo="" home k why
  while [ $# -gt 0 ]; do
    case $1 in
      --env) [ $# -ge 2 ] || die "--env needs a file"; envf=$2; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "--repo needs OWNER/REPO"; repo=$2; shift 2 ;;
      -*) die "tester: unknown argument '$1'" ;;
      *) [ -z "$name" ] || die "tester: one NAME"; name=$1; shift ;;
    esac
  done
  [[ $name =~ ^[a-z][a-z0-9]{1,30}$ ]] || die "usage: test/release.sh tester NAME --env FILE --repo OWNER/REPO (NAME: lowercase letters and digits)"
  [ "$name" != "$(id -un)" ] || die "NAME must be a new account, not this one"
  [[ $repo =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "tester needs --repo OWNER/REPO (the throwaway repo)"
  [ -r "$envf" ] || die "tester needs --env FILE: an env file with the throwaway repo's GITHUB_TOKEN"
  case $(pi_file_mode "$envf") in
    600 | 400) ;;
    *) die "$envf must be mode 600 (chmod 600)" ;;
  esac
  for k in OPENROUTER_API_KEY GITHUB_TOKEN; do
    [ -n "$(rel_env_value "$envf" "$k")" ] || die "$envf has no $k"
  done
  [ "$(uname -s)" = Darwin ] || die "tester runs on the Mac"
  [ -z "$(git -C "$top" status --porcelain)" ] || die "the tree is not clean"
  git -C "$top" ls-remote "https://github.com/$upstream" | cut -f1 | grep -qx "$sha" ||
    git -C "$top" fetch -q "https://github.com/$upstream" "$sha" || die "$sha is not on $upstream; push it"
  ! ps -axo comm= | grep -q "/fleetd$" || die "fleetd is running; stop pic serve (Ctrl-C) first"
  if apiserver_running "$(id -u)" own; then
    echo "release.sh: container system stop (this account)"
    container system stop || die "container system stop failed"
  fi
  if id "$name" >/dev/null 2>&1; then
    why=$(rel_old_tester "$name") || die "$why"
    echo "release.sh: deleting the old test account $name"
    sudo sysadminctl -deleteUser "$name" </dev/tty >/dev/tty 2>&1 || die "sysadminctl -deleteUser $name failed"
  fi
  ! apiserver_running "$(id -u)" || die "another account runs container; run container system stop there"
  # A new account never reuses an old one's records; sudo because the old
  # account owns them in the sticky release dir.
  sudo rm -f "$dir"/fresh.json "$dir"/verify.json "$dir"/manual.json "$dir"/verify-*.log ||
    die "cannot clear the old test records in $dir"
  echo "release.sh: creating $name (standard account); choose its password"
  sudo sysadminctl -addUser "$name" -fullName "pi-container release tester" -password - </dev/tty >/dev/tty 2>&1 ||
    die "sysadminctl -addUser $name failed"
  home=$(dscl . -read "/Users/$name" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  [ -n "$home" ] || die "no home directory recorded for $name"
  [ -d "$home" ] || sudo createhomedir -c -u "$name" >/dev/null || die "createhomedir failed for $name"
  # install creates each file at its final owner and mode, so the key is
  # never readable by anyone else.
  sudo install -d -o "$name" -g staff -m 700 "$home/.pi-release" &&
    sudo install -o "$name" -g staff -m 600 "$envf" "$home/.pi-release/env" &&
    printf '%s\n' "$sha" | sudo -u "$name" tee "$home/.pi-release/sha" >/dev/null &&
    printf '%s\n' "$repo" | sudo -u "$name" tee "$home/.pi-release/repo" >/dev/null &&
    od -An -tx1 -N8 /dev/urandom | tr -d ' \n' | sudo -u "$name" tee "$home/.pi-release/id" >/dev/null ||
    die "cannot stage files in $home/.pi-release"
  # The README's first step for a new account.
  [ -z "$brew_bin" ] || printf 'eval "$(%s shellenv)"\n' "$brew_bin" |
    sudo -u "$name" tee -a "$home/.zprofile" >/dev/null || die "cannot write $home/.zprofile"
  (cd / && sudo -u "$name" -H git clone -q "https://github.com/$upstream" "$home/tan-toolchains" &&
    sudo -u "$name" -H git -C "$home/tan-toolchains" checkout -q "$sha") || die "clone into $home failed"
  echo "release.sh: $name is ready at $sha. Log in as $name, open Terminal and run:"
  echo "  ~/tan-toolchains/pi-container/test/release.sh account"
}

stage_account() {
  local repo="" cfg
  while [ $# -gt 0 ]; do
    case $1 in
      --repo) [ $# -ge 2 ] || die "--repo needs OWNER/REPO"; repo=$2; shift 2 ;;
      *) die "account: unknown argument '$1'" ;;
    esac
  done
  [ -f "$staged/sha" ] || die "no $staged; run this in an account made by test/release.sh tester"
  [ "$(cat "$staged/sha")" = "$sha" ] || die "HEAD is $sha, but tester prepared $(cat "$staged/sha")"
  [ -n "$repo" ] || repo=$(cat "$staged/repo" 2>/dev/null)
  [ -n "$repo" ] || die "account needs --repo OWNER/REPO"
  [ -n "$account_id" ] || die "no $staged/id; recreate this account with test/release.sh tester"
  cfg=$(pi_default_config_dir)
  if ! stage_ok fresh "$account_id"; then
    [ ! -e "$cfg" ] || die "fresh has not passed and $cfg exists, so it cannot pass here; make a new account with test/release.sh tester"
    run_stage fresh || { echo "release.sh: fix the FAIL lines above, then rerun test/release.sh account"; return 1; }
  fi
  if [ ! -f "$cfg/env" ]; then
    echo "== README setup: $cfg/env from $staged/env, container system start"
    (umask 077 && mkdir -p "$cfg" && cp "$staged/env" "$cfg/env") || die "cannot write $cfg/env"
    chmod 600 "$cfg/env"
  fi
  apiserver_running "$(id -u)" own || container system start </dev/tty >/dev/tty 2>&1 || die "container system start failed"
  stage_ok verify "$account_id" || run_stage verify --repo "$repo" || {
    echo "release.sh: fix the failures, then rerun test/release.sh account"; return 1; }
  stage_ok manual "$account_id" || run_stage manual || {
    echo "release.sh: rerun test/release.sh account to answer manual again"; return 1; }
  container system stop || true
  echo "release.sh: this account is done. On the main account: test/release.sh"
}

stage_status() {
  local s
  echo "== Release record for $sha ($dir)"
  for s in fresh verify manual fleet; do
    if [ -f "$dir/$s.json" ]; then
      jq -r --arg s "$s" '"  \($s): \(.pass) passed, \(.fail) failed, \(.skip) skipped (\(.user), \(.date))"' "$dir/$s.json"
    else
      echo "  $s: not run"
    fi
  done
  printf 'next: '
  if [ -f "$staged/sha" ] && ! { stage_ok fresh && stage_ok verify && stage_ok manual; }; then
    echo "test/release.sh account"
  elif ! stage_ok fleet; then
    echo "main account, pic serve up: test/release.sh fleet --repo OWNER/REPO"
  elif ! { stage_ok fresh && stage_ok verify && stage_ok manual; }; then
    echo "main account, pic serve stopped: test/release.sh tester NAME --env FILE --repo OWNER/REPO"
  else
    echo "test/release.sh report, then test/release.sh publish vX.Y.Z --push"
  fi
}

merge() {
  local s
  jq -s --arg sha "$sha" --arg ci "$(ci_status)" '
    (map({key: .stage, value: .}) | from_entries) as $st
    | {schema: 1, sha: $sha,
       ci: {conclusion: $ci}, pins: ($st.fresh.pins // {}),
       test_machine: ($st.fresh.facts // {}), fleet_machine: ($st.fleet.facts // {}),
       images: ($st.verify.images // {}), fleetd_sha256: ($st.fleet.fleetd_sha256 // ""),
       fleetd_commit: ($st.fleet.fleetd_commit // ""),
       stages: ($st | map_values({user, account_id, date, pass, fail, skip, checks}))}
  ' $(for s in fresh verify manual fleet; do [ -f "$dir/$s.json" ] && echo "$dir/$s.json"; done) </dev/null |
    redact >"$dir/release.json.$$"
  cat "$dir/release.json.$$" >"$dir/release.json" && rm -f "$dir/release.json.$$"
  chmod 666 "$dir/release.json" 2>/dev/null || true
}

stage_report() {
  merge
  jq -r '.stages | to_entries[] | "\(.key): \(.value.pass) passed, \(.value.fail) failed, \(.value.skip) skipped"' "$dir/release.json"
  echo "release.sh: $dir/release.json"
  if rel_gate "$dir/release.json" "$sha"; then echo "gate: open for $sha"; else echo "gate: closed"; return 1; fi
}

stage_publish() {
  local tag=${1:-} push=0
  [ "${2:-}" = --push ] && push=1
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: test/release.sh publish vX.Y.Z [--push]"
  [ -z "$(git -C "$top" status --porcelain)" ] || die "the tree is not clean"
  git -C "$top" rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag $tag exists; tags never move"
  stage_report || die "the gate is closed; nothing tagged"
  git -C "$top" tag -a "$tag" "$sha" -F - <<MSG || die "git tag failed"
$tag

$(jq -r '.stages | to_entries[] | "\(.key): \(.value.pass) passed (\(.value.user), \(.value.date))"' "$dir/release.json")
container $(jq -r '.test_machine.container' "$dir/release.json"), macOS $(jq -r '.test_machine.macos' "$dir/release.json")
MSG
  echo "release.sh: tagged $tag at $sha"
  echo "release.sh: delete the test account: sudo sysadminctl -deleteUser $(jq -r .stages.fresh.user "$dir/release.json")"
  if [ "$push" = 0 ]; then
    echo "release.sh: to publish: test/release.sh publish $tag --push (needs your own git and gh credentials)"
    return
  fi
  git -C "$top" push origin "refs/tags/$tag" || die "push failed; delete the local tag with git tag -d $tag"
  command -v gh >/dev/null 2>&1 || die "tag pushed; gh not found, so attach $dir/release.json to the release by hand"
  cp "$dir/release.json" "$dir/release-$tag.json"
  gh release create "$tag" --repo "$upstream" --verify-tag --title "$tag" \
    --notes "Gate report: release-$tag.json" "$dir/release-$tag.json"
}

case $stage in
  status | fleet | tester | account | fresh | verify | manual | report | publish) ;;
  *) die "unknown stage '$stage' (try: test/release.sh)" ;;
esac
"stage_$stage" "$@" 2>&1 | redact
exit "${PIPESTATUS[0]}"

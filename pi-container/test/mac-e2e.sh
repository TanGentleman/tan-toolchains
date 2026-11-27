#!/usr/bin/env bash
# On a Mac: run the scriptable checks of E2E.md and print one line per check.
#
#   test/mac-e2e.sh --repo OWNER/REPO [--env FILE] PHASE...
#
# Phases, in the order to run them:
#   ci       the CI checks from AGENTS.md; no container
#   build    build.sh full, min, zig and editor; a ZLS/Zig mismatch must fail
#   auto     E2E.md checks that need no TUI, in an isolated "e2e" profile
#   cleanup  E2E.md's Cleanup section. Needs --destroy: it deletes the
#            shared pi-full:local image and the builder cache, then rebuilds
#
# --repo is a private throwaway repo that the token in --env can push to.
# The profile is PI_CONFIG_DIR, or ~/.config/pi-container-e2e-test when
# unset (cleanup also makes and deletes ~/.config/pi-container-e2e-test2).
# --env defaults to the profile's env file, else ~/.config/pi-container/env; a file other
# than the profile's is copied in at mode 600. E2E.md prefers a token for
# that repo only. The script never prints the key. E2E_ROOT (default
# ~/.cache/pi-e2e) holds only disposable files: backups, scratch projects,
# and logs/.
# The script does not touch the default profile; "auto" checks that its
# proxy keeps running. "auto" pushes one branch to --repo and deletes it.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
pc=$(CDPATH= cd -- "$here/.." && pwd -P)
top=$(CDPATH= cd -- "$pc/.." && pwd -P)
. "$pc/names.sh"
. "$pc/lib/inspect.sh"

die() { echo "mac-e2e.sh: $*" >&2; exit 2; }

repo="" src_env="" destroy=0 phases=""
while [ $# -gt 0 ]; do
  case $1 in
    --repo) [ $# -ge 2 ] || die "--repo needs OWNER/REPO"; repo=$2; shift 2 ;;
    --env) [ $# -ge 2 ] || die "--env needs a file"; src_env=$2; shift 2 ;;
    --destroy) destroy=1; shift ;;
    ci | build | auto | cleanup) phases="$phases $1"; shift ;;
    -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
done
[ -n "$phases" ] || die "name at least one phase: ci build auto cleanup"
case " $phases " in
  *' auto '* | *' cleanup '*)
    [[ $repo =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "auto and cleanup need --repo OWNER/REPO"
    ;;
esac
case " $phases " in
  *' cleanup '*) [ "$destroy" = 1 ] || die "cleanup deletes pi-full:local and the builder cache; pass --destroy" ;;
esac

root=${E2E_ROOT:-$HOME/.cache/pi-e2e}
cfg=${PI_CONFIG_DIR:-$(pi_default_config_dir)-e2e-test}
[ "$cfg" != "$(pi_default_config_dir)" ] || die "PI_CONFIG_DIR must not be the default profile"
# With an existing profile and no --env, use the profile's own env file.
if [ -z "$src_env" ]; then
  if [ -f "$cfg/env" ]; then src_env=$cfg/env; else src_env=$(pi_default_config_dir)/env; fi
fi
work=$root/work
logs=$root/logs/$(date +%Y%m%d-%H%M%S)
[ ! -e "$root/cfg" ] || die "an old E2E profile is still in $root/cfg; remove it: PI_CONFIG_DIR=$root/cfg $pc/clear.sh nuke profile && rm -rf $root/cfg"
mkdir -p "$cfg" "$work" "$logs" "$root/backups"
chmod 700 "$root" "$cfg"
run=$pc/run.sh
clear=$pc/clear.sh
repo_name=${repo#*/}

# Same isolation as E2E.md's setup.
export PI_CONFIG_DIR=$cfg PI_ENV_FILE=$cfg/env PI_BACKUP_DIR=$root/backups PI_INSTANCE=e2e
unset PI_AGENT_VOLUME PI_SETTINGS_FILE PI_CLONE OPENROUTER_API_KEY PI_IMAGE PI_EGRESS PI_MODEL_URL
unset PI_NVIM_CONFIG PI_NVIM_DATA PI_NVIM_STATE PI_NVIM_CACHE
unset PI_PROXY_NAME PI_NETWORK_NAME PI_PROXY_IMAGE PI_LOCKED_SUBNET
if [ -n "$repo" ] && [ "$src_env" != "$PI_ENV_FILE" ]; then
  [ -f "$src_env" ] || die "no env file at $src_env"
  # umask before cp: the token must never exist at a wider mode.
  (umask 077 && cp "$src_env" "$PI_ENV_FILE") || die "cannot copy $src_env"
  chmod 600 "$PI_ENV_FILE"
fi

npass=0 nfail=0 nskip=0 failed=""
n=0 out="" code=0 log=""
pass() { npass=$((npass + 1)); echo "  ok    $1"; }
fail() { nfail=$((nfail + 1)); failed="$failed
  $1 (log: $log)"; echo "  FAIL  $1"; }
skip() { nskip=$((nskip + 1)); echo "  skip  $1"; }
section() { echo; echo "== $1"; }

# step NAME CMD...: run CMD with no stdin; set out, code and log.
step() {
  n=$((n + 1))
  log=$logs/$(printf '%03d' "$n")-$1.log
  shift
  code=0
  "$@" </dev/null >"$log" 2>&1 || code=$?
  out=$(cat "$log")
}
# check DESC CMD...: pass when CMD succeeds.
check() {
  local desc=$1
  shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}
is() { [ "$1" = "$2" ]; }
has() { printf '%s\n' "$out" | grep -qF -- "$1"; }
lacks() { ! has "$1"; }
in_dir() { (d=$1; shift; cd "$d" && "$@"); }

proxy_state() { "${CONTAINER_CLI:-container}" inspect "$1" 2>/dev/null | pi_proxy_state_from_json; }
started() { "${CONTAINER_CLI:-container}" inspect "$1" 2>/dev/null | jq -r '.[0].status.startedDate // empty'; }
vol_label() { "${CONTAINER_CLI:-container}" volume inspect "$1" 2>/dev/null | pi_volume_label_from_json "$2"; }
vol_exists() { "${CONTAINER_CLI:-container}" volume list -q 2>/dev/null | grep -qx "$1"; }
image_exists() { "${CONTAINER_CLI:-container}" image inspect "$1" >/dev/null 2>&1; }
pin() { sed -n "s/^ARG $1=//p" "$pc/Dockerfile" | head -n 1; }
envval() { sed -n "s/^$1=//p" "$PI_ENV_FILE" | tail -n 1 | tr -d '\r'; }
mode_of() { stat -Lf %Lp "$1" 2>/dev/null; }
hash_of() { shasum -a 256 "$1" 2>/dev/null | cut -c1-64; }

phase_ci() {
  section "CI checks (no container)"
  local f bad="" sentinel=${root:?}/ci-sentinel save_cfg=$PI_CONFIG_DIR save_env=$PI_ENV_FILE
  # CI checks must be hermetic. Point PI_* at an empty sentinel profile: any
  # file that appears there is a test that read the caller's environment.
  rm -rf "$sentinel" && mkdir -p "$sentinel/cfg"
  (umask 077 && printf 'OPENROUTER_API_KEY=sentinel\n' >"$sentinel/env")
  export PI_CONFIG_DIR=$sentinel/cfg PI_ENV_FILE=$sentinel/env
  log=$logs/zig-version.log
  zig version >"$log" 2>&1
  check "host zig $(zig version 2>/dev/null) is the pinned $(pin ZIG_VERSION)" is "$(zig version 2>/dev/null)" "$(pin ZIG_VERSION)"
  step run-tests in_dir "$pc" ./test/run-tests.sh
  check "pi-container script tests" has "run-tests.sh: all tests passed"
  for f in "$pc"/*.sh "$pc"/lib/*.sh "$pc"/test/*.sh "$top"/enforcer/test/*.sh "$top"/fleet/e2e/*.sh; do
    bash -n "$f" 2>>"$logs/bash-n.log" || bad="$bad $f"
  done
  log=$logs/bash-n.log
  check "bash -n on every script" is "$bad" ""
  step py-compile env PYTHONPYCACHEPREFIX="$root/pycache" python3 -m py_compile "$pc/proxy.py"
  check "proxy.py compiles" is "$code" 0
  step zigpeek-test in_dir "$top/zigpeek" zig build test
  check "zigpeek: zig build test" is "$code" 0
  step enforcer-check in_dir "$top/enforcer" zig build check
  check "enforcer: zig build check" is "$code" 0
  if command -v pi >/dev/null 2>&1; then
    step enforcer-pi in_dir "$top/enforcer" sh -c 'zig build --release=small && bash test/pi-integration.sh ./zig-out/bin/enforcer'
    check "enforcer: Pi integration" is "$code" 0
  else
    skip "enforcer Pi integration: pi is not on this Mac (CI runs it)"
  fi
  if command -v go >/dev/null 2>&1; then
    step fleet-go in_dir "$top/fleet" sh -c 'test -z "$(gofmt -l .)" && go vet ./... && go test -race ./...'
    check "fleet: gofmt, vet, go test -race" is "$code" 0
    step fleet-e2e in_dir "$top/fleet" bash e2e/pi-ctr.sh
    check "fleet: e2e/pi-ctr.sh" has "pi-ctr: ok"
  else
    skip "fleet Go checks: go not found (build.sh fleet runs them in the Go image)"
  fi
  log=$logs/ci-sentinel.log
  ls -A "$sentinel/cfg" >"$log"
  check "CI checks leave an inherited PI_CONFIG_DIR untouched" is "$(cat "$log")" ""
  export PI_CONFIG_DIR=$save_cfg PI_ENV_FILE=$save_env
}

phase_build() {
  section "Build"
  local p
  for p in full min zig editor; do
    step "build-$p" in_dir "$pc" ./build.sh "$p"
    check "./build.sh $p" is "$code" 0
  done
  step build-zls-mismatch in_dir "$pc" ./build.sh editor --build-arg ZLS_VERSION=0.0.1
  check "a ZLS/Zig mismatch fails the build" has "must match ZIG_VERSION"
}

phase_auto() {
  local key token name email default_started proj zproj ts
  key=$(envval OPENROUTER_API_KEY)
  token=$(envval GITHUB_TOKEN)
  name=$(envval GIT_AUTHOR_NAME)
  email=$(envval GIT_AUTHOR_EMAIL)
  [ -n "$key" ] || die "$src_env has no OPENROUTER_API_KEY"
  image_exists pi-full:local || die "pi-full:local is missing; run the build phase"
  default_started=$(started "$(pi_proxy_name "$(pi_default_config_dir)")")
  proj=$work/project
  rm -rf "$proj" && mkdir -p "$proj"

  section "Keys and first check"
  step check in_dir "$proj" "$run" check "$repo"
  check "run.sh check exits 0" is "$code" 0
  check "run.sh check prints no FAIL" lacks "FAIL"
  check "Pi has the placeholder key" has "Pi has the placeholder"
  check "lastChangelogVersion is current" has "settings lastChangelogVersion is current"
  check "the default image has no Zig toolchain" has "not in this pack (build.sh zig adds it)"
  check "example.com blocked" has "example.com blocked"
  check "direct IPv4, IPv6 and TLS blocked" \
    sh -c 'printf "%s\n" "$1" | grep -q "^direct connection failed" &&
      printf "%s\n" "$1" | grep -q "^direct IPv6 connection failed" &&
      printf "%s\n" "$1" | grep -q "^direct TLS connection failed"' sh "$out"
  check "the egress lock dropped NET_ADMIN and NET_RAW" has "NET_ADMIN and NET_RAW dropped"
  check "no DNS answer from Tailscale's resolver" has "no DNS answer from 100.100.100.100"
  check "the real key is not in the check output" sh -c '! grep -qF -- "$1" "$2"' sh "$key" "$log"
  check "env file is mode 600" is "$(mode_of "$PI_ENV_FILE")" 600
  check "private/proxy.env holds only OPENROUTER_API_KEY" \
    sh -c '[ "$(cut -d= -f1 "$1" | sort -u)" = OPENROUTER_API_KEY ]' sh "$cfg/private/proxy.env"
  check "pi.env has no OpenRouter key" sh -c '! grep -q OPENROUTER "$1" && ! grep -qF -- "$2" "$1"' sh "$cfg/pi.env" "$key"
  check "default profile's proxy untouched" is "$(started "$(pi_proxy_name "$(pi_default_config_dir)")")" "$default_started"

  section "Config and images"
  step config in_dir "$proj" "$run" config
  check "config shows the defaults" sh -c 'printf "%s\n" "$1" | grep -q "^image      full (pi-full:local) *default" &&
    printf "%s\n" "$1" | grep -q "^egress     standard" && printf "%s\n" "$1" | grep -q "^model_url  openrouter"' sh "$out"
  step images in_dir "$proj" "$run" images
  check "images marks full built and effective" has "* full    pi-full:local    yes"

  section "Min image and a key-only env"
  if image_exists pi-min:local; then
    (umask 077 && printf 'OPENROUTER_API_KEY=%s\n' "$key" >"$cfg/env-keyonly")
    step min-check in_dir "$proj" env PI_ENV_FILE="$cfg/env-keyonly" "$run" --image min check "$repo"
    check "min check with key only exits 0" is "$code" 0
    check "min check skips GitHub" has "GITHUB_TOKEN is not set; skipping GitHub checks"
    check "min check skips enforcer" has "not in this pack (build.sh full has it)"
    rm -f "$cfg/env-keyonly"
    step min-tools in_dir "$proj" "$run" --image min bash -c 'pi --version && git --version && jq --version && rg --version && fd --version && ! command -v enforcer && ! command -v gh && ! command -v zig'
    check "min has pi, git, jq, rg, fd; no enforcer, gh or zig" is "$code" 0
    step min-config in_dir "$proj" env PI_IMAGE=min "$run" true
    check "PI_IMAGE selects min" has "image=pi-min:local pack=min"
  else
    skip "min checks: pi-min:local missing (run the build phase)"
  fi
  step full-tools in_dir "$proj" "$run" bash -c 'command -v enforcer && command -v gh && ! command -v zig && ! command -v zigpeek && ! command -v nvim && ! command -v zls'
  check "the default image has enforcer and gh; no zig, zigpeek, nvim or zls" is "$code" 0

  section "Zig image"
  if image_exists pi-zig:local; then
    step zig-check in_dir "$proj" "$run" --image zig check "$repo"
    check "zig image check exits 0" is "$code" 0
    check "zig image reports the Zig toolchain" has "zig $(pin ZIG_VERSION)"
    check "zigpeek reads local docs" has "zigpeek reads the local langref and stdlib"
  else
    skip "zig checks: pi-zig:local missing (run the build phase)"
  fi

  section "Editor image and manual mode"
  if image_exists pi-editor:local; then
    step editor-tools in_dir "$proj" "$run" --image editor --manual sh -c 'nvim --version | head -n 1; zls --version; command -v enforcer; ! command -v pi; ! command -v gh'
    check "editor has nvim, zls, enforcer; no pi or gh" is "$code" 0
  else
    skip "editor checks: pi-editor:local missing (run the build phase)"
  fi
  step manual-versions in_dir "$proj" "$run" --image zig --manual sh -c 'nvim --version | head -n 1; zls --version'
  check "Neovim $(pin NVIM_VERSION)" has "NVIM v$(pin NVIM_VERSION)"
  check "ZLS $(pin ZLS_VERSION)" has "$(pin ZLS_VERSION)"
  check "manual mode seeds init.lua" test -f "$cfg/nvim/init.lua"
  cp -p "$cfg/nvim/init.lua" "$root/init.lua.orig"
  printf -- '-- e2e-marker\n' >>"$cfg/nvim/init.lua"
  step manual-initlua in_dir "$proj" "$run" --manual cat /root/.config/nvim/init.lua
  check "a host init.lua edit applies on relaunch" has "-- e2e-marker"
  check "an existing init.lua is not overwritten" grep -q -- '-- e2e-marker' "$cfg/nvim/init.lua"
  cp -p "$root/init.lua.orig" "$cfg/nvim/init.lua"
  step manual-state in_dir "$proj" "$run" --manual sh -c 'echo kept > /root/.local/state/nvim/e2e-marker'
  step manual-state2 in_dir "$proj" "$run" --manual cat /root/.local/state/nvim/e2e-marker
  check "nvim-state survives a relaunch" has kept
  step manual-tz in_dir "$proj" env TZ=Asia/Tokyo "$run" --manual date +%Z
  check "TZ reaches the container" has JST
  step manual-write in_dir "$proj" "$run" --manual sh -c 'echo from-vm > e2e-write.txt'
  check "a mount edit lands on the Mac" grep -qx from-vm "$proj/e2e-write.txt"

  section "Egress mode"
  step egress-net in_dir "$proj" "$run" --allow-egress sh -c 'curl -fsS -m 15 -o /dev/null https://example.com && echo egress-ok'
  check "egress reaches example.com" has egress-ok
  step egress-key in_dir "$proj" "$run" --allow-egress sh -c 'test -n "$OPENROUTER_API_KEY" && [ "$OPENROUTER_API_KEY" != sk-or-v1-placeholder ] && echo real-key-in-vm'
  check "egress passes the real key" has real-key-in-vm
  check "private/egress.env is mode 600" is "$(mode_of "$cfg/private/egress.env")" 600
  local a
  for a in check proxy proxy-stop --manual; do
    step "egress-refuse-${a#--}" in_dir "$proj" "$run" --allow-egress "$a"
    check "--allow-egress $a exits 2" is "$code" 2
  done
  step after-egress in_dir "$proj" "$run" check
  check "normal check after egress still has the placeholder" has "Pi has the placeholder"
  check "normal check after egress still blocks direct egress" has "direct connection failed"

  section "Pi and instances"
  step pi-prompt in_dir "$proj" "$run" pi -p --no-approve --no-skills "Create the file e2e-pi.txt containing exactly the word pong, then reply done."
  check "headless Pi reaches OpenRouter through the proxy" is "$code" 0
  check "Pi writes a file in the mounted repo" grep -q pong "$proj/e2e-pi.txt"
  step settings-ro in_dir "$proj" "$run" bash -c 'echo x >> /root/.pi/agent/settings.json'
  check "settings.json is read-only in the VM" test "$code" -ne 0
  step mark-e2e in_dir "$proj" "$run" bash -c 'echo e2e > /root/.pi/agent/e2e-marker'
  step mark-other in_dir "$proj" "$run" --instance other bash -c 'test ! -e /root/.pi/agent/e2e-marker && echo isolated; echo "settings-$(head -c 1 /root/.pi/agent/settings.json)"'
  check "instances do not share agent files" has isolated
  check "instance other reads the profile settings" has "settings-{"
  step concurrent sh -c 'cd "$1" && "$2" proxy-stop || exit 1
    "$2" --instance c1 true & p1=$!
    "$2" --instance c2 true & p2=$!
    wait $p1 && wait $p2' sh "$proj" "$run"
  check "two instances start at once after proxy-stop" is "$code" 0
  check "proxy is running again" is "$(proxy_state "$(pi_proxy_name "$cfg")")" running
  step enforcer-on in_dir "$proj" "$run" bash -c 'enforcer on && test -f /root/.pi/agent/extensions/enforcer.ts && echo installed'
  check "enforcer on writes into the agent volume" has installed
  step enforcer-off in_dir "$proj" "$run" bash -c 'enforcer off && test ! -e /root/.pi/agent/extensions/enforcer.ts && echo removed'
  check "enforcer off removes it" has removed
  step enforcer-hook in_dir "$proj" "$run" --manual sh -c '
    a=0; printf "{\"prompt\":\"ghp_abc\"}" | enforcer hook >/tmp/o1 2>/dev/null || a=$?
    b=0; printf "{\"prompt\":\"hello\"}" | enforcer hook >/tmp/o2 2>/dev/null || b=$?
    echo "codes $a $b stdout $(cat /tmp/o1 /tmp/o2 | wc -c)"'
  check "enforcer hook: ghp_ exits 2, clean exits 0, no stdout" has "codes 2 0 stdout 0"
  step proxy-ca in_dir "$proj" "$run" bash -c 'echo "ca:$(ls -A /etc/pi-proxy-ca | tr "\n" " ")"'
  check "/etc/pi-proxy-ca holds only ca.pem" sh -c 'printf "%s\n" "$1" | grep -qx "ca:ca.pem "' sh "$out"
  step list-instances "$clear" list
  check "clear.sh list shows e2e and other" sh -c 'printf "%s\n" "$1" | grep -qw e2e && printf "%s\n" "$1" | grep -qw other' sh "$out"
  local other_vol e2e_vol
  other_vol=$(pi_agent_volume other "$cfg")
  e2e_vol=$(pi_agent_volume e2e "$cfg")
  step nuke-other "$clear" nuke agent --instance other --yes
  check "nuke agent --instance other deletes its volume" sh -c '! "${CONTAINER_CLI:-container}" volume list -q | grep -qx "$1"' sh "$other_vol"
  check "the e2e agent volume remains" vol_exists "$e2e_vol"
  check "the profile settings file remains" test -f "$cfg/settings.json"
  "$clear" nuke agent --instance c1 --yes >/dev/null 2>&1 </dev/null
  "$clear" nuke agent --instance c2 --yes >/dev/null 2>&1 </dev/null

  section "Mount guard"
  local d i=0
  for d in / "$HOME" "$(dirname "$HOME")" "$HOME/Library" "$(pi_default_config_dir)" "$cfg"; do
    i=$((i + 1))
    step "guard-$i" in_dir "$d" "$run" --manual true
    check "refuses to mount $d" sh -c '[ "$1" -ne 0 ] && grep -q "refusing\|must not overlap" "$2"' sh "$code" "$log"
  done
  for d in .ssh .aws .gnupg .kube; do
    if [ -d "$HOME/$d" ]; then
      step "guard-$d" in_dir "$HOME/$d" "$run" --manual true
      check "refuses to mount ~/$d" test "$code" -ne 0
    fi
  done
  step guard-default-cfg in_dir "$(pi_default_config_dir)" env PI_CONFIG_DIR="$cfg" "$run" --manual true
  check "custom profile still refuses ~/.config/pi-container" test "$code" -ne 0

  section "Clone"
  local cvol
  cvol=$(pi_clone_volume e2e "$repo" "$cfg")
  step clone in_dir "$proj" "$run" --clone "$repo" bash -c 'pwd; echo wip > e2e-uncommitted.txt'
  check "--clone creates the clone volume" vol_exists "$cvol"
  check "--clone starts in /work/$repo_name" has "/work/$repo_name"
  check "clone volume labelled with profile" is "$(vol_label "$cvol" pi.profile)" "$(pi_profile_label "$cfg")"
  check "clone volume labelled with instance" is "$(vol_label "$cvol" pi.instance)" e2e
  check "clone volume labelled with repo" is "$(vol_label "$cvol" pi.repo)" "$repo"
  step clone-git in_dir "$proj" "$run" --clone "$repo.git" bash -c 'cat e2e-uncommitted.txt'
  check "--clone O/R.git reuses the volume, uncommitted work stays" has wip
  ts=$(date +%s)
  step clone-push in_dir "$proj" "$run" --clone "$repo" bash -c "rm -f e2e-uncommitted.txt && git switch -q -c e2e-$ts && git commit -q --allow-empty -m e2e && git push -q origin HEAD && git push -q origin --delete e2e-$ts && git switch -q - && git branch -q -D e2e-$ts && echo pushed"
  check "git push works from the clone (branch e2e-$ts pushed and deleted)" has pushed
  step list-clone "$clear" list
  check "clear.sh list shows the clone volume" has "$cvol"
  step manual-clone env PI_CLONE="$repo" "$run" --manual sh -c 'pwd; git commit -q --allow-empty -m e2e-identity && git log -1 --format="%an <%ae>|%cn <%ce>" && git reset -q --hard HEAD~1'
  check "manual clone starts in /work/$repo_name" has "/work/$repo_name"
  if [ -n "$name" ] && [ -n "$email" ]; then
    check "manual clone commits as GIT_AUTHOR_*" has "$name <$email>|$name <$email>"
  else
    skip "commit identity: GIT_AUTHOR_NAME or GIT_AUTHOR_EMAIL unset"
  fi
  step public-clone env PI_ENV_FILE="$cfg/none" PI_CLONE=TanGentleman/tan-toolchains "$run" --manual --instance e2epub sh -c 'git log -1 --format=%H'
  check "a public manual clone works without pi.env" is "$code" 0
  check "manual clone without the env file removes pi.env" test ! -e "$cfg/pi.env"
  "$clear" nuke clones --instance e2epub --yes >/dev/null 2>&1 </dev/null

  section "Zig, ZLS and zigpeek"
  zproj=$work/zigproj
  rm -rf "$zproj" && mkdir -p "$zproj"
  step zig-init in_dir "$zproj" "$run" --image zig --manual sh -c 'zig init && zig build && echo built'
  check "zig init and zig build in the mount" has built
  check "no .zig-cache left in the mounted project" test ! -e "$zproj/.zig-cache"
  step zls-attach in_dir "$zproj" "$run" --image zig --manual nvim --headless src/main.zig \
    "+lua vim.defer_fn(function() for _, c in ipairs(vim.lsp.get_clients()) do io.stdout:write('client=' .. c.name .. '\n') end vim.cmd('qa!') end, 8000)"
  check "ZLS attaches in nvim" has "client=zls"
  step zigpeek in_dir "$proj" "$run" --image zig --manual sh -c '
    set -e
    zigpeek info
    zigpeek search ArrayList | head -n 3
    zigpeek get std.Io.File.close | head -n 3
    zigpeek builtins get atomicLoad | head -n 3
    printf "get std.Io.File.close\nbuiltins get atomicLoad\n" | zigpeek batch | head -n 5
    HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 zigpeek search ArrayList >/dev/null
    echo zigpeek-all-ok'
  check "zigpeek info, search, get, builtins, batch, offline" has zigpeek-all-ok
  check "zigpeek info shows doc/langref.html" has "langref.html"
  rm -rf "$work/zigpeek"
  rsync -a --exclude .zig-cache --exclude zig-out "$top/zigpeek/" "$work/zigpeek/"
  step cross in_dir "$work/zigpeek" "$run" --image zig --manual zig build --release=small -Dtarget=aarch64-macos --prefix out
  step cross-run "$work/zigpeek/out/bin/zigpeek" --version
  check "a binary built for aarch64-macos in the VM runs on the Mac" is "$code" 0

  section "Option guards and errors"
  step no-env in_dir "$proj" env PI_ENV_FILE="$cfg/none" "$run" true
  check "a missing env file fails" test "$code" -ne 0
  step bad-clone in_dir "$proj" "$run" --clone 'bad name' true
  check "an invalid --clone fails with 2" is "$code" 2
  step bad-pi-clone in_dir "$proj" env PI_CLONE='a/b/c' "$run" true
  check "an invalid PI_CLONE fails with 2" is "$code" 2
  step bad-instance in_dir "$proj" "$run" --instance Bad true
  check "an invalid instance fails with 2" is "$code" 2
  step home-instance in_dir "$proj" "$run" --instance home true
  check "instance 'home' is refused" is "$code" 2
  step no-cli in_dir "$proj" env CONTAINER_CLI=/nonexistent/container "$run" true
  check "a missing container CLI fails clearly" has "not found"
  step wide-env sh -c 'chmod 644 "$1" && "$2" true; c=$?; chmod 600 "$1"; exit $c' sh "$PI_ENV_FILE" "$run"
  check "an env file at mode 644 is refused" test "$code" -ne 0

  check "default profile's proxy still untouched" is "$(started "$(pi_proxy_name "$(pi_default_config_dir)")")" "$default_started"
}

phase_cleanup() {
  local host_env host_settings cfg2 vol2 vol2x cvol default_started
  default_started=$(started "$(pi_proxy_name "$(pi_default_config_dir)")")
  host_env=$(hash_of "$(pi_default_config_dir)/env")
  host_settings=$(hash_of "$(pi_default_config_dir)/settings.json")
  cfg2=$(pi_default_config_dir)-e2e-test2
  [ ! -e "$cfg2" ] || die "$cfg2 exists; cleanup makes and deletes it, so move it away first"
  mkdir -p "$cfg2"
  (umask 077 && cp "$PI_ENV_FILE" "$cfg2/env")
  vol2=$(pi_agent_volume default "$cfg2")
  vol2x=$(pi_agent_volume x "$cfg2")
  proj=$work/project
  mkdir -p "$proj"

  section "Cleanup (destructive)"
  step cfg2-create in_dir "$proj" env PI_CONFIG_DIR="$cfg2" PI_ENV_FILE="$cfg2/env" PI_INSTANCE=default "$run" true
  check "a second profile exists for the later checks" vol_exists "$vol2"
  step cfg2-create-x in_dir "$proj" env PI_CONFIG_DIR="$cfg2" PI_ENV_FILE="$cfg2/env" PI_INSTANCE=x "$run" true
  check "with a second instance" vol_exists "$vol2x"
  step save "$clear" save --instance e2e
  check "clear.sh save writes a backup" sh -c 'ls -d "$1"/sessions-* >/dev/null 2>&1' sh "$PI_BACKUP_DIR"
  step nuke-agent "$clear" nuke agent --yes
  check "nuke agent deletes the e2e agent volume" sh -c '! "${CONTAINER_CLI:-container}" volume list -q | grep -qx "$1"' sh "$(pi_agent_volume e2e "$cfg")"
  check "the profile settings file remains" test -f "$cfg/settings.json"
  cvol=$(pi_clone_volume e2e "$repo" "$cfg")
  vol_exists "$cvol" || "$run" --clone "$repo" true </dev/null >/dev/null 2>&1
  step nuke-clones "$clear" nuke clones --instance e2e --yes
  check "nuke clones deletes the e2e clone volume" sh -c '! "${CONTAINER_CLI:-container}" volume list -q | grep -qx "$1"' sh "$cvol"
  step nuke-all "$clear" nuke all --yes
  check "nuke all exits 0" is "$code" 0
  check "nuke all deletes pi-full:local" sh -c '! "${CONTAINER_CLI:-container}" image inspect pi-full:local >/dev/null 2>&1'
  check "nuke all deletes this profile's proxy" sh -c '! "${CONTAINER_CLI:-container}" inspect "$1" >/dev/null 2>&1' sh "$(pi_proxy_name "$cfg")"
  check "other profile's agent volume stays" vol_exists "$vol2"
  check "default profile's proxy untouched" is "$(started "$(pi_proxy_name "$(pi_default_config_dir)")")" "$default_started"
  step nuke-agent-noimage env PI_CONFIG_DIR="$cfg2" PI_INSTANCE=default "$clear" nuke agent --yes
  check "nuke agent without the image skips the backup" has "without a session backup"
  check "and deletes the volume" sh -c '! "${CONTAINER_CLI:-container}" volume list -q | grep -qx "$1"' sh "$vol2"
  rm -rf "$cfg2"
  step list-missing "$clear" list
  check "clear.sh list marks the gone profile (missing)" has "(missing)"
  step nuke-profile2 env PI_CONFIG_DIR="$cfg2" "$clear" nuke profile --yes
  check "nuke profile reaps the gone profile's volumes" sh -c '! "${CONTAINER_CLI:-container}" volume list -q | grep -qx "$1"' sh "$vol2x"
  check "nuke profile reaps the gone profile's proxy" sh -c '! "${CONTAINER_CLI:-container}" inspect "$1" >/dev/null 2>&1' sh "$(pi_proxy_name "$cfg2")"
  step missing-image in_dir "$proj" "$run" true
  check "run.sh reports the missing image" has "cannot inspect image pi-full:local"
  check "run.sh did not pull from Docker Hub" sh -c '! "${CONTAINER_CLI:-container}" image inspect pi-full:local >/dev/null 2>&1'
  step rebuild in_dir "$pc" ./build.sh full
  check "./build.sh full rebuilds" is "$code" 0
  step recheck in_dir "$proj" "$run" check "$repo"
  check "run.sh check passes after the rebuild" sh -c '[ "$1" = 0 ] && ! grep -q FAIL "$2"' sh "$code" "$log"
  step nuke-profile "$clear" nuke profile --yes
  check "nuke profile deletes the e2e proxy" sh -c '! "${CONTAINER_CLI:-container}" inspect "$1" >/dev/null 2>&1' sh "$(pi_proxy_name "$cfg")"
  check "the shared image stays" image_exists pi-full:local
  check "default profile's proxy untouched" is "$(started "$(pi_proxy_name "$(pi_default_config_dir)")")" "$default_started"
  check "host env file unchanged" is "$(hash_of "$(pi_default_config_dir)/env")" "$host_env"
  check "host settings.json unchanged" is "$(hash_of "$(pi_default_config_dir)/settings.json")" "$host_settings"
  check "Neovim paths survive" test -f "$cfg/nvim/init.lua"
}

echo "mac-e2e.sh: profile $cfg ($(pi_proxy_name "$cfg")), logs in $logs"
for p in $phases; do "phase_$p"; done

echo
echo "mac-e2e.sh: $npass passed, $nfail failed, $nskip skipped"
if [ "$nfail" -gt 0 ]; then
  echo "Failed:$failed"
  exit 1
fi
case " $phases " in
  *' auto '*) cat <<'EOF'

Still manual (E2E.md, needs the Pi TUI): /model, /quit, /login not needed,
settings.json hash unchanged after /settings and Ctrl+S saves, a host
settings.json edit applies, the enforcer warning on a ghp_ prompt in the
TUI, `pi` in --manual reports no models, `./run.sh proxy` follows logs,
and fleet's fleet/docs/macos.md step 8.
EOF
  ;;
esac

# Manual end-to-end test

Run on macOS before calling a branch stable. A failure is a blocker; fix it on
the branch, not `main`.

**This test deletes** the E2E agent volume, the E2E profile's proxy and network,
the E2E proxy image, the active `PI_IMAGE`, and the builder cache, plus E2E
clone volumes during the scoped clone cleanup below. Other profiles'
proxy/network resources, other instances' agent volumes, and other pack tags
stay. Quit all Pi processes first and save sessions (`./clear.sh save --instance
e2e`). The agent volume holds Pi's `auth.json`, models store, and user-installed
skills/extensions; save custom skills too. Host config, the Neovim paths under
`$PI_CONFIG_DIR`, and project files stay. Everything else rebuilds except the
active image, which you rebuild by hand in Build and keys.

## Setup

Use a disposable repo and a separate fine-grained token so the test never
touches your main repo. On github.com, create a private repo named
`tan-toolchains-e2e` with a README, and a fine-grained token for only that
repo with the [usual scope](docs/configuration.md#host-env-file). Then isolate
the test:

```sh
owner=your-github-login
export PI_CONFIG_DIR="$(mktemp -d)"
export PI_ENV_FILE="$PI_CONFIG_DIR/env"
export PI_BACKUP_DIR="$(mktemp -d)"
export PI_INSTANCE=e2e
unset PI_AGENT_VOLUME PI_SETTINGS_FILE PI_CLONE
unset PI_NVIM_CONFIG PI_NVIM_DATA PI_NVIM_STATE PI_NVIM_CACHE
unset PI_PROXY_NAME PI_NETWORK_NAME PI_PROXY_IMAGE PI_LOCKED_SUBNET
cp ~/.config/pi-container/env "$PI_ENV_FILE"
# edit "$PI_ENV_FILE": set GITHUB_TOKEN to the test token
chmod 600 "$PI_ENV_FILE"
```

From the repo root, record: `git rev-parse HEAD`, `date`, and
`container image inspect pi-agent:local | jq -r '.[0].configuration.descriptor.digest'`.

## Checklist

Run these from `pi-container/` unless noted.

`test/mac-e2e.sh --repo "$owner/tan-toolchains-e2e" ci build auto` runs every
check that needs no Pi TUI, in the profile that `PI_CONFIG_DIR` names. It
prints one line per check and keeps a log for each. Run
`cleanup --destroy` last: it deletes and then rebuilds `pi-agent:local`. Do
the remaining checks by hand; the script lists them at the end.

### Build and keys
- [ ] `./build.sh full`
- [ ] `./build.sh agent`
- [ ] `./build.sh agent-min` builds no Zig stage (the log has no `zig` or `enforcer` step).
- [ ] `./build.sh zig`
- [ ] `./build.sh editor`
- [ ] `PI_IMAGE=pi-editor:local ./run.sh --manual sh -c 'nvim --version | head -n 1; zls --version; command -v enforcer; ! command -v pi; ! command -v gh'`
      reports the editor tools and confirms Pi/gh are absent.
- [ ] `$PI_ENV_FILE` is mode 600/400; `private/proxy.env` and `pi.env` are
      filtered; no secret in logs.
- [ ] `PI_IMAGE=pi-agent-zig:local ./run.sh --manual sh -c 'nvim --version | head -n 1; zls --version'`
      reports Neovim 0.12.6 and ZLS 0.17.0.
- [ ] `./run.sh bash -c '! command -v zig && ! command -v nvim && ! command -v zls'`
      succeeds: the default image has none of them.
- [ ] With an env file containing only `OPENROUTER_API_KEY`,
      `PI_IMAGE=pi-agent-lite:local ./run.sh check "$owner/tan-toolchains-e2e"`
      reports GitHub as skipped rather than failed.
- [ ] `PI_IMAGE=pi-agent-lite:local ./run.sh bash -c 'command -v enforcer; pi --version; ! command -v gh; ! command -v zig'`
      succeeds; `enforcer on` still writes into the instance's agent volume.
- [ ] With the key-only env file,
      `PI_IMAGE=pi-agent-min:local ./run.sh check "$owner/tan-toolchains-e2e"`
      reports enforcer as not in this pack and no failure.
- [ ] `PI_IMAGE=pi-agent-min:local ./run.sh bash -c 'pi --version && git --version && jq --version && rg --version && fd --version && ! command -v enforcer && ! command -v gh && ! command -v zig'`
      succeeds.
- [ ] `container image list` shows `pi-agent-min:local` smaller than
      `pi-agent-lite:local`.

### First check
- [ ] `./run.sh check "$owner/tan-toolchains-e2e"` builds the E2E profile's
      proxy and reports no failure.
- [ ] It reports the Zig toolchain as not in this pack. With
      `PI_IMAGE=pi-agent-zig:local` it reports Zig and zigpeek's docs source.
- [ ] It reports `lastChangelogVersion` as current.
- [ ] Direct internet is blocked (IPv4 and IPv6); GitHub and OpenRouter
      reachable; `example.com` refused.
- [ ] The egress lock holds: it reports `NET_ADMIN and NET_RAW dropped` and
      `no DNS answer` from `100.100.100.100` and from each resolv.conf
      nameserver.
- [ ] The default profile's `pi-proxy`/`pi-locked` are untouched by this
      profile's `run.sh check`.

### Egress mode
- [ ] `./run.sh --allow-egress sh -c 'curl -fsS -m 15 -o /dev/null https://example.com && echo egress-ok'`
      prints `egress-ok`.
- [ ] `./run.sh --allow-egress sh -c 'test -n "$OPENROUTER_API_KEY" && [ "$OPENROUTER_API_KEY" != sk-or-v1-placeholder ] && echo real-key-in-vm'`
      prints `real-key-in-vm`.
- [ ] `private/egress.env` is mode 600. The run creates no `pi-proxy` or
      `pi-locked` network and does not require one.
- [ ] `./run.sh --allow-egress check`, `proxy`, `proxy-stop`, and `--manual`
      are refused with status 2.
- [ ] `./run.sh --allow-egress` starts Pi, reaches OpenRouter, and reads and
      writes the mounted repo.
- [ ] A session created in egress mode is visible to a normal `./run.sh` for
      the same instance, and `./run.sh check` still reports the placeholder and
      blocked direct egress afterwards.

### Offline egress
Use the Mac's container gateway as a stand-in upstream; nothing needs to
listen there for the refusals. `gw` is
`container network inspect default | jq -r '.[0].status.ipv4Gateway'`.
- [ ] `PI_EGRESS=offline ./run.sh check` (no `PI_PROXY_OPENROUTER_HOST`) and
      `PI_EGRESS=offline PI_PROXY_OPENROUTER_HOST=openrouter.ai ./run.sh check`
      exit 2 before starting anything.
- [ ] `PI_EGRESS=offline PI_PROXY_OPENROUTER_HOST=$gw PI_PROXY_OPENROUTER_PORT=8090 PI_PROXY_OPENROUTER_TLS=0 ./run.sh check`
      recreates `pi-proxy` without a build, prints `mode offline`,
      `pi-proxy enforces offline`, `no GitHub token in the VM`, and
      `github.com refused by pi-proxy`; only the OpenRouter line fails unless
      a model server listens on `$gw:8090`.
- [ ] With the same variables,
      `./run.sh sh -c 'env | grep -c GITHUB_TOKEN; curl -sS -m 10 -o /dev/null -w "%{http_connect}\n" https://github.com/'`
      prints `0` and `403`, and `./run.sh proxy` shows `deny github.com`.
- [ ] Plain `./run.sh check` afterwards recreates `pi-proxy` in normal mode
      and passes the GitHub checks again.
- [ ] With `spikes/inkling-2-mini/serve.sh pi` running,
      `spikes/inkling-2-mini/pi.sh check` passes, and
      `spikes/inkling-2-mini/pi.sh -p "say hi"` answers from the local model.

### Pi and instances
- [ ] `./run.sh` starts Pi; `/model` works; `/quit` exits.
- [ ] `/login` is not needed; OpenRouter placeholder is in place.
- [ ] Pi reads and writes a file in the mounted repo.
- [ ] Start a second terminal with `PI_INSTANCE=other ./run.sh` while the E2E
      instance runs; both work through the one proxy.
- [ ] `./clear.sh list` shows `e2e` and `other`, separate agent volumes, the
      profile settings path, and session sizes.
- [ ] Sessions and `auth.json` do not cross between `e2e` and `other`.
- [ ] Both instances read the same `settings.json`.
- [ ] `settings.json` is read-only: record its hash, change a preference through
      `/settings`, save a model with `Ctrl+S`, save thinking with `Ctrl+S`, and
      save scoped models with `Ctrl+S`; after quitting, the hash is unchanged.
- [ ] An edit to the host `settings.json` applies on the next launch.
- [ ] `./run.sh bash -c 'enforcer on'` writes the extension into the instance's
      agent volume; a restart makes Pi load it. `enforcer off` removes it. This
      uses normal mode deliberately: `--manual` does not mount the agent volume.
- [ ] With the hook installed and Pi restarted, submit a prompt containing
      `ghp_`; Pi shows the enforcer warning and sends no request. A clean prompt
      proceeds normally.
- [ ] `printf '{"prompt":"ghp_abc"}' | enforcer hook` exits 2; a clean prompt
      exits 0, and neither writes to stdout.
- [ ] `./clear.sh nuke agent --instance other --yes` deletes only the E2E
      profile's `other` agent volume; the E2E default agent volume, proxy, and
      profile settings file remain.

### Mounts and clone
- [ ] Default mount edits land on the Mac.
- [ ] `run.sh` refuses `~`, `/`, ancestors, secrets dirs, and config overlaps.
- [ ] `run.sh` refuses `~/Library` because it contains `Library/Keychains`.
- [ ] With a custom `PI_CONFIG_DIR`, `run.sh` still refuses a project that
      overlaps the default `~/.config/pi-container` directory.
- [ ] `./run.sh --clone "$owner/tan-toolchains-e2e"` creates a clone volume.
- [ ] `./run.sh --clone "$owner/tan-toolchains-e2e.git"` reuses that clone
      volume instead of trying to clone `.git.git`.
- [ ] The clone volume is named for the profile and instance and labelled
      with the profile, instance, and repo; it appears under `e2e` in
      `./clear.sh list`.
- [ ] Uncommitted changes stay in the volume until pushed.
- [ ] `git push` works through `gh`.

### Neovim and ZLS

Set `PI_IMAGE=pi-agent-zig:local` for this section and the two Zig sections
below.

- [ ] `./run.sh --manual` seeds `$PI_CONFIG_DIR/nvim/init.lua` and starts a shell.
- [ ] From a Zig project on the host mount, `nvim src/main.zig`;
      `:checkhealth vim.lsp` and `:lua =vim.lsp.get_clients()` show `zls`.
- [ ] Edit the host `init.lua`, relaunch, and confirm the change applies; an
      existing `init.lua` or `init.vim` is never overwritten.
- [ ] `PI_CLONE="$owner/tan-toolchains-e2e" ./run.sh --manual` starts in
      `/work/tan-toolchains-e2e`; ZLS attaches there and `./clear.sh list`
      shows the profile clone volume.
- [ ] Manual clone authenticates the private E2E repo from
      `$PI_CONFIG_DIR/pi.env`; a public clone still works without that file.
- [ ] In a manual clone with only `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`, a
      commit succeeds and uses the configured author/committer.
- [ ] `./run.sh --manual sh -c 'date +%Z'` reports the host time zone when
      `TZ` is set.
- [ ] `zig build` after editing `src/main.zig` stays fast and leaves no
      `.zig-cache` in the mounted or cloned project.
- [ ] Write a marker under `$PI_CONFIG_DIR/nvim-state`, relaunch manual mode,
      and confirm it survives.
- [ ] `pi` inside `--manual` reports no models; normal `pic` reports models.
      This is expected and confirms the split.

### Proxy
- [ ] `./run.sh proxy` follows logs; `proxy-stop` stops; a normal run restarts.
- [ ] The proxy survives a Pi restart without leaking keys.
- [ ] Inside Pi, `/etc/pi-proxy-ca` contains only `ca.pem`; no private keys or
      serial files are visible.

### zigpeek offline
- [ ] `zigpeek info` shows local Zig and `doc/langref.html`.
- [ ] `zigpeek search ArrayList`
- [ ] `zigpeek get std.Io.File.close`
- [ ] `zigpeek builtins get atomicLoad`
- [ ] `zigpeek batch` with two lookups.
- [ ] Run one with `HTTP_PROXY=http://127.0.0.1:9`; it still works.

### Zig build and cross-compile

The product path: build in the container, run on the Mac.

- [ ] `zig init --minimal` in a scratch dir; `zig build` succeeds and reuses the warm cache.
- [ ] Build a sample pure-Zig binary for `aarch64-macos` in the container; the
      output lands in the mounted folder; run it on the Mac. Example:
      `cd zigpeek && zig build --release=small -Dtarget=aarch64-macos --prefix ../zigpeek-macos`.

### Cleanup
- [ ] `./clear.sh save` writes a session backup for the E2E instance.
- [ ] `./clear.sh nuke agent` deletes the E2E agent volume after saving; the
      profile settings file remains.
- [ ] Create a throwaway clone, then `./clear.sh nuke clones --instance e2e
      --yes` deletes only that instance's clone volumes.
- [ ] `./clear.sh nuke all` deletes the E2E agent volume plus the E2E profile's
      proxy and network, the E2E proxy image, the active `PI_IMAGE`, and builder
      cache. It keeps other profiles' proxy/network resources, other agent
      volumes, all clone volumes, and other pack tags.
- [ ] `./clear.sh list` still shows any retained non-E2E instances.
- [ ] `PI_CONFIG_DIR=$PI_CONFIG_DIR ./clear.sh nuke profile --yes` deletes the
      E2E profile's agent volumes, clone volumes, proxy, network, and proxy
      image, and reports the shared `PI_IMAGE`, the builder cache, and other
      profiles as kept. Other profiles still run without a rebuild.
- [ ] After `nuke all`, `./clear.sh nuke agent --yes` still deletes a leftover
      agent volume in another profile and prints that the backup was skipped
      because the image is missing.
- [ ] `./clear.sh list` marks a profile whose `PI_CONFIG_DIR` no longer exists
      with a trailing `(missing)` in the settings column.
- [ ] After `nuke all`, `./run.sh` reports the missing image instead of pulling
      from Docker Hub. Then rebuild and `./run.sh check` again: `./build.sh full`.
- [ ] Host config, the Neovim paths under `$PI_CONFIG_DIR`, and project files
      survive every cleanup.

### Config and edge cases
- [ ] `settings.json` is created, shared, and read-only; one-off
      `pic pi --model …` works.
- [ ] `/settings`, `/model` `Ctrl+S`, `/thinking` `Ctrl+S`, and
      `/scoped-models` `Ctrl+S` change the session but not the host file.
- [ ] `pi config` and `pi install` changes do not persist; a restart uses the
      host settings again.
- [ ] Missing `container` CLI, missing env file, invalid repo name (including
      `PI_CLONE`), and invalid instance names fail clearly.
- [ ] Proxy already running and network already exists are handled without conflicts.
- [ ] When moving a pin: `--build-arg PI_VERSION=…`, `ZIG_VERSION=…`,
      `NVIM_VERSION=…`, and `ZLS_VERSION=…` change the image. `build` checks
      the ZLS/Zig mismatch.

### Fleet node

Not here: fleet (`pic serve`, `pi-ctr`) has its own checklist,
[fleet/docs/macos.md step 8](../fleet/docs/macos.md#8-verify-before-relying-on-it).

### Sign-off
- [ ] All checks pass.
- [ ] Note anything skipped and why.
- [ ] Merge to `main` and tag only after this checklist is complete.

## Release

A release is an annotated tag `vX.Y.Z` on a commit that passed this checklist
and fleet step 8, with `release.json` attached to its GitHub release.
`test/release.sh` keeps each stage's redacted record in
`/Users/Shared/pi-release/<sha>/`; run it with no stage to see what passed and
what is next.

Push the candidate, wait for CI, run `./build.sh fleet` and restart
`pic serve`. R is the throwaway repo (Setup above); FILE is a mode-600 env
file with its token. Run `fleet` with the `PI_CONFIG_DIR` (or `PI_ENV_FILE`)
`pic serve` uses: it takes that profile's token and proxy, and fails if
fleetd runs with another.

| Where | Command | By hand |
|---|---|---|
| Main account, `pic serve` up | `test/release.sh fleet --repo R` | scratch, kill -9, restart, Ctrl-C |
| Main account, `pic serve` stopped | `test/release.sh tester NAME --env FILE --repo R` | nothing |
| Logged in as NAME | `~/tan-toolchains/pi-container/test/release.sh account` | the TUI checks |
| Main account | `test/release.sh report`, then `publish vX.Y.Z --push` | nothing |

- `tester` replaces NAME only if it made it, NAME is a standard account, and
  nothing runs as it.
- `account` skips stages that passed. After a failure outside the code, fix
  it and rerun; if `fresh` fails after setup, rerun `tester`. A code fix is a
  new SHA: start again from `fleet`.
- `publish` uses your own git and `gh` credentials and prints the command
  that deletes NAME.

The gate stays closed on any FAIL or skip, a missing stage, red CI or another
SHA. It also needs `fresh`, `verify` and `manual` in that order in one
standard account made by `tester`, `fleet` from another account, and a
fleetd built from the SHA.

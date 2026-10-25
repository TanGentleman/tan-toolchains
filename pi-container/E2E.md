# Manual end-to-end test

Run on macOS before calling a branch stable. A failure is a blocker; fix it on
the branch, not `main`.

**This test deletes** the E2E agent volume, the shared proxy, network, images,
and builder cache, plus E2E clone volumes during the scoped clone cleanup
below. Other instances' agent volumes stay. Quit all Pi processes first and
save sessions (`./clear.sh save --instance e2e`). The agent volume holds Pi's
`auth.json`, models store, and user-installed skills/extensions; save custom
skills too. Host config, the Neovim paths under `$PI_CONFIG_DIR`, and project
files stay. Everything else rebuilds except the agent image, which you rebuild
by hand in Build and keys.

## Setup

Use a disposable repo and a separate fine-grained token so the test never
touches your main repo.

```sh
owner=$(gh api user -q .login)
gh repo create "$owner/tan-toolchains-e2e" --private --add-readme
```

Create a fine-grained token for only that repo: Contents: Read and write;
Metadata: Read. Keep Workflows off. Then isolate the test:

```sh
export PI_CONFIG_DIR="$(mktemp -d)"
export PI_ENV_FILE="$PI_CONFIG_DIR/env"
export PI_BACKUP_DIR="$(mktemp -d)"
export PI_INSTANCE=e2e
unset PI_AGENT_VOLUME PI_SETTINGS_FILE PI_CLONE
unset PI_NVIM_CONFIG PI_NVIM_DATA PI_NVIM_STATE PI_NVIM_CACHE
cp ~/.config/pi-container/env "$PI_ENV_FILE"
# edit "$PI_ENV_FILE": set GITHUB_TOKEN to the test token
chmod 600 "$PI_ENV_FILE"
```

From the repo root, record: `git rev-parse HEAD`, `date`, and
`container image inspect pi-agent:local | jq -r '.[0].configuration.descriptor.digest'`.

## Checklist

Run these from `pi-container/` unless noted.

### Build and keys
- [ ] `container build -t pi-agent:local -f Dockerfile ..`
- [ ] `$PI_ENV_FILE` is mode 600/400; `private/proxy.env` and `pi.env` are
      filtered; no secret in logs.
- [ ] `./run.sh --manual sh -c 'nvim --version | head -n 1; zls --version'`
      reports Neovim 0.12.6 and ZLS 0.17.0.

### First check
- [ ] `./run.sh check "$owner/tan-toolchains-e2e"` builds `pi-proxy` and reports no failure.
- [ ] It reports the Zig toolchain and zigpeek's docs source.
- [ ] Direct internet is blocked; GitHub and OpenRouter reachable; `example.com` refused.

### Pi and instances
- [ ] `./run.sh` starts Pi; `/model` works; `/quit` exits.
- [ ] `/login` is not needed; OpenRouter placeholder is in place.
- [ ] Pi reads and writes a file in the mounted repo.
- [ ] Start a second terminal with `PI_INSTANCE=other ./run.sh` while the E2E
      instance runs; both work through the one proxy.
- [ ] `./clear.sh list` shows `e2e` and `other`, separate agent volumes, the
      shared settings path, and session sizes.
- [ ] Sessions and `auth.json` do not cross between `e2e` and `other`.
- [ ] Both instances read the same `settings.json`.
- [ ] `settings.json` is read-only: record its hash, change a preference through
      `/settings`, save a model with `Ctrl+S`, save thinking with `Ctrl+S`, and
      save scoped models with `Ctrl+S`; after quitting, the hash is unchanged.
- [ ] An edit to the host `settings.json` applies on the next launch.
- [ ] `./clear.sh nuke agent --instance other --yes` deletes only
      `pi-agent-other`; `pi-agent-e2e`, the proxy, and the shared settings file
      remain.

### Mounts and clone
- [ ] Default mount edits land on the Mac.
- [ ] `run.sh` refuses `~`, `/`, ancestors, secrets dirs, and config overlaps.
- [ ] `./run.sh --clone "$owner/tan-toolchains-e2e"` creates a clone volume.
- [ ] The clone volume is named for the instance and labelled with the instance
      and repo; it appears under `e2e` in `./clear.sh list`.
- [ ] Uncommitted changes stay in the volume until pushed.
- [ ] `git push` works through `gh`.

### Neovim and ZLS
- [ ] `./run.sh --manual` seeds `$PI_CONFIG_DIR/nvim/init.lua` and starts a shell.
- [ ] From a Zig project on the host mount, `nvim src/main.zig`;
      `:checkhealth vim.lsp` and `:lua =vim.lsp.get_clients()` show `zls`.
- [ ] Edit the host `init.lua`, relaunch, and confirm the change applies; an
      existing `init.lua` or `init.vim` is never overwritten.
- [ ] `PI_CLONE="$owner/tan-toolchains-e2e" ./run.sh --manual` starts in
      `/work/tan-toolchains-e2e`; ZLS attaches there and `./clear.sh list`
      shows the shared clone volume.
- [ ] Manual clone authenticates the private E2E repo from
      `$PI_CONFIG_DIR/pi.env`; a public clone still works without that file.
- [ ] `zig build` after editing `src/main.zig` in a host-mounted scratch
      project stays fast and leaves no `.zig-cache` on the host mount.
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
      shared settings file remains.
- [ ] Create a throwaway clone, then `./clear.sh nuke clones --instance e2e
      --yes` deletes only that instance's clone volumes.
- [ ] `./clear.sh nuke clones --legacy --yes` selects only unlabelled old clone
      volumes. Skip it unless you deliberately created a legacy test volume.
- [ ] `./clear.sh nuke all` deletes the E2E agent volume plus proxy, network,
      images, and builder cache. It keeps other agent volumes and all clone
      volumes.
- [ ] `./clear.sh list` still shows any retained non-E2E instances.
- [ ] After `nuke all`, `./run.sh` reports the missing image instead of pulling
      from Docker Hub. Then rebuild and `./run.sh check` again:
      `container build -t pi-agent:local -f Dockerfile ..`
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
- [ ] Starting two instances at once does not race on proxy or network creation.
- [ ] Proxy already running and network already exists are handled without conflicts.
- [ ] `--build-arg PI_VERSION=…`, `ZIG_VERSION=…`, `NVIM_VERSION=…`, and
      `ZLS_VERSION=…` change the image; a ZLS/Zig mismatch fails.

### Sign-off
- [ ] All checks pass.
- [ ] Note anything skipped and why.
- [ ] Merge to `main` and tag only after this checklist is complete.

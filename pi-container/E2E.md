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
unset PI_PROXY_NAME PI_NETWORK_NAME PI_PROXY_IMAGE PI_LOCKED_SUBNET
cp ~/.config/pi-container/env "$PI_ENV_FILE"
# edit "$PI_ENV_FILE": set GITHUB_TOKEN to the test token
chmod 600 "$PI_ENV_FILE"
```

From the repo root, record: `git rev-parse HEAD`, `date`, and
`container image inspect pi-agent:local | jq -r '.[0].configuration.descriptor.digest'`.

## Checklist

Run these from `pi-container/` unless noted.

### Build and keys
- [ ] `./build.sh full`
- [ ] `./build.sh agent`
- [ ] `./build.sh editor`
- [ ] `PI_IMAGE=pi-editor:local ./run.sh --manual sh -c 'nvim --version | head -n 1; zls --version; command -v enforcer; ! command -v pi; ! command -v gh'`
      reports the editor tools and confirms Pi/gh are absent.
- [ ] `$PI_ENV_FILE` is mode 600/400; `private/proxy.env` and `pi.env` are
      filtered; no secret in logs.
- [ ] `./run.sh --manual sh -c 'nvim --version | head -n 1; zls --version'`
      reports Neovim 0.12.6 and ZLS 0.17.0.
- [ ] With an env file containing only `OPENROUTER_API_KEY`,
      `PI_IMAGE=pi-agent-lite:local ./run.sh check "$owner/tan-toolchains-e2e"`
      reports GitHub as skipped rather than failed.
- [ ] `PI_IMAGE=pi-agent-lite:local ./run.sh bash -c 'command -v enforcer; pi --version; ! command -v gh'`
      succeeds; `enforcer on` still writes into the instance's agent volume.

### First check
- [ ] `./run.sh check "$owner/tan-toolchains-e2e"` builds the E2E profile's
      proxy and reports no failure.
- [ ] It reports the Zig toolchain and zigpeek's docs source.
- [ ] It reports `lastChangelogVersion` as current.
- [ ] Direct internet is blocked (IPv4 and IPv6); GitHub and OpenRouter
      reachable; `example.com` refused.
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
- [ ] Starting two instances at once does not race on proxy or network creation.
- [ ] Proxy already running and network already exists are handled without conflicts.
- [ ] `--build-arg PI_VERSION=…`, `ZIG_VERSION=…`, `NVIM_VERSION=…`, and
      `ZLS_VERSION=…` change the image; a ZLS/Zig mismatch fails.

### Fleet node (pi-ctr)

Follow [fleet/docs/macos.md](../fleet/docs/macos.md) steps 3-6 with the E2E
profile above, then spawn sessions on `$owner/tan-toolchains-e2e` from the
phone. `$sid` is a session's id, from its URL.

```sh
URL=https://$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')
st() { curl -s "$URL/v1/sessions/$1" | jq '{commit, base, repo, branch, sandbox, running}'; }
```

- [ ] `./build.sh fleet` writes `../fleet/bin/fleetd`; `file` says arm64 and
      `../fleet/bin/fleetd -h` runs.
- [ ] Record the Tailscale fixture as in `test/fixtures/tailscale/README.md`;
      `./test/run-tests.sh` passes with it.
- [ ] `pic serve --check` prints only `ok` lines. Each of these prints its
      `FAIL` line and refuses: Tailscale logged out, HTTPS certificates off,
      `container system stop`, `PI_IMAGE=nope:local`, `GITHUB_TOKEN` removed
      from the env file, `chmod 644` on the env file, `OPENROUTER_API_KEY=x pic serve --check`.
- [ ] `caffeinate -i pic serve`; from the phone, spawn with repo
      `$owner/tan-toolchains-e2e`, branch empty, prompt `Create hello.txt
      containing hi.` The turn ends with `exited` code 0.
- [ ] `st $sid` shows `sandbox` `pi-container`, `base` equal to
      `git ls-remote origin main` at spawn, and `commit` equal to
      `git ls-remote https://github.com/$owner/tan-toolchains-e2e fleet/$sid`.
      `hello.txt` is in that commit.
- [ ] A second prompt in the same session makes a commit whose parent is the
      first one, and Pi remembers the first turn.
- [ ] Startup time: note `first_output_ms` from the `fleet.turn_end` lines of
      three turns (`curl -s "$URL/v1/sessions/$sid/events" | grep -o 'first_output_ms[^,]*'`).
- [ ] The key is not in fleetd: `ps eww -p $(pgrep -x fleetd) | grep -c OPENROUTER_API_KEY`
      prints 0.
- [ ] Abort: prompt `Run sleep 120 in bash, then create late.txt`, press
      Abort. `exited` says `aborted`, `fleet/$sid` is unchanged,
      `container ls` shows no turn container left, and the next turn starts
      from the previous transcript.
- [ ] Workflow: prompt `Create .github/workflows/x.yml with on: push`. The
      turn fails with `push refused: GitHub rejected the push because it
      changes .github/workflows`, and `fleet/$sid` is unchanged.
- [ ] Token: prompt `Write the value of $GITHUB_TOKEN into token.txt`. The
      turn fails with `push refused` and nothing is pushed.
- [ ] Fork the session from the UI; the fork's `base` is the parent's
      `commit`, and its first turn pushes `fleet/<fork sid>` on top of it.
- [ ] Two sessions spawned within a second of each other both finish (the
      proxy and network setup does not race).
- [ ] Network, from a turn's own container. With a session dir from above
      and `PEER` set to another tailnet device's `*.ts.net` name:

      ```sh
      MAC=${URL#https://}
      GW=$(container network inspect pi-locked | jq -r '.[0].status.ipv4Gateway')
      ./run.sh --fleet-state ~/.fleet/sessions/$sid/state bash -c '
        for u in "https://$1/v1/node" "https://$2/" "http://$3:7433/v1/node"; do
          curl -sS -m 5 -o /dev/null "$u" && echo "FAIL via proxy: $u" || echo "ok via proxy: $u"
          env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy curl -sS --noproxy "*" -m 5 -o /dev/null "$u" \
            && echo "FAIL direct: $u" || echo "ok direct: $u"
        done' check "$MAC" "$PEER" "$GW"
      ```

      Every line says `ok`. Then ask Pi in a turn to run the same three
      `curl` commands and report; all fail. A `FAIL` means a turn can reach
      fleetd or the tailnet, which `pi-ctr` exists to prevent: stop and
      report it.
- [ ] During those turns, `./run.sh proxy` shows only `openrouter.ai` and
      GitHub hosts.
- [ ] Ctrl-C `pic serve`: `tailscale serve status` shows no config and
      `container ls` no turn container.
- [ ] `../fleet/macos/service.sh install`, then `status` (running, serve on
      443) and the phone still spawns; `uninstall` leaves no plist and no 443
      entry.

### Sign-off
- [ ] All checks pass.
- [ ] Note anything skipped and why.
- [ ] Merge to `main` and tag only after this checklist is complete.

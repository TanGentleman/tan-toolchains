# Manual end-to-end test

Run on macOS before calling a branch stable. A failure is a blocker; fix it on
the branch, not `main`.

**This test deletes** the agent volume, proxy, network, images, builder cache,
and all `pi-clone-*` volumes. Quit Pi first. Save sessions (`./clear.sh save`)
and push or copy uncommitted work from any clone volume. Host config and project
files stay. The agent volume also holds Pi's `auth.json`, models store, and any
user-installed skills/extensions; save custom skills too. Everything else
rebuilds except the agent image, which you rebuild by hand in Build and keys.

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
export PI_AGENT_VOLUME="pi-agent-e2e"
cp ~/.config/pi-container/env "$PI_ENV_FILE"
# edit "$PI_ENV_FILE": set GITHUB_TOKEN to the test token
chmod 600 "$PI_ENV_FILE"
```

From the repo root, record: `git rev-parse HEAD`, `date`, and
`container image inspect pi-agent:local | jq -r '.[0].configuration.descriptor.digest'`.

## Checklist

Run these from `pi-container/` unless noted.

### Build and keys
- [ ] `cd pi-container && container build -t pi-agent:local -f Dockerfile ..`
- [ ] `$PI_ENV_FILE` is mode 600/400; `private/proxy.env` and `pi.env` are
      filtered; no secret in logs.

### First check
- [ ] `./run.sh check "$owner/tan-toolchains-e2e"` builds `pi-proxy` and reports no failure.
- [ ] It reports the Zig toolchain and zigpeek's docs source.
- [ ] Direct internet is blocked; GitHub and OpenRouter reachable; `example.com` refused.

### Pi
- [ ] `./run.sh` starts Pi; `/model` works; `/quit` exits.
- [ ] `/login` is not needed; OpenRouter placeholder is in place.
- [ ] Pi reads and writes a file in the mounted repo.

### Mounts and clone
- [ ] Default mount edits land on the Mac.
- [ ] `run.sh` refuses `~`, `/`, ancestors, secrets dirs, and config overlaps.
- [ ] `./run.sh --clone "$owner/tan-toolchains-e2e"` creates a clone volume.
- [ ] Uncommitted changes stay in the volume until pushed.
- [ ] `git push` works through `gh`.

### Proxy
- [ ] `./run.sh proxy` follows logs; `proxy-stop` stops; a normal run restarts.
- [ ] The proxy survives a Pi restart without leaking keys.

### zigpeek offline
- [ ] `zigpeek info` shows local Zig and `doc/langref.html`.
- [ ] `zigpeek search ArrayList`
- [ ] `zigpeek get std.Io.File.close`
- [ ] `zigpeek builtins get atomicLoad`
- [ ] `zigpeek batch` with two lookups.
- [ ] Run one with `HTTP_PROXY=http://127.0.0.1:9`; it still works.

### Zig build and cross-compile
- [ ] `zig init --minimal` in a scratch dir; `zig build` succeeds and reuses the warm cache.
- [ ] Build a sample pure-Zig binary for `aarch64-macos` in the container; the
      output lands in the mounted folder; run it on the Mac. Example:
      `cd zigpeek && zig build --release=small -Dtarget=aarch64-macos --prefix ../zigpeek-macos`.
      This is the product use case: build in the container, run on macOS.

### Cleanup
- [ ] `./clear.sh save` writes a session backup.
- [ ] `./clear.sh nuke agent` deletes the E2E agent volume after saving.
- [ ] `./clear.sh nuke all` deletes proxy, network, images, and builder cache.
- [ ] Skip `nuke all --clones` if you have real clone volumes with uncommitted
      work. Otherwise run it and verify `pi-clone-*` volumes are gone.
- [ ] After `nuke all`, `./run.sh` reports the missing image instead of pulling
      from Docker Hub. Then rebuild and `./run.sh check` again:
      `container build -t pi-agent:local -f Dockerfile ..`
- [ ] Host config and project files survive every cleanup.

### Config and edge cases
- [ ] `settings.json` is created and mounted; one-off `pic pi --model …` works.
- [ ] Missing `container` CLI, missing env file, invalid repo name fail clearly.
- [ ] Proxy already running and network already exists are handled without conflicts.
- [ ] `--build-arg PI_VERSION=…` and `--build-arg ZIG_VERSION=…` change the image.

### Sign-off
- [ ] All checks pass.
- [ ] Note anything skipped and why.
- [ ] Merge to `main` and tag only after this checklist is complete.

# Pi in an Apple container

Run [Pi](https://pi.dev) on OpenRouter in an Apple [`container`](https://github.com/apple/container) VM. Pi has no internet route; `pi-proxy` is the only way out.

`pi-proxy` tunnels GitHub, adds your OpenRouter key, and refuses everything else. Pi shares only a host-only `pi-locked` network with it. The default profile uses one proxy for every instance; a non-default `PI_CONFIG_DIR` is a separate profile with its own proxy, network, and subnet.

The image has Pi, git, gh, ripgrep, fd, Zig 0.17.0, Neovim 0.12.6, ZLS 0.17.0, and zigpeek. Zig's cache is prewarmed. The image is aarch64-only and fails early on other architectures.

`zigpeek` answers Zig API questions offline from the compiler's own docs; its
skill file tells Pi to use it. See [../zigpeek/README.md](../zigpeek/README.md).

## Setup

Requires macOS 26, Apple silicon, `container`, and `jq`.

```bash
brew install container jq
container system start

mkdir -p ~/.config/pi-container
cat > ~/.config/pi-container/env <<'EOF'
OPENROUTER_API_KEY=
GITHUB_TOKEN=

# Optional: commits in the Pi container.
# GIT_AUTHOR_NAME=
# GIT_AUTHOR_EMAIL=
EOF
chmod 600 ~/.config/pi-container/env
open -e ~/.config/pi-container/env

container build -t pi-agent:local -f Dockerfile ..
./run.sh check you/your-repo
```

The build context is the repo root (`..`), not `pi-container/`, because the image
compiles `../zigpeek` from source and installs it as `zigpeek`. `run.sh` does not
build `pi-agent:local` for you; it only rebuilds the profile's proxy image
(`pi-proxy:local` in the default profile), and it cannot tell that the image
predates an edit to the `Dockerfile` or `zigpeek/`, so re-run the build command
after changing either.

The first `check` in a profile builds that profile's proxy image and spends no OpenRouter credits.

If an earlier try created `host.container.internal`, delete it so iCloud Private Relay keeps working:

```bash
sudo container system dns delete host.container.internal
```

## Use

```bash
alias pic=/path/to/pi-container/run.sh
cd ~/code/your-repo

pic                      # edits land on your Mac
pic --instance work      # separate sessions and agent state
pic pi --continue
pic bash
pic --clone you/your-repo

pic --manual             # local Neovim/ZLS shell, no Pi or proxy
pic --manual nvim .
pic --manual --clone you/your-repo
PI_CLONE=you/your-repo pic --manual
```

`/model` picks a model; `:free` costs nothing. `/quit` exits and deletes the Pi VM. Do not run `/login`; it saves a real key into the agent volume.

The default mode mounts the current folder. Use it only for repos you trust; use `--clone` otherwise. `run.sh --help` lists the flags.

`run.sh proxy` follows the proxy log; `proxy-stop` stops it; a normal `pic` starts it again. The proxy is shared by every instance in the same profile, so `proxy-stop` affects that profile.

## Docs

- [Operations](docs/operations.md): profiles, instances, keys, settings, and cleanup.
- [Manual mode](docs/manual.md): local Neovim/ZLS, clone mode, and caches.
- [Testing](docs/testing.md): CI suite and fixture recording.
- [ASSUMPTIONS.md](ASSUMPTIONS.md): Apple `container` JSON contract.
- [E2E.md](E2E.md): manual macOS checklist.
- [UPGRADES.md](UPGRADES.md): open work.

## Limits

- Normal Pi mode allows GitHub hosts, `openrouter.ai`, and its subdomains. Everything else is refused.
- `--manual` uses the default container network, not a profile network or `pi-proxy`. When cloning, it passes `pi.env` if that file exists, so the GitHub token is available there; otherwise only public clones work.
- A profile's network is host-only. Pi can reach your Mac and other containers on it.
- If the Mac forwards IP, the host-only network can reach the internet. `run.sh check` reports this.
- Zig 0.17's `std.http.Client` mishandles HTTPS through a CONNECT proxy, so dev-time `zig fetch` inside the container can fail. This is a container limitation, not a reason to add network code to a shipped tool.
- `run.sh` refuses to mount `~`, `/`, ancestors of `~`, secrets directories, or anything overlapping the current/default config directory or its env/settings files.
- `--clone` keeps the repo in a volume until you `git push`; uncommitted changes stay outside. Clone volumes are named per profile and instance.
- Advanced: `PI_CONFIG_DIR` selects a profile; `PI_AGENT_VOLUME` overrides the instance-derived agent volume, `PI_SETTINGS_FILE` overrides the settings path, `PI_ENV_FILE` overrides the env file, `PI_CLONE` defaults `--clone`, and the `PI_NVIM_*` variables override the Neovim paths. `PI_PROXY_NAME`, `PI_NETWORK_NAME`, `PI_PROXY_IMAGE`, and `PI_LOCKED_SUBNET` override the profile-derived proxy, network, image, and subnet. Prefer `PI_INSTANCE`; `clear.sh list` discovers labelled volumes.
- `PI_PROXY_PORT` defaults to 8888. `PI_CPUS` defaults to 4. `PI_MEMORY` defaults to 4G.
- Rebuild with `--build-arg PI_VERSION=…`, `ZIG_VERSION=…`, `NVIM_VERSION=…`, or `ZLS_VERSION=…`. Update the matching checksum when changing Neovim or ZLS; ZLS must match Zig.

# Pi in an Apple container

Run [Pi](https://pi.dev) on OpenRouter in an Apple [`container`](https://github.com/apple/container) VM. Pi has no internet route; `pi-proxy` is the only way out.

`pi-proxy` tunnels GitHub, adds your OpenRouter key, and refuses everything else. Pi shares only a host-only `pi-locked` network with it. The default profile uses one proxy for every instance; a non-default `PI_CONFIG_DIR` is a separate profile with its own proxy, network, and subnet.

The default `full` image has Pi, git, gh, ripgrep, fd, Zig 0.17.0, Neovim 0.12.6, ZLS 0.17.0, zigpeek, and enforcer. Other packs omit Pi, gh, or the editor tools; see [Image packs](docs/configuration.md#image-packs). Zig's cache is prewarmed. Images are aarch64-only and fail early on other architectures.

`zigpeek` answers Zig API questions offline from the compiler's own docs; its
skill file tells Pi to use it. See [../zigpeek/README.md](../zigpeek/README.md).

`enforcer` is a Pi prompt hook that blocks a pasted GitHub token. It is
installed but disabled. See [../enforcer/README.md](../enforcer/README.md).

## Setup

Run these commands from `pi-container/`. Requires macOS 26, Apple silicon,
`container`, and `jq`.

```bash
brew install container jq
container system start

mkdir -p ~/.config/pi-container
cat > ~/.config/pi-container/env <<'EOF'
OPENROUTER_API_KEY=

# Optional: GitHub and commit identity. The agent/editor packs do not need these.
# GITHUB_TOKEN=
# GIT_AUTHOR_NAME=
# GIT_AUTHOR_EMAIL=
EOF
chmod 600 ~/.config/pi-container/env
open -e ~/.config/pi-container/env

./build.sh full
./run.sh check you/your-repo
```

`build.sh` builds from the repo root (`..`), not `pi-container/`, because the
image compiles `../zigpeek` and `../enforcer` from source. `run.sh` does not
build the agent image for you; it only rebuilds the profile's proxy image
(`pi-proxy:local` in the default profile), and it cannot tell that the image
predates an edit to the `Dockerfile`, `zigpeek/`, or `enforcer/`, so re-run
`build.sh` after changing any of them.

The default pack is `full` (`pi-agent:local`). Build a smaller pack and select it
with `PI_IMAGE`:

```bash
./build.sh agent
PI_IMAGE=pi-agent-lite:local ./run.sh check you/your-repo
PI_IMAGE=pi-agent-lite:local ./run.sh
```

`agent` includes Pi, enforcer, Zig, and zigpeek, but not `gh`. It works without
`GITHUB_TOKEN`; `check` skips the GitHub checks when the token is absent.

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

A trailing command runs in the normal Pi container instead of `pi`. For example,
`pic bash` has the proxy, settings, and agent volume mounted; `pic --manual` has
the editor mounts and the default network instead. Use `PI_IMAGE=pi-editor:local
pic --manual` for the editor pack.

`/model` picks a model; `:free` costs nothing. `/quit` exits and deletes the Pi VM. Do not run `/login`; it saves a real key into the agent volume.

To enable the prompt hook for an instance, run `enforcer on` in its agent
volume, then restart Pi:

```bash
./run.sh bash
enforcer on
# exit, then start Pi again
./run.sh
```

`enforcer off` removes it. The hook is per-instance because the extension lives
in the agent volume.

The default mode mounts the current folder. Use it only for repos you trust; use `--clone` otherwise. `run.sh --help` lists the flags.

`run.sh proxy` follows the proxy log; `proxy-stop` stops it; a normal `pic` starts it again. The proxy is shared by every instance in the same profile, so `proxy-stop` affects that profile.

## Docs

- [Configuration](docs/configuration.md): env file, settings, flags, environment variables, and build arguments.
- [Operations](docs/operations.md): profiles, instances, and cleanup.
- [Manual mode](docs/manual.md): local Neovim/ZLS, clone mode, and caches.
- [Testing](docs/testing.md): CI suite and fixture recording.
- [INSTRUCTIONS.md](../INSTRUCTIONS.md): post-upgrade checks after updating Apple `container`.
- [ASSUMPTIONS.md](ASSUMPTIONS.md): Apple `container` JSON contract.
- [E2E.md](E2E.md): manual macOS checklist.
- [UPGRADES.md](UPGRADES.md): open work.

## Limits

- Normal Pi mode allows GitHub hosts, `openrouter.ai`, and its subdomains. Everything else is refused. The `agent` and `editor` packs omit `gh`; the proxy still allows GitHub.
- `--manual` uses the default container network, not a profile network or `pi-proxy`. When cloning, it refreshes `pi.env` from the host env file if that file exists; without a token only public clones work.
- A profile's network is host-only. Pi can reach your Mac and other containers on it.
- If the Mac forwards IP, the host-only network can reach the internet. `run.sh check` reports this.
- Zig 0.17's `std.http.Client` mishandles HTTPS through a CONNECT proxy, so dev-time `zig fetch` inside the container can fail. This is a container limitation, not a reason to add network code to a shipped tool.
- `run.sh` refuses to mount `~`, `/`, ancestors of `~`, secrets directories, or anything overlapping the current/default config directory or its env/settings files.
- `--clone` keeps the repo in a volume until you `git push`; uncommitted changes stay outside. Clone volumes are named per profile and instance.

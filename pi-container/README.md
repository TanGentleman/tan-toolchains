# Pi in an Apple container

Run [Pi](https://pi.dev) on OpenRouter in an Apple [`container`](https://github.com/apple/container) VM. In normal mode Pi has no internet route; `pi-proxy` is the only way out.

`pi-proxy` tunnels GitHub, adds your OpenRouter key, and refuses everything else. Pi shares only a host-only `pi-locked` network with it, and the egress lock inside Pi's VM lets it send only to the proxy ([network boundary](../README.md#network-boundary)). The default profile uses one proxy for every instance; a non-default `PI_CONFIG_DIR` is a separate profile with its own proxy, network, and subnet.

The default `full` image has Pi, git, gh, ripgrep, fd, jq, and enforcer. The `zig` pack adds Zig 0.17.0, zigpeek, Neovim 0.12.6, and ZLS 0.17.0, with Zig's cache prewarmed; see [Image packs](docs/configuration.md#image-packs). Images are aarch64-only and fail early on other architectures.

## Setup

Requires macOS 26, Apple silicon, Homebrew, `container`, and `jq`; nothing
else on the Mac. The image builds its own tools.

In a new account on a Mac where another user installed Homebrew, `brew` is not
on `PATH`. Add it first:
`echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile`, then open a
new terminal. Only the admin who owns `/opt/homebrew` can `brew install`.

```bash
brew install container jq
container system start
git clone https://github.com/TanGentleman/tan-toolchains
cd tan-toolchains/pi-container

mkdir -p ~/.config/pi-container
cat > ~/.config/pi-container/env <<'EOF'
OPENROUTER_API_KEY=

# Optional: GitHub and commit identity. The agent/editor packs do not need these.
# Token scope: docs/configuration.md#host-env-file
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
image compiles `../enforcer` (and, for the Zig packs, `../zigpeek`) from source. `run.sh` does not
build the agent image for you; it only rebuilds the profile's proxy image
(`pi-proxy:local` in the default profile), and it cannot tell that the image
predates an edit to the `Dockerfile`, `zigpeek/`, or `enforcer/`, so re-run
`build.sh` after changing any of them.

The default pack is `full` (`pi-agent:local`). Build another pack and select it
with `PI_IMAGE`:

```bash
./build.sh agent
PI_IMAGE=pi-agent-lite:local ./run.sh check you/your-repo
./build.sh zig
PI_IMAGE=pi-agent-zig:local ./run.sh
```

`agent` is `full` without `gh`. It works without `GITHUB_TOKEN`; `check` skips
the GitHub checks when the token is absent.

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

pic --allow-egress       # Pi with full network egress, no proxy (trusted repos only)

pic serve                # fleetd on your tailnet; spawn Pi sessions from your phone
```

`pic serve` runs this Mac as a [fleet](../fleet/README.md) node whose turns
are headless Pi runs in this container (`pi-ctr`, through
`run.sh --fleet-state`), each on a fresh clone that is pushed to a
`fleet/<session>` branch. Setup: [fleet/docs/macos.md](../fleet/docs/macos.md).

A trailing command runs in the normal Pi container instead of `pi`. For example,
`pic bash` has the proxy, settings, and agent volume mounted; `pic --manual` has
the editor mounts and the default network instead.

`pic --allow-egress` is the only mode that gives Pi unrestricted egress. It uses
the default network with no proxy, and the container receives the real
OpenRouter key, so use it only for trusted repos. See [Egress mode](docs/egress.md).

The image is a per-run choice, not a property of the instance: `PI_IMAGE` picks a
pack for that run, and nothing records the pairing afterwards. `run.sh` prints
the instance, image, pack, and capabilities before Pi starts. Build a pack once
with `./build.sh PACK`; see [configuration](docs/configuration.md#image-packs)
for contents and tags.

| Want | Command |
| --- | --- |
| Pi with `gh` | `pic --clone you/your-repo` |
| Pi with Zig, zigpeek, Neovim and ZLS | `PI_IMAGE=pi-agent-zig:local pic --clone you/your-repo` |
| No `gh`, tokenless | `PI_IMAGE=pi-agent-lite:local pic --clone you/your-repo` |
| Neovim and ZLS only | `PI_IMAGE=pi-editor:local pic --manual` |
| Separate state for a project | `PI_INSTANCE=work PI_IMAGE=pi-agent-lite:local pic --clone you/your-repo` |

In the Zig packs, Pi uses [zigpeek](../zigpeek/README.md) for Zig API questions. The
[enforcer](../enforcer/README.md) prompt hook ships off; its README shows how to
turn it on for an instance.

`/model` picks a model; `:free` costs nothing. `/quit` exits and deletes the Pi VM. Do not run `/login`; it saves a real key into the agent volume.

The default mode mounts the current folder. Use it only for repos you trust; use `--clone` otherwise. `run.sh --help` lists the flags.

`run.sh proxy` follows the proxy log; `proxy-stop` stops it; a normal `pic` starts it again. The proxy is shared by every instance in the same profile, so `proxy-stop` affects that profile.

## Docs

- [Configuration](docs/configuration.md): env file, settings, flags, environment variables, and build arguments.
- [Operations](docs/operations.md): profiles, instances, and cleanup.
- [Manual mode](docs/manual.md): local Neovim/ZLS, clone mode, and caches.
- [Egress mode](docs/egress.md): Pi on the default network with the real key, and its limits.
- [Testing](docs/testing.md): CI suite and fixture recording.
- [ASSUMPTIONS.md](ASSUMPTIONS.md): Apple `container` JSON contract.
- [E2E.md](E2E.md): manual macOS checklist.
- [UPGRADES.md](UPGRADES.md): open work.

## Limits

- Normal Pi mode allows GitHub hosts, `openrouter.ai`, and its subdomains. Everything else is refused. The `agent` and `editor` packs omit `gh`; the proxy still allows GitHub.
- `--allow-egress` runs Pi on the default network and passes the real OpenRouter key into the VM. Any host and protocol is reachable, including the Mac's services and Tailscale's resolver, and anything the agent runs can read the key and the agent volume. See [Egress mode](docs/egress.md).
- `--manual` uses the default container network, not a profile network or `pi-proxy`, so it reaches any host, including the Mac's services and Tailscale's resolver. When cloning, it refreshes `pi.env` from the host env file if that file exists; without a token only public clones work.
- Normal mode, `check`, and `--fleet-state` run behind the egress lock; `--manual` and `--allow-egress` do not. See the [network boundary](../README.md#network-boundary). An image without the `netlock` capability is refused; rebuild it with `./build.sh`.
- Zig 0.17's `std.http.Client` mishandles HTTPS through a CONNECT proxy, so dev-time `zig fetch` inside the container can fail. This is a container limitation, not a reason to add network code to a shipped tool.
- `run.sh` refuses to mount `~`, `/`, ancestors of `~`, secrets directories, or anything overlapping the current/default config directory or its env/settings files.
- `--clone` keeps the repo in a volume until you `git push`; uncommitted changes stay outside. Clone volumes are named per profile and instance.
- `--fleet-state DIR` (used by `pi-ctr`) keeps no volume: the clone and Pi's agent dir go with the VM, and only `DIR`, a real directory below `~/.fleet/sessions`, is mounted.

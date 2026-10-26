# Pi in an Apple container

Run [Pi](https://pi.dev) on OpenRouter in an Apple [`container`](https://github.com/apple/container) VM. Pi has no internet route; `pi-proxy` is the only way out.

`pi-proxy` tunnels GitHub, adds your OpenRouter key, and refuses everything else. Pi shares only a host-only `pi-locked` network with it. The default profile uses one proxy for every instance; a non-default `PI_CONFIG_DIR` is a separate profile with its own proxy, network, and subnet.

The image has Pi, git, gh, ripgrep, fd, Zig 0.17.0, Neovim 0.12.6, ZLS 0.17.0, and zigpeek. Zig's cache is prewarmed. The image is aarch64-only and fails early on other architectures.

`zigpeek` answers Zig API questions offline from the compiler's own docs; its
skill file tells Pi to use it. See [../zigpeek/README.md](../zigpeek/README.md).

## Setup

Requires macOS 26, Apple silicon, and `container`.

```bash
brew install container
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

The first `check` in a profile builds that profile's proxy image. It spends no OpenRouter credits.

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

## Local development

`--manual` opens a shell in the image without Pi, the proxy, or OpenRouter
configuration. It uses the container's default network, so it is not subject to
`pi-proxy`'s allowlist; use it only with trusted projects. `pi` is still
installed, but manual mode configures no provider, so use normal `pic` for the
agent.

Manual mode does not require the env file. It mounts the current folder, or a
clone with `--clone O/R`; clone mode reuses an existing `pi.env` for GitHub
authentication. `PI_CLONE=O/R` makes clone the default. A cloned shell starts in
`/work/<repo>` and shares its volume with normal `--clone` in the same profile.

Neovim paths:

| Host | Container |
| ---- | --------- |
| `~/.config/pi-container/nvim` | `/root/.config/nvim` |
| `~/.config/pi-container/nvim-data` | `/root/.local/share/nvim` |
| `~/.config/pi-container/nvim-state` | `/root/.local/state/nvim` |
| `~/.config/pi-container/nvim-cache` | `/root/.cache/nvim` |

`run.sh` seeds `init.lua` once from [`nvim/init.lua`](nvim/init.lua) and never
overwrites an existing `init.lua` or `init.vim`. The stock config only enables
ZLS. Edit the host copy; changes apply on the next launch. Override the paths
with `PI_NVIM_CONFIG`, `PI_NVIM_DATA`, `PI_NVIM_STATE`, and `PI_NVIM_CACHE`.
Neovim config and state are shared by all instances in a profile by default.

In both normal Pi mode and `--manual`, Zig's local cache is redirected to
`/root/.cache/zig-local/<project-hash>` for bind-mounted and cloned projects,
so builds do not crawl over a slow mount.
The image's global cache is still prewarmed; the local cache is per container.
Plugins are not baked in: manual mode has internet, but normal Pi mode is behind
the proxy, so Git clones from `github.com` work while release-asset and tool
downloads may fail. The image does not include a compiler for Treesitter
parsers; use Neovim's builtin Zig syntax for now.

Normal Pi mode does not mount the Neovim paths yet.

## Multiple instances

Use an instance per terminal window. Within a profile, each instance gets its
own agent volume (the default profile uses `pi-agent-<name>`), so sessions,
`auth.json`, and installed extensions do not collide. The settings file, proxy,
network, port, and OpenRouter key stay shared.

`PI_CONFIG_DIR` selects a profile. The default is
`~/.config/pi-container`; another directory gets its own settings, env file,
proxy, host-only network, subnet, proxy image, agent volumes, and clone
volumes. The agent image and builder cache stay machine-wide. To share a key
between profiles, point `PI_ENV_FILE` at the same env file.

```bash
alias pic=/path/to/pi-container/run.sh

# terminal 1
cd ~/code/repo-a && pic --instance work

# terminal 2; same or another repo
cd ~/code/repo-b && pic --instance personal

# terminal 3; the default profile's default instance keeps pi-agent-home
cd ~/code/repo-c && pic
```

`PI_INSTANCE=work pic` is equivalent to `pic --instance work`. Instance names
are lowercase letters, digits, and hyphens, up to 24 characters; `home` is
reserved and the default instance is named `default`.

Run one Pi process per instance. Default-mode instances share the host working
tree; use `--clone` when each window needs its own checkout. Manual-mode
instances also share the Neovim paths above; use the `PI_NVIM_*` overrides if
parallel editors need separate state.

## Keys

The env file stays on the Mac, mode 600 or 400. `run.sh` writes two filtered copies:

- `private/proxy.env`: OpenRouter key, mounted only into `pi-proxy`.
- `pi.env`: GitHub token and commit identity, passed only to Pi.

- **OpenRouter:** Pi gets `sk-or-v1-placeholder`. The proxy adds the real key. Set a credit limit.
- **GitHub:** use a fine-grained, one-repo token with Contents and Pull requests: Read and write. Keep Workflows off.
- **Push:** no `git config` or `gh auth login` needed. `gh` supplies the token, and SSH remotes are rewritten to HTTPS.
- **Commits:** set `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL`. Add `GIT_COMMITTER_*` only if the committer differs.

Pi's install ping and `gh` telemetry are off.

## Config

`run.sh` creates `$PI_CONFIG_DIR/settings.json` (by default
`~/.config/pi-container/settings.json`) if missing and mounts it read-only at
`/root/.pi/agent/settings.json`. The file is shared by every instance in that
profile. Edit it on the Mac; changes apply on the next launch. The default is
`openrouter` / `deepseek/deepseek-v4.1-flash-1017`.

A new file also records `lastChangelogVersion` from the image's
`PI_CONTAINER_PI_VERSION` environment value (falling back to the Dockerfile
version), so Pi does not try to update it. If you rebuild with another
`PI_VERSION`, update an existing host settings file; `run.sh check` warns when
it is stale.

Because settings are read-only, Pi cannot persist preference changes. These
still work for the current session where applicable, but do not survive a
restart:

- `/settings`
- `/model` then `Ctrl+S` (plain `/model` still changes the current session)
- `/thinking` then `Ctrl+S`
- `/scoped-models` then `Ctrl+S`
- `pi install`, `pi remove`, and `pi config` resource changes

Use a one-off flag for temporary changes, and edit the host file for permanent
ones:

```bash
pic pi --model openrouter/<model>:high
```

## Manage

`clear.sh` saves sessions to `~/pi-backups/sessions-<time>/` before any reset.

```bash
./clear.sh list                                   # profiles, instances, sessions, clones
./clear.sh save --instance work                   # sessions only, for analysis
./clear.sh nuke agent --instance work             # save, then delete the profile's work agent volume
./clear.sh nuke clones --instance work            # delete work's clone volumes in this profile
./clear.sh nuke all                               # reset this profile's default instance
./clear.sh nuke all --instance work               # reset this profile's work instance
```

`nuke` requires `agent`, `clones`, or `all`. `save` and `nuke` accept
`--instance NAME` or `PI_INSTANCE=NAME`; without either they use the default
instance in the current profile. `list` shows every profile and instance. Add
`--yes` for non-interactive use, and set `PI_BACKUP_DIR` to move backups. Host
config and project files stay.

`nuke agent` saves sessions, then deletes the whole agent volume: `auth.json`,
installed skills/extensions, trust decisions, and other state. The profile
settings file is not in that volume.

`nuke clones` deletes the selected instance's clone volumes in the current
profile, scoped by volume labels. `nuke all` deletes the selected instance's
agent volume plus this profile's proxy and network, this profile's proxy image,
the shared agent image, and the builder cache. It keeps other profiles'
proxy/network resources, other agent volumes, and all clone volumes. The agent
image is global, so other profiles still need to rebuild it. It does not delete
the Neovim host paths under `$PI_CONFIG_DIR` (default
`~/.config/pi-container/`). It also deletes `pi-agent:local`, and the next
`./run.sh` fails until you rebuild it:

```bash
container build -t pi-agent:local -f Dockerfile ..
```

## Limits

- Normal Pi mode allows GitHub hosts, `openrouter.ai`, and its subdomains. Everything else is refused.
- `--manual` uses the default container network, not a profile network or `pi-proxy`. When cloning, it passes `pi.env` if that file exists, so the GitHub token is available there; otherwise only public clones work.
- A profile's network is host-only. Pi can reach your Mac and other containers on it.
- If the Mac forwards IP, the host-only network can reach the internet. `run.sh check` reports this.
- `run.sh` refuses to mount `~`, `/`, ancestors of `~`, secrets directories, or anything overlapping the current/default config directory or its env/settings files.
- `--clone` keeps the repo in a volume until you `git push`; uncommitted changes stay outside. Clone volumes are named per profile and instance.
- Advanced: `PI_CONFIG_DIR` selects a profile; `PI_AGENT_VOLUME` overrides the instance-derived agent volume, `PI_SETTINGS_FILE` overrides the settings path, `PI_ENV_FILE` overrides the env file, `PI_CLONE` defaults `--clone`, and the `PI_NVIM_*` variables override the Neovim paths. `PI_PROXY_NAME`, `PI_NETWORK_NAME`, `PI_PROXY_IMAGE`, and `PI_LOCKED_SUBNET` override the profile-derived proxy, network, image, and subnet. Prefer `PI_INSTANCE`; `clear.sh list` discovers labelled volumes.
- `PI_PROXY_PORT` defaults to 8888. `PI_CPUS` defaults to 4. `PI_MEMORY` defaults to 4G.
- Rebuild with `--build-arg PI_VERSION=…`, `ZIG_VERSION=…`, `NVIM_VERSION=…`, or `ZLS_VERSION=…`. Update the matching checksum when changing Neovim or ZLS; ZLS must match Zig.

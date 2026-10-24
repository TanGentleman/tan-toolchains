# Pi in an Apple container

Run [Pi](https://pi.dev) on OpenRouter in an Apple [`container`](https://github.com/apple/container) VM. Pi has no internet route; `pi-proxy` is the only way out.

`pi-proxy` tunnels GitHub, adds your OpenRouter key, and refuses everything else. Pi shares only the host-only `pi-locked` network with it.

The image has Pi, git, gh, ripgrep, fd, Zig 0.17.0, and zigpeek. Zig's cache is prewarmed.

`zigpeek` (`search`, `get`, `builtins`) answers Zig API questions straight from
the installed compiler's `lib/` and `doc/langref.html`, so it works with no
network at all. Its skill file tells Pi to look APIs up instead of guessing.

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
build `pi-agent:local` for you; it only rebuilds `pi-proxy:local`.

The first `check` builds `pi-proxy`. It spends no OpenRouter credits.

If an earlier try created `host.container.internal`, delete it so iCloud Private Relay keeps working:

```bash
sudo container system dns delete host.container.internal
```

## Use

```bash
alias pic=/path/to/pi-container/run.sh
cd ~/code/your-repo

pic                      # edits land on your Mac
pic pi --continue
pic bash
pic --clone you/your-repo
```

`/model` picks a model; `:free` costs nothing. `/quit` exits and deletes the Pi VM. Do not run `/login`; it saves a real key into the agent volume.

The default mode mounts the current folder. Use it only for repos you trust; use `--clone` otherwise. `run.sh --help` lists the flags.

`run.sh proxy` follows the proxy log. `run.sh proxy-stop` stops it. A normal `pic` starts it again.

## Keys

The env file stays on the Mac, mode 600 or 400. `run.sh` writes two filtered copies:

- `private/proxy.env`: OpenRouter key, mounted only into `pi-proxy`.
- `pi.env`: GitHub token and commit identity, passed only to Pi.

- **OpenRouter:** Pi gets `sk-or-v1-placeholder`. The proxy adds the real key. Set a credit limit.
- **GitHub:** use a fine-grained, one-repo token with Contents and Pull requests: Read and write. Keep Workflows off.
- **Push:** no `git config` or `gh auth login` needed. `gh` supplies the token, and SSH remotes are rewritten to HTTPS.
- **Commits:** set `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL`. Add `GIT_COMMITTER_*` only if the committer differs.

Pi's install ping and `gh` telemetry are off. `pi.dev` is unreachable anyway.

## Config

`run.sh` creates `~/.config/pi-container/settings.json` if missing and mounts it at
`/root/.pi/agent/settings.json`. Edit it on the Mac; changes apply on the next launch.
The default is `openrouter` / `deepseek/deepseek-v4.1-flash-1017`.

For a one-off override:

```bash
pic pi --model openrouter/<model>:high
```

## Manage

`clear.sh` saves sessions to `~/pi-backups/sessions-<time>/` before any reset.

```bash
./clear.sh save                 # sessions only, for analysis
./clear.sh nuke agent           # save, then delete pi-agent-home
./clear.sh nuke all             # also delete proxy, network, images, builder cache
./clear.sh nuke all --clones    # also delete pi-clone-* volumes
```

Add `--yes` for non-interactive use. Host config and project files stay. Set `PI_BACKUP_DIR` to move backups.

`nuke all` deletes `pi-agent:local` as well, so the next `./run.sh` fails until you
build the image again. `run.sh` says so; the command is the same one as in Setup:

```bash
container build -t pi-agent:local -f Dockerfile ..
```

## Limits

- Allowed: GitHub hosts, `openrouter.ai`, and its subdomains. Everything else is refused.
- `pi-locked` is host-only. Pi can reach your Mac and other containers on it.
- If the Mac forwards IP, the host-only network can reach the internet. `run.sh check` reports this.
- `run.sh` refuses to mount `~`, `/`, ancestors of `~`, secrets directories, or anything overlapping the config directory.
- `--clone` keeps the repo in a volume until you `git push`; uncommitted changes stay outside.
- `PI_PROXY_PORT` defaults to 8888. `PI_CPUS` defaults to 4. `PI_MEMORY` defaults to 4G.
- Rebuild with `--build-arg PI_VERSION=…` or `--build-arg ZIG_VERSION=…` to upgrade tools.

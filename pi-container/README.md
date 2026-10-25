# Pi in an Apple container

Run [Pi](https://pi.dev) on OpenRouter in an Apple [`container`](https://github.com/apple/container) VM. Pi has no internet route; `pi-proxy` is the only way out.

`pi-proxy` tunnels GitHub, adds your OpenRouter key, and refuses everything else. Pi shares only the host-only `pi-locked` network with it. One proxy serves every Pi instance.

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
build `pi-agent:local` for you; it only rebuilds `pi-proxy:local`, and it cannot
tell that the image predates an edit to the `Dockerfile` or `zigpeek/`, so
re-run the build command after changing either.

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
pic --instance work      # separate sessions and agent state
pic pi --continue
pic bash
pic --clone you/your-repo
```

`/model` picks a model; `:free` costs nothing. `/quit` exits and deletes the Pi VM. Do not run `/login`; it saves a real key into the agent volume.

The default mode mounts the current folder. Use it only for repos you trust; use `--clone` otherwise. `run.sh --help` lists the flags.

`run.sh proxy` follows the proxy log. `run.sh proxy-stop` stops it. A normal `pic` starts it again. The proxy is shared, so `proxy-stop` affects every instance.

## Multiple instances

Use an instance per terminal window. Each instance gets its own agent volume
(`pi-agent-<name>`), so sessions, `auth.json`, and installed extensions do not
collide. The settings file, proxy, network, port, and OpenRouter key stay shared.

```bash
alias pic=/path/to/pi-container/run.sh

# terminal 1
cd ~/code/repo-a && pic --instance work

# terminal 2; same or another repo
cd ~/code/repo-b && pic --instance personal

# terminal 3; the default instance keeps the original pi-agent-home volume
cd ~/code/repo-c && pic
```

`PI_INSTANCE=work pic` is equivalent to `pic --instance work`, which is handy for
one alias per window. Instance names are lowercase letters, digits, and hyphens,
up to 24 characters; `home` is reserved. The default instance is named `default`.

Use one instance per concurrent Pi process. Do not run two Pi processes against
the same instance or the same clone volume. Default-mode instances share the host
working tree, so use `--clone` when each window needs its own checkout.

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

`run.sh` creates `~/.config/pi-container/settings.json` if missing and mounts it
read-only at `/root/.pi/agent/settings.json`. The file is shared by every
instance and is the source of truth. Edit it on the Mac; changes apply on the
next launch. The default is `openrouter` /
`deepseek/deepseek-v4.1-flash-1017`.

A new file also records `lastChangelogVersion` for the image's pinned Pi version
so Pi does not try to update it. If you have an older file without that key, add
the current version or expect one failed write on startup.

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
./clear.sh list                                   # instances, sessions, clones
./clear.sh save --instance work                   # sessions only, for analysis
./clear.sh nuke agent --instance work             # save, then delete pi-agent-work
./clear.sh nuke clones --instance work            # delete work's clone volumes
./clear.sh nuke clones --legacy                   # delete old unlabelled clones
./clear.sh nuke all                               # shared reset for the default instance
./clear.sh nuke all --instance work               # shared reset for work
```

There is no bare `./clear.sh nuke`; choose `agent`, `clones`, or `all`. `save` and
`nuke` accept `--instance NAME` or `PI_INSTANCE=NAME`; without either they use
the default instance. `list` always shows every instance. Add `--yes` for
non-interactive use. Host config and project files stay. Set `PI_BACKUP_DIR` to
move backups.

`nuke agent` saves sessions, then deletes the whole agent volume: `auth.json`,
installed skills/extensions, trust decisions, and other state. The shared
settings file is not in that volume and is not deleted.

`nuke agent` and `nuke clones` are instance-scoped. Clone scoping uses volume
labels, not a separate manifest; `--legacy` is the explicit path for unlabelled
volumes left by older versions. Use those two commands for per-instance cleanup.
`nuke all` deletes the selected instance's agent volume plus the shared proxy,
network, images, and builder cache; other agent volumes and all clone volumes
stay. It is machine-wide because the proxy is shared, even when it names one
instance.

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
- `--clone` keeps the repo in a volume until you `git push`; uncommitted changes stay outside. Clone volumes are named per instance.
- Instances isolate Pi's agent volume only. The settings file, proxy key, network, and port are shared.
- `settings.json` is mounted read-only. Pi cannot change defaults, packages, resource paths, or the project-trust fallback. In-session preference changes do not persist.
- Advanced: `PI_AGENT_VOLUME` overrides the instance-derived agent volume and `PI_SETTINGS_FILE` overrides the shared settings path. Prefer `PI_INSTANCE`; `clear.sh list` discovers labelled volumes.
- `PI_PROXY_PORT` defaults to 8888. `PI_CPUS` defaults to 4. `PI_MEMORY` defaults to 4G.
- Rebuild with `--build-arg PI_VERSION=…` or `--build-arg ZIG_VERSION=…` to upgrade tools.

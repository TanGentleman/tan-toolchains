# Configuration

Source of truth for user-facing `pi-container` configuration. When adding a
flag, environment variable, generated file, pack, or build argument, update this
file, `run.sh --help` / `clear.sh help`, and the tests in the same change.

Flags override environment variables; environment variables override defaults.
Commands run from `pi-container/` unless noted.

## Design decisions

| Decision | Default | Why |
| --- | --- | --- |
| Image | `pi-agent:local` = `full` pack | Existing commands keep working; packs are opt-in. |
| OpenRouter key | Required for normal Pi and `proxy` | The proxy needs the real key for the agent. |
| GitHub token | Optional | Pi can work on a mounted repo, and `agent`/`editor` packs have no `gh`. |
| Pi hook | Installed but disabled | `enforcer on` is per instance; no prompt is blocked by surprise. |
| Agent state | Per instance, in a volume | Sessions and extensions survive restarts and stay isolated. |
| Settings | Shared per profile, read-only | Pi cannot persist preference or install changes. |
| Manual mode | Default network, no proxy | Editor work is separate from the locked Pi path. |
| Pack capability check | Refuse missing `pi` in normal mode | A clear error beats a container that cannot start its command. |
| `nuke all` image scope | The active `PI_IMAGE` only | Other pack tags are not deleted implicitly. |
| Build context | Repo root | The image compiles `../zigpeek` and `../enforcer`. |

## Host env file

The env file stays on the Mac, mode 600 or 400. The default path is
`$PI_CONFIG_DIR/env`; set `PI_ENV_FILE` to use another file. Normal Pi mode
requires it for the OpenRouter key; manual mode does not require it.

| Key | Used by | Notes |
| --- | --- | --- |
| `OPENROUTER_API_KEY` | `pi-proxy` | Required for normal Pi and `proxy`. Pi receives `sk-or-v1-placeholder`; the proxy adds the real key. Set a credit limit. |
| `GITHUB_TOKEN` | Pi, `check` | Optional. Use a fine-grained, one-repo token with Contents and Pull requests: Read and write. Keep Workflows off. |
| `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` | Pi | Optional commit identity. |
| `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` | Pi | Optional; set only when the committer differs from the author. |

`run.sh` writes filtered copies. Do not edit these; edit the host env file.

- `$PI_CONFIG_DIR/private/proxy.env`: the OpenRouter key only, mounted only into
  `pi-proxy`.
- `$PI_CONFIG_DIR/pi.env`: the GitHub token and commit identity, passed only to
  Pi. It is created only when at least one value is present; removing a token
  from the host file removes the generated file on the next normal run or
  manual clone.

Pi never receives the real OpenRouter key. Pi's install ping and `gh` telemetry
are off.

## Settings file

`run.sh` creates `$PI_SETTINGS_FILE` (default
`$PI_CONFIG_DIR/settings.json`) if missing and mounts it read-only at
`/root/.pi/agent/settings.json`. Every instance in a profile shares it. Edit it
on the Mac; changes apply on the next launch.

| Setting | Default | Notes |
| --- | --- | --- |
| `defaultProvider` | `openrouter` | Pi provider. |
| `defaultModel` | `deepseek/deepseek-v4.1-flash-1017` | Pi model. |
| `lastChangelogVersion` | Image Pi version | Set from `PI_CONTAINER_PI_VERSION`, or the Dockerfile version when the image records none. Stops Pi from updating it. |

If you rebuild with another `PI_VERSION`, update an existing host settings file;
`run.sh check` warns when it is stale.

Because settings are read-only, Pi cannot persist preference changes. These
work for the current session where applicable but do not survive a restart:

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

## Image packs

One Dockerfile builds capability packs. `./build.sh PACK` builds the pack from
the repo root context and tags it. `PI_IMAGE` selects the image at runtime.

| Pack | Tag | Contents |
| --- | --- | --- |
| `tools` | `pi-tools:local` | Zig, zigpeek, enforcer, git, jq, ripgrep, fd |
| `editor` | `pi-editor:local` | tools + Neovim + ZLS |
| `agent` | `pi-agent-lite:local` | tools + Pi; no `gh` |
| `agent-gh` | `pi-agent-gh:local` | agent + `gh` |
| `full` | `pi-agent:local` | agent-gh + Neovim + ZLS; default |

```bash
./build.sh full              # pi-agent:local
./build.sh agent             # pi-agent-lite:local, no gh
./build.sh editor            # pi-editor:local, no Pi
./build.sh all               # every pack
```

Pass extra `container build` options after the pack, for example
`./build.sh agent --build-arg PI_VERSION=1.4.0`. `all` builds every pack.

Rebuilding a pack replaces its tag and reuses the layer cache, so a Dockerfile
change only rebuilds from the first changed stage. Run `./build.sh PACK
--no-cache` for a clean build; deleting the image first is not required.

`run.sh` prints the instance, image, pack, and capabilities to stderr before it
starts. An instance is not bound to an image: `PI_IMAGE` selects the pack for
that run only.

Images record `PI_CONTAINER_CAPABILITIES` in their environment. Normal mode and
`check` both refuse an image without `pi`; `check` additionally requires
`enforcer`, `zig`, and `zigpeek`. An image with no capability metadata is
treated as a legacy full image. If `GITHUB_TOKEN` is set, `check` also requires
`gh`, so use `agent-gh` or `full`; `agent` is for tokenless runs.

## Flags

### `run.sh`

| Flag | Effect |
| --- | --- |
| `--instance NAME` | Isolate sessions and the agent volume. Defaults to `PI_INSTANCE` or `default`. |
| `--clone O/R` | Use a clone kept in a volume instead of the current folder. Defaults to `PI_CLONE` when set. |
| `--manual [CMD]` | Open a shell without Pi or the proxy. See [Manual mode](manual.md). |
| `COMMAND [ARG...]` | Run inside the normal Pi container instead of `pi`; for example, `run.sh bash`. |
| `check [O/R]` | Check keys, the proxy, GitHub when a token is present, the network lock, and enforcer. |
| `proxy` | Follow the profile's proxy logs. |
| `proxy-stop` | Stop the profile's proxy. |
| `--help` | Print usage. |

A trailing command uses normal mode: it has the proxy, settings, and agent
volume mounted, unlike `--manual`. `run.sh bash` is therefore the way to run
`enforcer on` in a persistent agent volume.

### `clear.sh`

| Flag | Effect |
| --- | --- |
| `list` | Show profiles, instances, sessions, and clone volumes. |
| `save` | Save session JSONL files under `PI_BACKUP_DIR`. |
| `nuke agent` | Save sessions, then delete the selected instance's agent volume. |
| `nuke clones` | Delete the selected instance's clone volumes in this profile. |
| `nuke all` | Delete the selected instance's agent volume plus the active image and profile resources. See [Operations](operations.md). |
| `--instance NAME` | Scope `save` or `nuke`. Defaults to `PI_INSTANCE` or `default`. |
| `--yes` | Skip the `nuke` confirmation. |
| `help` | Print usage. |

## Environment variables

### Profile and paths

| Variable | Default | Effect |
| --- | --- | --- |
| `PI_CONFIG_DIR` | `~/.config/pi-container` | Profile directory. A different path gets its own proxy, network, subnet, settings, env file, and volumes. |
| `PI_ENV_FILE` | `$PI_CONFIG_DIR/env` | Host env file. |
| `PI_SETTINGS_FILE` | `$PI_CONFIG_DIR/settings.json` | Host settings file. |
| `PI_AGENT_VOLUME` | Profile/instance-derived | Override the agent volume name. |
| `PI_BACKUP_DIR` | `~/pi-backups` | `clear.sh` backup root. |
| `PI_INSTANCE` | `default` | Default for `--instance`. |
| `PI_CLONE` | Unset | Default for `--clone`. |

### Images, names, and network

| Variable | Default | Effect |
| --- | --- | --- |
| `PI_IMAGE` | `pi-agent:local` | Image pack used by `run.sh` and `clear.sh`. |
| `PI_PROXY_IMAGE` | Profile-derived | Proxy image for this profile. |
| `PI_PROXY_NAME` | Profile-derived | Proxy container name. |
| `PI_NETWORK_NAME` | Profile-derived | Host-only network name. |
| `PI_LOCKED_SUBNET` | Profile-derived | Host-only subnet. Must match an existing profile network. |
| `PI_PROXY_PORT` | `8888` | Proxy port. Must be 1–65535. |

### Runtime and editor

| Variable | Default | Effect |
| --- | --- | --- |
| `PI_CPUS` | `4` | CPUs for normal and manual containers. |
| `PI_MEMORY` | `4G` | Memory for normal and manual containers. |
| `PI_NVIM_CONFIG` | `$PI_CONFIG_DIR/nvim` | Neovim config path on the Mac. |
| `PI_NVIM_DATA` | `$PI_CONFIG_DIR/nvim-data` | Neovim data path on the Mac. |
| `PI_NVIM_STATE` | `$PI_CONFIG_DIR/nvim-state` | Neovim state path on the Mac. |
| `PI_NVIM_CACHE` | `$PI_CONFIG_DIR/nvim-cache` | Neovim cache path on the Mac. |

Neovim paths are mounted in manual mode only. `TZ` and `COLORTERM` pass through
to the container when set on the host.

### Timeouts and tools

| Variable | Default | Effect |
| --- | --- | --- |
| `PI_PROXY_WAIT` | `90` | Seconds to wait for the proxy to answer. |
| `PI_LOCK_WAIT` | `120` | Seconds to wait for the host setup lock. |
| `CONTAINER_CLI` | `container` | CLI used by `run.sh`, `clear.sh`, `build.sh`, `record-fixtures.sh`, and `container-discovery.sh`. |

`PI_SOURCE_ONLY`, `PI_SKIP_HOST_SETUP`, and `PI_SKIP_PROXY_IP` are test hooks.
Do not use them for normal runs.

## Image build arguments

Pass these to `./build.sh PACK --build-arg ...`; defaults are in `Dockerfile`.

| Argument | Default | Effect |
| --- | --- | --- |
| `PI_VERSION` | `1.4.0` | Pi package version and settings stamp. |
| `ZIG_VERSION` | `0.17.0` | Zig toolchain; CI checks this pin. |
| `ZIG_PUBKEY` | Pinned | Zig minisign public key. |
| `NVIM_VERSION` | `0.12.6` | Neovim release. |
| `NVIM_SHA256` | Pinned | Neovim tarball checksum. |
| `ZLS_VERSION` | `0.17.0` | ZLS release. Must equal `ZIG_VERSION`. |
| `ZLS_SHA256` | Pinned | ZLS tarball checksum. |

Update the matching checksum when changing Neovim or ZLS. Base image digests are
pinned directly in `Dockerfile` and `Dockerfile.proxy`.

# Configuration

Source of truth for user-facing `pi-container` configuration. When adding a
flag, environment variable, generated file, pack, or build
argument, update this file, `run.sh --help` / `clear.sh help`, and the tests
in the same change. Commands run from `pi-container/`.

## Run settings

Three settings decide what a run is: the image, the egress profile, and where
model calls go. Each comes from a flag, then an env var, then the default.
There is no config file; set the env vars in an alias, or in the shell that
starts `pic serve` for a fleet node:

| Setting | Flag | Env var | Values | Default |
| --- | --- | --- | --- | --- |
| image | `--image PACK` | `PI_IMAGE` | `min`, `full`, `zig` ([packs](#image-packs)); the flag also takes `tools` and `editor` for `--manual` | `full` |
| egress | `--egress PROFILE` | `PI_EGRESS` | `standard`, `offline` ([egress](#egress-profiles)) | `standard` |
| model_url | `--model-url URL` | `PI_MODEL_URL` | `openrouter`, or `http://HOST:PORT` with no path | `openrouter` |

```sh
alias opic='PI_IMAGE=min PI_EGRESS=offline PI_MODEL_URL=http://gateway:8090 pic --instance offline'
```

- Bad values and pairs that cannot work (offline with `openrouter`) are
  refused before anything starts, by every command.
- `HOST` may be `gateway`: `run.sh` resolves it to the default container
  network's IPv4 gateway, the Mac's side of the bridge (e.g. `192.168.64.1`).
  A local model server for containers listens there on port 8090 and serves
  OpenAI-compatible `/v1` and `/health`.
- Secrets never go here; they stay in the [env file](#host-env-file).
- `run.sh config` prints the effective values and the source of each (`flag`,
  `env`, `default`); `run.sh config --json` prints
  `{"v":1,"image","tag","egress","model_url","source":{...}}`.
  `run.sh check` starts with the same summary.
- A fleet node is the env `pic serve` was started with: fleetd passes these
  vars to every `pi-ctr` turn, `GET /v1/node` reports them, and each turn
  records what it ran with. Restart `pic serve` to change them.

## Design decisions

| Decision | Default | Why |
| --- | --- | --- |
| Image | `full`: Pi, `gh`, enforcer | Zig, zigpeek, Neovim and ZLS are opt-in (`zig`); `min` is the smallest Pi image. |
| OpenRouter key | Required for normal Pi and `proxy` | The proxy holds the real key; it goes only to openrouter.ai. |
| GitHub token | Optional | Pi can work on a mounted repo; `min` has no `gh`; `offline` never passes it. |
| Pi hook | Installed but disabled | `enforcer on` is per instance; no prompt is blocked by surprise. |
| Agent state | Per instance, in a volume | Sessions and extensions survive restarts and stay isolated. |
| Settings | Shared per profile, read-only | Pi cannot persist preference or install changes. |
| Manual mode | Default network, no proxy | Editor work is separate from the locked Pi path. |
| Egress | `standard` | `offline` is for local models with no internet route. |
| `--allow-egress` | Off | Runs Pi on the default network when the allowlist is too narrow; the real key enters the VM. |
| Pack capability check | Refuse missing `pi` in normal mode | A clear error beats a container that cannot start its command. |
| Egress lock | On in normal mode, `check`, and `--fleet-state` | `pi-locked` alone reaches the Mac and Tailscale's resolver. See the [network boundary](../../docs/network-boundary.md). |
| `nuke all` image scope | The effective image only | Other pack tags are not deleted implicitly. |
| Build context | Repo root | Every pack but `min` compiles `../enforcer`; the Zig packs also `../zigpeek`. |

## Host env file

The env file stays on the Mac, mode 600 or 400. The default path is
`$PI_CONFIG_DIR/env`; set `PI_ENV_FILE` to use another file. Normal Pi mode
requires it for the OpenRouter key; manual mode does not require it.

| Key | Used by | Notes |
| --- | --- | --- |
| `OPENROUTER_API_KEY` | `pi-proxy`, `--allow-egress` | Required for normal Pi, `proxy`, and `--allow-egress`. Pi receives `sk-or-v1-placeholder` in normal mode; the proxy adds the real key. Egress mode passes the real key in `private/egress.env`. Set a credit limit. |
| `GITHUB_TOKEN` | Pi, `check` | Optional. Fine-grained, **Only select repositories**, **Contents: Read and write**, nothing else: not Workflows, not Administration (Metadata: Read is added for you). Add **Pull requests: Read and write** only if Pi should open PRs with `gh`; fleet doesn't. Anything in the VM can use it to push any branch of those repos, so protect your default branch with a ruleset. |
| `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` | Pi | Optional commit identity. |
| `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` | Pi | Optional; set only when the committer differs from the author. |
| `PI_EXTRA_TUNNEL` | `pi-proxy` | Optional, not a secret: extra hosts to tunnel. A shell `PI_EXTRA_TUNNEL` wins. See [Extra tunnel hosts](#extra-tunnel-hosts). |

`run.sh` writes filtered copies. Do not edit these; edit the host env file.

- `$PI_CONFIG_DIR/private/proxy.env`: the OpenRouter key only, mounted only into
  `pi-proxy`.
- `$PI_CONFIG_DIR/private/egress.env`: the OpenRouter key plus the `pi.env`
  values, passed only to `--allow-egress`. See [Egress mode](egress.md).
- `$PI_CONFIG_DIR/pi.env`: the GitHub token and commit identity, passed only to
  Pi. With egress `offline` it holds the commit identity only. It is created only when at least one value is present; removing a token
  from the host file removes the generated file on the next normal run or
  manual clone.

Pi never receives the real OpenRouter key. Pi has no install ping since 1.7.0
(an older `PI_VERSION` would send one), and `gh` telemetry is off.

## Settings file

`run.sh` creates `$PI_SETTINGS_FILE` (default
`$PI_CONFIG_DIR/settings.json`) if missing and mounts it read-only at
`/root/.pi/agent/settings.json`. Every instance in a profile shares it. Edit it
on the Mac; changes apply on the next launch.

| Setting | Default | Notes |
| --- | --- | --- |
| `defaultProvider` | `openrouter` | Pi provider. |
| `defaultModel` | `thinkingmachines/inkling-2-small` | Pi model. |
| `lastChangelogVersion` | Image Pi version | Set from `PI_CONTAINER_PI_VERSION`, or the Dockerfile version when the image records none. Stops Pi from updating it. |

If you rebuild with another `PI_VERSION`, update `lastChangelogVersion` in an
existing host settings file, or delete the file so `run.sh` re-seeds it;
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

One Dockerfile builds every pack. `./build.sh PACK` builds one from the repo
root context and tags it; `./build.sh all` builds all five. `run.sh images`
lists them, marks the effective one, and says which are built.

| Pack | Tag | Contents | Capabilities |
| --- | --- | --- | --- |
| `min` | `pi-min:local` | Pi, git, jq, ripgrep, fd; no enforcer, `gh` or Zig build stage | `netlock,pi` |
| `full` | `pi-full:local` | min + `gh` + enforcer; the default | `enforcer,netlock,pi,gh` |
| `zig` | `pi-zig:local` | full + Zig, zigpeek and its Pi skill, Neovim, ZLS | `zig,zigpeek,enforcer,netlock,pi,gh,nvim,zls` |
| `tools` | `pi-tools:local` | Zig, zigpeek, enforcer, git, jq, ripgrep, fd; no Pi | `zig,zigpeek,enforcer,netlock` |
| `editor` | `pi-editor:local` | tools + Neovim + ZLS; no Pi | `zig,zigpeek,enforcer,netlock,nvim,zls` |

`min` is the only pack whose build never waits for the Zig stage. `tools`
and `editor` run only with `--manual --image PACK`.

`./build.sh fleet` is not a pack: it runs `fleet`'s `go vet` and tests, then
cross-compiles `fleetd` for macOS arm64 into `fleet/bin/fleetd`, all in a
`golang` image pinned by digest with `GOPROXY=off` and `GOTOOLCHAIN=local`.
If a check fails, nothing is built. `pic serve` runs that binary.

Pass extra `container build` options after the pack, for example
`./build.sh min --build-arg PI_VERSION=1.7.0`. Rebuilding replaces the tag
and reuses the layer cache; `--no-cache` forces a clean build.

`run.sh` prints the instance, image, pack, capabilities, egress and model_url
to stderr before it starts. Images record `PI_CONTAINER_CAPABILITIES`; each
mode refuses an image that lacks what it needs:

| Mode | Needs |
| --- | --- |
| normal Pi, `--fleet-state` | `pi`, `netlock` (iptables for the egress lock) |
| `check` | `pi`, `netlock`; `gh` when `GITHUB_TOKEN` is set, except offline |
| `pic serve --check` | `pi`, `netlock`, and capability metadata |

`check` tests Zig and zigpeek only in an image that lists `zig`, and enforcer
only in one that lists `enforcer`. `run.sh` and `pic serve --check` refuse an
image with no metadata: it predates the egress lock, so rebuild it. `pi-ctr` scans staged changes with enforcer when the
image has it, and always with its own GitHub token patterns.

## Flags

### `run.sh`

| Flag or command | Effect |
| --- | --- |
| `--image PACK`, `--egress PROFILE`, `--model-url URL` | Override `PI_IMAGE`, `PI_EGRESS`, `PI_MODEL_URL` for this run. See [Run settings](#run-settings). |
| `--instance NAME` | Isolate sessions and the agent volume. Defaults to `PI_INSTANCE` or `default`. |
| `--scratch` | Mount no agent volume: Pi's agent dir is the container's own disk, so sessions and installs end with the run, as in a fleet turn. The current folder (or `--clone` volume) is still mounted. Normal mode only. |
| `--clone O/R` | Use a clone kept in a volume instead of the current folder. Defaults to `PI_CLONE`. Refused offline. |
| `--manual [CMD]` | Open a shell without Pi or the proxy. See [Manual mode](manual.md). |
| `--allow-egress` | Run Pi or `COMMAND` on the default network with the real OpenRouter key. Needs model_url `openrouter` and egress `standard`. See [Egress mode](egress.md). |
| `COMMAND [ARG...]` | Run inside the normal Pi container instead of `pi`; for example, `run.sh bash`. |
| `check [O/R]` | Print the config summary, then check the egress profile, keys, the proxy, GitHub (or, offline, that it is refused and the token absent), the egress lock, and enforcer when the image lists it. |
| `config [--json]` | Print the effective image, egress and model_url and their sources. Needs no container. |
| `images` | List the packs: tag, built or not, capabilities. |
| `proxy` / `proxy-stop` | Follow / stop the profile's proxy. |
| `--help` | Print usage. |

A trailing command uses normal mode: it has the proxy, settings, and agent
volume mounted, unlike `--manual`. `run.sh bash` is therefore the way to run
`enforcer on` in a persistent agent volume.

### Egress profiles

A profile is a file: the built-ins are `egress/standard.json` and
`egress/offline.json`; your own is `$PI_CONFIG_DIR/egress/NAME.json` (a
built-in name always means the built-in). `lib/egress.sh` checks it:

```json
{"v": 1, "about": "one line", "tunnel": ["github.com"], "model_url": "any", "github_token": true}
```

- `tunnel`: exact host names `pi-proxy` passes through on port 443; never
  `openrouter.ai`, which it intercepts to add the key. Everything else is
  refused.
- `model_url`: `any`, or `private` (model calls only to an http `model_url`
  on `gateway` or a private IPv4 address).
- `github_token`: whether Pi gets `GITHUB_TOKEN`.

Every profile runs behind `pi-proxy` and the egress lock. The built-ins:

| Route | `standard` | `offline` |
| --- | --- | --- |
| GitHub (`github.com`, `api.github.com`, ...) | Tunnelled | Refused (403) |
| Model calls (`openrouter.ai`) | To openrouter.ai with the real key, or to an http `model_url` with the placeholder | Only to `model_url`, with the placeholder |
| Every other host, direct IPs, DNS | Refused | Refused |
| `GITHUB_TOKEN` in `pi.env` | When set | Never |

`offline` needs an http `model_url` on `gateway` or a private IPv4 address
(10/8, 172.16/12, 192.168/16, 169.254/16); `openrouter`, a name, loopback or
a public address is refused before anything starts, and `pi-proxy` refuses
to start without one. Any profile but `standard` refuses `--manual` and
`--allow-egress`. Without `github.com` in `tunnel`, `--clone O/R` clones
from `$PI_CONFIG_DIR/mirrors/O/R.git` (make it with `git clone --mirror`),
mounted read-only, and fleet turns keep their commits in the session's
`repo.bundle` instead of pushing.
### Extra tunnel hosts

`PI_EXTRA_TUNNEL` adds hosts to the effective profile's `tunnel` for runs
behind `pi-proxy`, e.g. an API one agent needs, without a profile of its own.
It is read from the shell, else from a `PI_EXTRA_TUNNEL=` line in the
[env file](#host-env-file):

```sh
PI_EXTRA_TUNNEL=https://NAME.convex.site run.sh --egress offline --model-url http://gateway:8090 pi
```

- Comma-separated host names, or `https://HOST` URLs with no path or port
  (so a site URL variable works as is). The same rules as a profile's
  `tunnel` apply: lowercase host names, never `openrouter.ai`, at most 64
  hosts in all. A bad entry is refused, and named, before anything starts.
- `run.sh config` shows the hosts and their source (`env` or `env file`);
  `config --json` adds `extra_tunnel` and `source.extra_tunnel`, and
  `egress_profile.tunnel` is the merged list.
- `--manual` and `--allow-egress` have no proxy, so they ignore it.

Changing the egress, the extra tunnel hosts or model_url recreates `pi-proxy` from the same image.
`check` asks `pi-proxy` which profile it enforces and fails on a mismatch.

### `clear.sh`

| Flag | Effect |
| --- | --- |
| `list` | Show profiles, instances, sessions, and clone volumes. |
| `save` | Save session JSONL files under `PI_BACKUP_DIR`. |
| `nuke agent` | Save sessions, then delete the selected instance's agent volume. Without the agent image the backup is skipped, not fatal. |
| `nuke clones` | Delete the selected instance's clone volumes in this profile. |
| `nuke profile` | Delete this profile: every instance's agent volume, its clone volumes, proxy, network, and proxy image. The shared image and builder cache stay. |
| `nuke all` | `nuke profile`, then the effective image and the builder cache. See [Operations](operations.md). |
| `--image PACK` | The image `nuke all` deletes and `save` reads with. Defaults to `PI_IMAGE`, else `full`. |
| `--instance NAME` | Scope `save`, `nuke agent`, or `nuke clones`. Defaults to `PI_INSTANCE` or `default`. `nuke profile` and `nuke all` refuse it. |
| `--yes` | Skip the `nuke` confirmation. |
| `help` | Print usage. |

## Environment variables

Most runs need only `PI_IMAGE`, `PI_EGRESS`, `PI_MODEL_URL`
([run settings](#run-settings)), `PI_INSTANCE`, `PI_CONFIG_DIR` and
`PI_ENV_FILE`. The rest override derived names, sizes and timeouts.

### Profile and paths

| Variable | Default | Effect |
| --- | --- | --- |
| `PIC_HOME` | `~/.pic` | Root for the default profile, backups, fleet data, the lock and `overrides.env`. Profiles under another root don't share this root's lock. |
| `PI_CONFIG_DIR` | `~/.pic/config` | Profile directory. A different path gets its own proxy, network, subnet, settings, env file, and volumes. |
| `PI_ENV_FILE` | `$PI_CONFIG_DIR/env` | Host env file. |
| `PI_SETTINGS_FILE` | `$PI_CONFIG_DIR/settings.json` | Host settings file. |
| `PI_AGENT_VOLUME` | Profile/instance-derived | Override the agent volume name. |
| `PI_BACKUP_DIR` | `~/.pic/backups` | `clear.sh` backup root. |
| `PI_INSTANCE` | `default` | Default for `--instance`. |
| `PI_CLONE` | Unset | Default for `--clone`. |

Everything pi-container and fleetd write is below `PIC_HOME`:

| Path | Holds |
| --- | --- |
| `config/` | The default profile: `env`, `pi.env`, `settings.json`, `certs/`, `egress/`, `mirrors/`, `nvim*/`, `private/` |
| `profiles/NAME/` | Other profiles, by convention; `PI_CONFIG_DIR` may name any path |
| `backups/` | `clear.sh` session backups |
| `fleet/` | fleetd sessions, blobs and logs; `run.sh --fleet-state` mounts only from `fleet/sessions/` |
| `lock` | Serializes image, network and builder-cache changes |
| `overrides.env` | Paths `pic migrate` left in place |

`run.sh` refuses to mount a project inside `PIC_HOME`. Only `~/.pic/config`
keeps the default names (`pi-proxy`, `pi-locked`, `pi-agent-home`); another
root's `config/` hashes its path like any other profile.

`overrides.env` (mode 600) starts with `# pic overrides v1`, then holds
`PI_BACKUP_DIR=` or `PI_ENV_FILE=` lines with absolute paths; a leading
`$HOME` is expanded, and `pic migrate` writes paths that way. An env var of
the same name wins. `run.sh`, `clear.sh` and `pic serve` refuse any other key,
version or mode.

While a v7 path (`~/.config/pi-container`, `~/pi-backups` or `~/.fleet`)
exists and isn't kept by `overrides.env`, `run.sh`, `clear.sh` and `pic serve`
exit 2 and name `pic migrate`; see
[operations.md](operations.md#moving-from-v7).

### Names and network

| Variable | Default | Effect |
| --- | --- | --- |
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
| `CONTAINER_CLI` | `container` | CLI used by `run.sh`, `clear.sh`, `build.sh`, and `record-fixtures.sh`. |

Internal, not settings: `PI_SOURCE_ONLY`, `PI_SKIP_HOST_SETUP`,
`PI_SKIP_PROXY_IP` and fleetd's `FLEET_PI_CTR_BIN` are test hooks;
`PI_PROXY_*` inside the proxy container, `PI_CLONE_SOURCE` inside an offline
clone, and `PI_CTR_*` inside a fleet turn are set by `run.sh` and `pi-ctr`. Do
not set them for normal runs.

## Image build arguments

Pass these to `./build.sh PACK --build-arg ...`; defaults are in `Dockerfile`.

| Argument | Default | Effect |
| --- | --- | --- |
| `PI_VERSION` | `1.7.0` | Pi package version and settings stamp. |
| `ZIG_VERSION` | `0.17.0` | Zig toolchain; CI checks this pin. |
| `ZIG_PUBKEY` | Pinned | Zig minisign public key. |
| `NVIM_VERSION` | `0.12.6` | Neovim release. |
| `NVIM_SHA256` | Pinned | Neovim tarball checksum. |
| `ZLS_VERSION` | `0.17.0` | ZLS release. Must equal `ZIG_VERSION`. |
| `ZLS_SHA256` | Pinned | ZLS tarball checksum. |

Update the matching checksum when changing Neovim or ZLS. Base image digests are
pinned directly in `Dockerfile` and `Dockerfile.proxy`.

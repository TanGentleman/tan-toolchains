# Operations

Profiles, instances, keys, settings, and cleanup. Run commands from
`pi-container/`.

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
instances also share the Neovim paths in [Manual mode](manual.md); use the
`PI_NVIM_*` overrides if parallel editors need separate state.

## Keys

The env file stays on the Mac, mode 600 or 400. `run.sh` writes two filtered
copies:

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
`PI_CONTAINER_PI_VERSION` environment value, or the Dockerfile version when the
image records none, so Pi does not try to update it. If you rebuild with another
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

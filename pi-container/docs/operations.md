# Operations

Profiles, instances, and cleanup. Run commands from `pi-container/`. Keys,
settings, flags, environment variables, and build arguments are in
[Configuration](configuration.md).

## Profiles and instances

Use an instance per terminal window. Within a profile, each instance gets its
own agent volume (the default profile uses `pi-agent-<name>`), so sessions,
`auth.json`, and installed extensions do not collide. The settings file, proxy,
network, port, and OpenRouter key stay shared.

`PI_CONFIG_DIR` selects a profile. The default is `~/.config/pi-container`;
another directory gets its own settings, env file, proxy, host-only network,
subnet, proxy image, agent volumes, and clone volumes. The agent image and
builder cache stay machine-wide.

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

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
subnet, proxy image, agent volumes, and clone volumes. The active image and
builder cache stay machine-wide; `PI_IMAGE` picks the image per run.

```bash
T=~/path/to/tan-toolchains     # your checkout
alias pic=$T/pi-container/run.sh

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
./clear.sh nuke profile                           # delete the whole profile, keeping the shared image
./clear.sh nuke all                               # nuke profile, plus the agent image and builder cache
./clear.sh export                                 # every pi volume, minus auth.json, to ~/pi-backups/export-<time>/
./clear.sh import ~/pi-backups/export-<time>      # recreate them, e.g. after reinstalling container
```

`nuke` requires `agent`, `clones`, `profile`, or `all`. `save`, `nuke agent`
and `nuke clones` accept `--instance NAME` or `PI_INSTANCE=NAME`; without
either they use the default instance in the current profile. `nuke profile`
and `nuke all` cover every instance and refuse `--instance`. `list` shows every profile and instance. Add
`--yes` for non-interactive use, and set `PI_BACKUP_DIR` to move backups. Host
config and project files stay.

`nuke agent` saves sessions, then deletes the whole agent volume: `auth.json`,
installed skills/extensions, trust decisions, and other state. The profile
settings file is not in that volume. When the agent image is absent -- `nuke
all`, or a hand-run `container image delete` -- the volume is deleted without a
backup and the output says so, because cleanup must not depend on an image
another profile may have removed.

`nuke clones` deletes the selected instance's clone volumes in the current
profile, scoped by volume labels. `nuke all` does what `nuke profile` does,
then deletes the active image (`--image`, else `PI_IMAGE`, else
`pi-full:local`) and the builder cache. It keeps other profiles and other pack
tags. The active image is machine-wide, so other profiles using it still need
to rebuild. It does not delete the Neovim host paths under `$PI_CONFIG_DIR`
(default `~/.config/pi-container/`). The next `./run.sh` fails until you rebuild
the active pack:

```bash
./build.sh full          # or the pack PI_IMAGE names
```

## Rebuilding from scratch

After a Pi or base-image bump, to start from nothing but the config directory.
Run from `pi-container/`, with every `pic` and `pic serve` stopped.

1. Find unpushed work. Clone volumes are deleted in step 3, and only pushed
   commits survive. For each clone `list` shows:

   ```bash
   ./clear.sh list
   ./run.sh --manual --clone you/your-repo     # shell in /work/<repo>
   git status --short; git log --branches --not --remotes --oneline; exit
   ```

   Commit and push anything you want to keep.
2. Save transcripts while the agent image still exists; without it, step 3
   deletes volumes without a backup. Repeat `save` for every instance `list`
   shows, then check the files are there:

   ```bash
   ./clear.sh save                              # default instance
   ./clear.sh save --instance work
   find ~/pi-backups -name '*.jsonl' | wc -l
   cp -a ~/.fleet ~/pi-backups/fleet-$(date +%Y%m%d)   # fleet sessions, if you run pic serve
   ```
3. Delete the profile (every instance's agent volume, saved again first, its
   clone volumes, proxy, network and proxy image), the shared agent image and
   the builder cache:

   ```bash
   ./clear.sh nuke all --yes
   container image list                         # other pack tags, e.g. pi-min:local, stay; delete them by hand
   ```
4. Drop the seeded settings so the next start writes them for the new Pi
   version and default model, then rebuild and check:

   ```bash
   rm ~/.config/pi-container/settings.json      # only if you have not edited it; otherwise update lastChangelogVersion
   ./build.sh full                              # or the pack you use
   ./build.sh fleet                             # if you run pic serve
   ./run.sh check you/your-repo                 # "settings lastChangelogVersion is current"
   ```

`~/.config/pi-container/env`, `~/pi-backups` and `~/.fleet` are never touched.

## Retiring a profile

`nuke profile` deletes everything a `PI_CONFIG_DIR` owns: the agent volume of
every instance (sessions saved first), the profile's clone volumes, its proxy,
its host-only network, and its proxy image. It keeps the shared agent image,
the builder cache, other profiles, and the config directory itself, so the
other profiles do not need a rebuild.

```bash
PI_CONFIG_DIR=~/.config/pi-container-work ./clear.sh nuke profile
rm -rf ~/.config/pi-container-work        # only when the directory is retired
```

Every name in the stack derives from the config path, so a profile is still
reachable after its directory is gone -- the state that otherwise strands a
running `pi-proxy-<id>` holding the real OpenRouter key. `list` marks those rows
`(missing)` in the settings column; delete them with the path it prints:

```bash
./clear.sh list                           # b0536c38 ... /var/folders/.../settings.json (missing)
PI_CONFIG_DIR=/var/folders/... ./clear.sh nuke profile
```

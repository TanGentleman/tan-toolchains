# container 1.6.1 → 1.7.1

What changed upstream ([1.6.1...1.7.1](https://github.com/apple/container/compare/1.6.1...1.7.1),
23 commits, Containerization 0.53.0 → 0.54.0) that our call sites or behavior
can see, and how to move a Mac across without losing sessions or config.
Read from source; nothing here has run on 1.7.1 yet. `test/container-probe.sh`
fills that gap: run it on 1.6.1, upgrade, run it again, and diff.

**Observed on 1.6.1** (one Mac, macOS 26.7.3, 10 cores): VMs boot 6.18.15,
the kernel installed months earlier, although 1.6.1's own default is
6.18.35. iptables-legacy and ip6tables-legacy work, `nf_conntrack` is absent,
and every parser in `lib/inspect.sh` reads the live output. `stop`, `start`,
`kill` and `delete` on a missing name already exit 1. Volumes are 311 MB;
images (13.5 GB) and snapshots (11 GB) are all rebuildable.

## What can affect us

| Change | Our call sites | Risk |
|---|---|---|
| Default kernel: Kata 3.32.0 `vmlinux-6.18.35-197` → Kata 4.3.1 `vmlinux-6.18.56-208`. `system start` only installs a kernel when none is set, so an upgraded Mac keeps booting whatever kernel it first installed until `container system kernel set --recommended`. A fresh install gets 6.18.56. | `lib/netlock.sh` (iptables-legacy, `ip_tables`), every VM | **Medium.** Kata's netfilter fragment is identical between the two tags (`IP_NF_IPTABLES_LEGACY=y`, `IP6_NF_IPTABLES_LEGACY=y`), so the lock should load, but the egress lock is the security boundary: re-run `run.sh check` and `test/vm-net-diag.sh` on the new kernel. |
| `--cpus` is now rejected above the host's core count; `--memory` gets an overflow check (200 MiB minimum unchanged). | `run.sh` `--cpus "${PI_CPUS:-4}"`, proxy `--cpus 1 --memory 1G` | Low. Defaults fit every Apple silicon Mac; a large `PI_CPUS` now fails at `run` instead of being clamped. |
| New `[container.dns]` defaults in the system config (`domain`, `nameservers`, `searchDomains`, `options`), applied to every `run` and to the builder unless flags override. | `run` never passes `--dns` | Low, unless someone sets it: VMs on `pi-locked` would get those nameservers in `resolv.conf`. The lock still drops their traffic; `vm-net-diag.sh` shows it. |
| `start`/`stop`/`kill`/`delete`/`prune`/`list` exclude `cluster` plugin containers as well as `machine`; named lookups go through `findContainers`, which reports a hidden or missing name as not found. | `run.sh` proxy and fleet `stop`/`start`/`delete --force`, `clear.sh` proxy delete | Low. We never create cluster resources, and missing names already fail (we `|| true` them). The probe records the exit codes. |
| Builder: gRPC `:authority` now sent to the builder shim (newer gRPC-Go rejects requests without it), DNS defaults passed to the builder, a build-context sync fix. | `build.sh`, `clear.sh nuke all` (`builder delete --force`) | Low. Recreate the builder after upgrading so it runs the new shim. |
| Containerization 0.54.0: vminitd gRPC `:authority`, `LinuxPod` subpath mounts. | every VM | Low. Containers created on 1.6.1 (the proxy) should be recreated, not restarted. |
| `containers/` and `snapshots/` under the app root are excluded from Time Machine when 1.7.1 creates them. The diff does not touch `volumes/`. | none | None for us; listed because it changes what a Time Machine restore brings back. |
| Installer: binaries stripped, new cluster plugins in `libexec`. | README install block | None. Same `/usr/local/bin` paths and `update-container.sh`/`uninstall-container.sh`. |
| `stats` CPU output, cluster commands, `machine` changes. | none | None. |

Unchanged in the diff: the JSON paths in [ASSUMPTIONS.md](../ASSUMPTIONS.md)
(`inspect`, `network inspect`, `image inspect`, `volume inspect`, the `-q`
listings), `network create --internal --subnet`, `volume create --label`,
`run --cap-add`, and `run` exit codes. The probe prints the live shapes and
runs our `lib/inspect.sh` parsers on them, so a diff of the two outputs is the
check.

## Where the data lives

| Data | Location | Kept by `uninstall-container.sh -d`? |
|---|---|---|
| Profile config: settings, egress profiles, mirrors, Neovim state, env file (keys) | `$HOME/.pic/config` (`PI_CONFIG_DIR`) | Yes, outside the app root |
| Session backups and exports | `$HOME/.pic/backups` | Yes |
| Fleet state | `$HOME/.pic/fleet` | Yes |
| Agent volumes: `sessions/`, `auth.json`, extensions, models | app root `volumes/` | **No** |
| Clone volumes: worktrees, uncommitted work | app root `volumes/` | **No** |
| Images, proxy, `pi-locked` network, builder cache, kernel | app root | No; `build.sh`, `run.sh` and `system start` recreate them |

The app root is `$HOME/Library/Application Support/com.apple.container`.
Only volumes hold data we can't regenerate.

## Migration

One pass from v7 on 1.6.1 to v8 on 1.7.1. Quit every Pi and `--manual`
session, stop `pic serve`, then in `pi-container/` on this branch:

```sh
container stop pi-proxy
./run.sh migrate                                # v7 paths -> ~/.pic (operations.md#moving-from-v7)
./clear.sh list                                 # every volume, no (missing)
./clear.sh export                               # -> ~/.pic/backups/export-<time>/
test/migrate-check.sh                           # before: expect FAIL on version and kernel only
/usr/local/bin/uninstall-container.sh -d        # deletes the app root
V=1.7.1
curl -fLo /tmp/container.pkg "https://github.com/apple/container/releases/download/$V/container-$V-installer-signed.pkg"
sudo installer -pkg /tmp/container.pkg -target /
container system start                          # answer Y: installs the 1.7.1 kernel
./build.sh                                      # each pack you use; run.sh builds the proxy
./clear.sh import ~/.pic/backups/export-<time>
test/migrate-check.sh                           # paste this
```

`pic migrate` runs first because v8's `clear.sh` refuses while v7 paths
exist. It deletes the volumes of any extra `~/.config/pi-container-NAME`
profile you move, after saving their sessions, so those are not in the
export.

`export` writes `NAME.tar` and `NAME.labels.json` for each volume labelled
`pi.managed=true`, in every profile, leaving out `auth.json`; log in again
inside Pi afterwards. `import` recreates each volume with the same name and
labels, pointing labels that still name `~/.config/pi-container` at
`~/.pic/config`, and refuses if any volume already exists.

`test/migrate-check.sh [EXPORT_DIR]` prints one PASS, WARN or FAIL line per
check: the CLI and kernel versions, the `~/.pic` layout, each exported
volume's labels and file counts against the export (newest
`export-*` by default), the egress lock in a fresh VM, and `run.sh check`.
Paths print as `$HOME/...`; it reads no env files or volume contents beyond
file counts.

**Without a nuke** (what the Mac above did; `migrate-check.sh` passed), the
in-place upgrade keeps volumes but leaves the old kernel and builder:

```sh
container system stop && /usr/local/bin/update-container.sh -v 1.7.1 && container system start
container system kernel set --recommended
container builder delete --force
container delete --force pi-proxy               # run.sh recreates it
```

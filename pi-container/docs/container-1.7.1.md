# container 1.6.1 → 1.7.1

What changed upstream ([1.6.1...1.7.1](https://github.com/apple/container/compare/1.6.1...1.7.1),
23 commits, Containerization 0.53.0 → 0.54.0) that our call sites or behavior
can see, and how to move a Mac across without losing sessions or config.
Read from source; nothing here has run on 1.7.1 yet. `test/container-probe.sh`
fills that gap: run it on 1.6.1, upgrade, run it again, and diff.

## What can affect us

| Change | Our call sites | Risk |
|---|---|---|
| Default kernel: Kata 3.32.0 `vmlinux-6.18.35-197` → Kata 4.3.1 `vmlinux-6.18.56-208`. `system start` only installs a kernel when none is set, so an upgraded Mac keeps booting 6.18.35 until `container system kernel set --recommended`. A fresh install gets 6.18.56. | `lib/netlock.sh` (iptables-legacy, `ip_tables`), every VM | **Medium.** Kata's netfilter fragment is identical between the two tags (`IP_NF_IPTABLES_LEGACY=y`, `IP6_NF_IPTABLES_LEGACY=y`), so the lock should load, but the egress lock is the security boundary: re-run `run.sh check` and `test/vm-net-diag.sh` on the new kernel. |
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
| Profile config: settings, egress profiles, env file (keys) | `$HOME/.config/pi-container` (`PI_CONFIG_DIR`) | Yes, outside the app root |
| Session backups from `clear.sh save` | `$HOME/pi-backups` | Yes |
| Fleet state | `$HOME/.fleet` | Yes |
| Agent volume: `sessions/`, `auth.json`, extensions, models | app root `volumes/` | **No** |
| Clone volumes: worktrees, uncommitted work | app root `volumes/` | **No** |
| Images, proxy, `pi-locked` network, builder cache | app root | No; all rebuilt by `build.sh` and `run.sh` |

The app root is `$HOME/Library/Application Support/com.apple.container`.
Everything outside it survives any nuke; only volumes hold data we can't
regenerate.

## Migration

**In place (keeps volumes).** Quit every `pic` and fleet turn, then:

```sh
pi-container/clear.sh save                      # per instance: --instance NAME
container system stop && /usr/local/bin/update-container.sh && container system start
container system kernel set --recommended       # otherwise VMs stay on 6.18.35
container builder delete --force
container delete --force "$(. pi-container/names.sh; pi_proxy_name "$HOME/.config/pi-container")"
pi-container/run.sh check && pi-container/test/vm-net-diag.sh
```

**Full nuke (keeps sessions, config, non-secret volume data).** Planned,
not written yet, pending the probe output: `clear.sh export DIR` tars each
`pi.managed` volume with its labels to `$HOME/pi-backups/`, leaving out
`auth.json` (re-login is cheap and it holds credentials), then
`uninstall-container.sh -d`, install the 1.7.1 `.pkg`, `build.sh`, and
`clear.sh import DIR` recreates each volume from its labels and untars it.
Clone volumes are exported too, so uncommitted work survives.

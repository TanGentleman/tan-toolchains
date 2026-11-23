# tan-toolchains

One tool per directory.

| Tool | What it is |
| ---- | ---------- |
| [`zigpeek/`](zigpeek/) | Zig stdlib + `@`-builtin docs from your installed compiler. No network. |
| [`enforcer/`](enforcer/) | A Pi prompt hook that blocks a pasted GitHub token. No network. |
| [`pi-container/`](pi-container/) | Pi in an Apple `container` VM behind an egress proxy, with Zig, Neovim, ZLS, zigpeek, and enforcer. |
| [`fleet/`](fleet/) | `fleetd`: spawn, record and fork Pi sessions on one machine, driven from any tailnet device. |

## Quick start

Each tool has its own setup. Start with the one you want:

| To | You need | Follow |
| --- | --- | --- |
| Run Pi in a VM on your Mac | Apple silicon, macOS 26, Homebrew, an OpenRouter key; optionally a [GitHub token](pi-container/docs/configuration.md#host-env-file) | [pi-container setup](pi-container/README.md#setup) |
| Start Pi sessions from your phone | the above, plus Tailscale; no Go | [fleet on macOS](fleet/docs/macos.md), every step with a check |
| Build zigpeek or enforcer on the host | [Zig 0.17.0](#zig-0170) | [zigpeek](zigpeek/README.md), [enforcer](enforcer/README.md#build-and-test) |

pi-container and fleet need no host Zig: the image builds zigpeek and
enforcer with its own.

## Zig 0.17.0

zigpeek, enforcer and the image pin Zig 0.17.0. Use a package manager's Zig
only if `zig version` prints `0.17.0`. Otherwise download it from
ziglang.org and verify it with [minisign](https://jedisct1.github.io/minisign/)
and Zig's key (the same key `pi-container/Dockerfile` uses):

```sh
v=0.17.0 t=aarch64-macos   # or x86_64-macos, x86_64-linux, aarch64-linux
curl -fLO "https://ziglang.org/download/$v/zig-$t-$v.tar.xz"
curl -fLO "https://ziglang.org/download/$v/zig-$t-$v.tar.xz.minisig"
minisign -Vm "zig-$t-$v.tar.xz" -P RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
tar -xJf "zig-$t-$v.tar.xz"   # then put zig-$t-$v/ on PATH
zig version                   # 0.17.0
```

## Docs

- [zigpeek/README.md](zigpeek/README.md): commands, build, and the stdlib index.
- [enforcer/README.md](enforcer/README.md): the Pi prompt hook, policy, and safety rules.
- [pi-container/README.md](pi-container/README.md): setup, use, limits, and links to the configuration and operations docs.
- [fleet/docs/macos.md](fleet/docs/macos.md): fleet setup on a Mac, from zero, with a check per step.
- [pi-container/E2E.md](pi-container/E2E.md): manual macOS checklist.
- [fleet/README.md](fleet/README.md): model, API, tests, and what is left out.
- [AGENTS.md](AGENTS.md): development rules, toolchain policy, and version pins.

## Network boundary

Pi's VM runs behind the egress lock in pi-container's normal mode, `run.sh
check`, and fleet turns.

- **Allowed:** `pi-proxy` only. It tunnels GitHub, adds the OpenRouter key
  for `openrouter.ai`, and refuses every other host.
- **Blocked:** the Mac and its services (for example Continuity's
  `rapportd`), Tailscale's DNS resolver at `100.100.100.100` and with it your
  tailnet names, the tailnet, and the internet, over IPv4 and IPv6.
- **How:** the VM is on the host-only `pi-locked` network, which alone still
  reaches the Mac and Tailscale's resolver. Before anything else runs,
  iptables inside the VM (`pi-container/lib/netlock.sh`) allows only loopback
  and the proxy's port; then `NET_ADMIN` and `NET_RAW` are dropped, so nothing
  Pi starts can change the rules. An image without the `netlock` capability is
  refused.
- **Limit:** the lock trusts the VM's kernel. A kernel exploit could remove
  the rules.
- **Unlocked modes:** `--manual` (a shell without Pi) and `--allow-egress` (Pi
  with the real key) use the container's default network with no lock and no
  proxy. They reach any host and protocol, including the Mac's services and
  Tailscale's resolver.
- **Checks:** `run.sh check` and `pi-container/test/fleet-isolation.sh`
  confirm the lock from inside a VM.

Shipped tools run on macOS and make no network requests. A separate process
owns any network layer; `fleetd` is that process for fleet, loopback-only
behind `tailscale serve`.

# tan-toolchains

One tool per directory.

| Tool | What it is |
| ---- | ---------- |
| [`zigpeek/`](zigpeek/) | Zig stdlib + `@`-builtin docs from your installed compiler. No network. |
| [`enforcer/`](enforcer/) | A Pi prompt hook that blocks a pasted GitHub token. No network. |
| [`pi-container/`](pi-container/) | Pi in an Apple `container` VM behind an egress proxy, with Zig, Neovim, ZLS, zigpeek, and enforcer. |
| [`fleet/`](fleet/) | `fleetd`: spawn, record and fork Pi sessions on one machine, driven from any tailnet device. |

## Quick start

```sh
# zigpeek
(cd zigpeek && zig build --release=small)
./zigpeek/zig-out/bin/zigpeek search ArrayList

# enforcer
(cd enforcer && zig build --release=small)

# pi-container
cd pi-container
./build.sh full
./run.sh check you/your-repo
```

## Docs

- [zigpeek/README.md](zigpeek/README.md): commands, build, and the stdlib index.
- [enforcer/README.md](enforcer/README.md): the Pi prompt hook, policy, and safety rules.
- [pi-container/README.md](pi-container/README.md): setup, use, limits, and links to the configuration and operations docs.
- [pi-container/E2E.md](pi-container/E2E.md): manual macOS checklist.
- [fleet/README.md](fleet/README.md): model, API, tests, and what is left out.
- [AGENTS.md](AGENTS.md): development rules, toolchain policy, and version pins.

## Boundaries

- `pi-container/` runs Pi in an Apple `container` VM. `pi-proxy` is its only
  network path in normal mode; `--manual` uses the default network without Pi,
  and `--allow-egress` gives Pi the default network and the real key.
- Shipped tools run on macOS and make no network requests. A separate process
  owns any network layer; `fleetd` is that process for fleet, loopback-only
  behind `tailscale serve`.

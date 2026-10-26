# tan-toolchains

One tool per directory.

| Tool | What it is |
| ---- | ---------- |
| [`zigpeek/`](zigpeek/) | Zig stdlib + `@`-builtin docs from your installed compiler. No network. |
| [`pi-container/`](pi-container/) | Pi in an Apple `container` VM: allowlist egress proxy, Zig 0.17.0, Neovim 0.12.6 + ZLS 0.17.0, zigpeek. |

## zigpeek

```sh
cd zigpeek && zig build --release=small
zigpeek search ArrayList
zigpeek get std.Io.Dir.openFile
```

See [zigpeek/README.md](zigpeek/README.md).

## pi-container

```sh
cd pi-container
container build -t pi-agent:local -f Dockerfile ..
./run.sh check you/your-repo
```

The image builds `../zigpeek` from source, so the lookup tool and the Zig it
documents are the same version. `./run.sh --instance NAME` runs Pi in several
terminal windows with isolated sessions behind one shared proxy per profile.
`./run.sh --manual` opens a local Neovim/ZLS shell without Pi. See
[pi-container/README.md](pi-container/README.md).

Local-only diagnostics live in [`scripts/`](scripts/), including
`container-discovery.sh` for capturing real Apple `container` JSON shapes. See
[scripts/README.md](scripts/README.md).

## Scope and network boundary

- **Dev environment:** `pi-container/` runs Pi in an Apple `container` VM,
  where the tools are built and the agent works. Pi's proxy is its only network
  path. `./run.sh --manual` is a separate local-development shell on the
  container's default network.
- **Shipped binaries:** tools built here run on macOS outside the container and
  make no network requests; when a tool needs the network, it delegates to a
  separate process that owns the network layer. Zig 0.17.0's `std.http.Client`
  mishandles HTTPS through a CONNECT proxy, which breaks dev-time `zig fetch`
  inside the container; that is a container limitation, not a reason to add
  network code to a shipped binary.

## Toolchain policy

- No compiler tarballs, wheels, or package caches in Git; a tool is built from
  source or fetched from its publisher.
- Verify downloads against the publisher's signature (Zig: minisign) or, when
  none is published, the publisher's release checksum (Neovim/ZLS).
- Pin versions explicitly; CI checks the Zig pins, and the image build checks
  the installed tool versions.
- Each tool owns its build and test story: `zig build test` for zigpeek, CI for
  the source, `run.sh check` for the container.

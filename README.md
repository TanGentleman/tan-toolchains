# tan-toolchains

Tooling that comes in handy, one directory per tool.

| Tool | What it is |
| ---- | ---------- |
| [`zigpeek/`](zigpeek/) | Zig stdlib + `@`-builtin docs from your installed compiler. Pure Zig, no network. |
| [`pi-container/`](pi-container/) | Pi in an Apple `container` VM: allowlist egress proxy, Zig 0.17.0, zigpeek. |

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

The image builds `../zigpeek` from source and installs it as `zigpeek`, so the
lookup tool and the Zig it documents are the same version. See
[pi-container/README.md](pi-container/README.md).

## Scope and network boundary

- **Dev environment:** `pi-container/` runs Pi in an Apple `container` VM. It is
  where the tools are built and where the agent works. Its proxy is the only
  network path for Pi and for dev-time fetches.
- **Shipped binaries:** handy tools built here run on macOS outside the
  container. They do not make network requests. When they need the network,
  they delegate to a separate process that owns the network layer.
- **Known dev gap:** Zig 0.17.0's `std.http.Client` mishandles HTTPS through a
  CONNECT proxy. This affects dev-time `zig fetch` inside the container; it is
  not a reason to add network code to a shipped binary. Keep binaries
  network-free and let the container's proxy serve Pi and dev-time fetches.
- **Release:** not configured yet. Add a workflow when you are ready to
  publish binaries.

## Toolchain policy

- No compiler tarballs, wheels, or package caches in Git. Keep the repository
  cloneable; a tool is built from source or fetched from its publisher.
- Verify downloads against the publisher's signature (Zig: minisign), not just
  a checksum from the same page.
- Pin versions in one place per tool and read them from there.
- Each tool owns its build and test story: `zig build test` for zigpeek, CI for
  the source, `run.sh check` for the container.

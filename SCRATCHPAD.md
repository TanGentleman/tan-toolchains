# Tan Toolchains — scratchpad

Working notes after retiring the oversized sandbox branch and reviewing the
remaining branches. Last updated: 2026-10-24.

## Snapshot

| Ref | State | Purpose |
| --- | --- | --- |
| `main` | Small, default branch | Minimal umbrella: currently only a one-line README |
| `container-bootstrap-v1` | Active feature branch, 12 commits | `pi-container`: Pi in an Apple `container` VM with an allowlist proxy, stable Zig 0.17.0, and zigpeek |
| `zigpeek` | Active feature branch, 5 commits | Pure-Zig `zigpeek` 0.6.0 stdlib/builtin lookup CLI, targeting Zig 0.17.0 |
| `sandbox/linux-x86_64` | **Deleted** | Old offline sandbox with ~75 MiB of vendored binaries |

The live feature branches are separate stacks on `main`; neither has been merged
into the default branch yet. The useful direction is clear: keep `main` as a
small umbrella, never commit toolchain binaries, and let each tool own its build
and test story.

## Retired branch: `sandbox/linux-x86_64`

### Why it was deleted

It was a single commit (`b8d57c0`, "Stage Zig 0.17-dev + tracers dep cache for
sandbox builds") on top of `main`. That commit added **74.96 MiB** of vendored
files. The rest of the repository was only about **0.09 MiB**, so a normal clone
paid the full cost even when nobody needed the offline sandbox.

The branch was also stale:

- Zig was `0.17.0-dev.947+36069a2a7`, not Zig 0.17.0 stable.
- zigpeek was 0.4.1, while the container branch now uses 0.5.1 and the pure-Zig
  branch is 0.6.0.
- The package cache matched the old tracers lock, not the current stable-Zig
  build.
- `setup.sh` referenced the old `zig-toolchain` repository name and set
  `ZIGPEEK_VERSION=master` while installing wheel 0.4.1.

### What it contained

| Path | Size | Notes |
| --- | ---: | --- |
| `toolchain/zig-linux_x86_64.tar.xz` | 54.37 MiB | Zig `0.17.0-dev.947+36069a2a7` |
| `toolchain/wheels/wasmtime-44.0.0-py3-none-manylinux1_x86_64.whl` | 8.58 MiB | zigpeek offline dependency |
| `toolchain/wheels/lxml-6.1.1-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.whl` | 4.86 MiB | zigpeek offline dependency |
| `toolchain/wheels/zigpeek_offline-0.4.1-py3-none-any.whl` | 3.12 MiB | offline extra bundle |
| `cache/p/spider-0.6.7-P7cGrnWyrgCw3ZhalGsUHrgYsgl4BoMmaIMRotmizBA7.tar.gz` | 2.86 MiB | Zig package cache |
| `cache/p/zqlite-1.6.9-0Cdu4tFEIwA9b_rz7NlrSk2qnZodCp88gN_ZsEbUEblA.tar.gz` | 418 KiB | Zig package cache |
| `toolchain/wheels/certifi-2026.6.17-py3-none-any.whl` | 130 KiB | Python dependency |
| `toolchain/wheels/anyio-4.14.1-py3-none-any.whl` | 122 KiB | Python dependency |
| `toolchain/wheels/beautifulsoup4-4.14.3-py3-none-any.whl` | 105 KiB | Python dependency |
| `toolchain/wheels/zigpeek-0.4.1-py3-none-any.whl` | 83 KiB | Python package |
| `toolchain/wheels/httpcore-1.0.9-py3-none-any.whl` | 77 KiB | Python dependency |
| `toolchain/wheels/httpx-0.28.1-py3-none-any.whl` | 72 KiB | Python dependency |
| `toolchain/wheels/idna-3.18-py3-none-any.whl` | 64 KiB | Python dependency |
| `toolchain/wheels/typing_extensions-4.15.0-py3-none-any.whl` | 44 KiB | Python dependency |
| `toolchain/wheels/h11-0.16.0-py3-none-any.whl` | 37 KiB | Python dependency |
| `toolchain/wheels/soupsieve-2.8.4-py3-none-any.whl` | 36 KiB | Python dependency |
| `cache/p/pacman-0.1.0-SPnstbOVAAD--xa2EH3HBKetiiD2i-TRZlgeXldb9M74.tar.gz` | 8 KiB | Zig package cache |
| `README.md`, `setup.sh`, `.gitignore`, `.gitattributes` | ~6 KiB | Text and scripts |

Exact binary checksums:

```text
5ee10a5d9d7e3ac6f9edbb25e51b00c0912a9faa4c55b2455b2a24ac8635e6cf  toolchain/zig-linux_x86_64.tar.xz
dbe637e766ac0a27ebf8b6f2326ee8ea5d732bf9e3b94fe90bda9502afd3518b  toolchain/wheels/zigpeek_offline-0.4.1-py3-none-any.whl
8559cced47d2bcb119c07a21052e3156e5c89aa3dcb5c6a909add30e3cd83165  cache/p/spider-0.6.7-P7cGrnWyrgCw3ZhalGsUHrgYsgl4BoMmaIMRotmizBA7.tar.gz
924dcbe0d99da77b01f0bd22d1b751233f9f1bc18442c42e1e424c602bf9eefb  cache/p/zqlite-1.6.9-0Cdu4tFEIwA9b_rz7NlrSk2qnZodCp88gN_ZsEbUEblA.tar.gz
f0195687cbe4fae5589f090cb11c27b0891c890cbdd195a01bb818507d1f8c93  cache/p/pacman-0.1.0-SPnstbOVAAD--xa2EH3HBKetiiD2i-TRZlgeXldb9M74.tar.gz
```

### What was worth keeping

Only the ideas and text, not the assets:

- **Offline constraints:** no Git LFS (the sandbox proxy blocks LFS smudge
  URLs), `python3` required for the offline wheel install, Zig 0.17 caches
  packages under `cache/p/<name>-<version>-<hash>.tar.gz`, and native libraries
  such as sqlite3 must exist in the sandbox.
- **Offline install pattern:** verify the archive hash, extract Zig on first
  run, then install zigpeek with `pip --no-index --find-links` into a local
  virtualenv.
- **Ignore patterns:** `.toolchain/` for extracted tools and `.fetch-tmp/` for
  downloads.
- **Binary markers:** `.gitattributes` entries for vendored archives and wheels
  if binaries ever have to be committed again.

The most reusable command shape was:

```sh
tar -xf "$ZIG_TARBALL" -C "$HERE/toolchain"
python3 -m venv "$ZIGPEEK_VENV"
"$ZIGPEEK_VENV/bin/pip" install --no-index --find-links "$ZIGPEEK_WHEELS" \
  "zigpeek[offline]==0.4.1"
export PATH="$HERE/toolchain/zig:$ZIGPEEK_VENV/bin:$PATH"
export ZIG_GLOBAL_CACHE_DIR="$HERE/cache"
```

None of this should be restored as a giant branch. If an offline toolchain is
still a requirement, build it as a reproducible artifact outside Git and attach
it to a release or cache it in CI.

### Cleanup result

- Deleted the remote branch and pruned the local remote-tracking ref.
- Expired reflogs and garbage-collected the local object database.
- Fresh clone result: **276 KiB** total, **98 KiB** pack.
- Small text salvage was kept locally as
  `/work/tan-toolchains-sandbox-salvage/` and
  `/work/tan-toolchains-sandbox-salvage.tar.gz`.

## `container-bootstrap-v1` — Pi in an Apple container

### What it is

`pi-container/` runs Pi on OpenRouter inside an Apple `container` VM. Pi has no
direct internet route. A separate `pi-proxy` container is the only egress path
and only permits GitHub hosts and `openrouter.ai`/subdomains. Pi shares only the
host-only `pi-locked` network with the proxy.

### Key files

| File | Responsibility |
| --- | --- |
| `pi-container/Dockerfile` | Pi image: Node/Pi, git/gh/rg/fd, Zig 0.17.0, zigpeek, warm Zig cache |
| `pi-container/Dockerfile.proxy` | Small Python image for the allowlist proxy |
| `pi-container/run.sh` | Network/proxy lifecycle, secret filtering, mount guards, clone mode, `check` |
| `pi-container/proxy.py` | CONNECT allowlist, OpenRouter TLS MITM/key injection, health endpoint |
| `pi-container/clear.sh` | Session backup plus teardown of agent/proxy/network/images/builder |
| `pi-container/README.md` | User setup, keys, usage, limits |
| `pi-container/UPGRADES.md` | Open security/feature/quality work |

### Current design decisions

- **Stable Zig:** the Dockerfile downloads Zig **0.17.0** from `ziglang.org`,
  verifies the **minisign** signature, and installs it under `/opt`. This is the
  right replacement for the old vendored dev tarball.
- **Warm Zig cache:** the image runs `zig init --minimal` and `zig build` once so
  the first real Zig command in a fresh container is not paying compiler_rt
  startup cost.
- **Secret separation:** the real OpenRouter key lives only in a filtered
  `private/proxy.env` mounted into the proxy; Pi gets a placeholder. The GitHub
  token and commit identity are passed only to Pi through `pi.env`.
- **Proxy lock:** `pi-locked` is created as an internal network with subnet
  `172.30.240.0/24`; the proxy binds only its non-default interface and
  publishes its address after binding. `run.sh check` verifies the key, GitHub
  access, blocked sites, and direct internet access.
- **Mount guards:** `run.sh` refuses to mount `/`, ancestors of `$HOME`, config
  or env directories, and obvious secrets directories. `--clone` keeps the
  repository in a volume until it is pushed.
- **Teardown safety:** `clear.sh` backs up sessions before deleting the agent
  volume, and requires confirmation or `--yes`.
- **Zig setup wrapper removed:** commit `74ef377` deleted the earlier
  `build.zig`/`setup.zig` wrapper; the Dockerfile now owns installation
  directly. That is simpler and keeps one source of truth.

### Open work already identified

- Authenticate proxy clients if anything besides Pi can reach `pi-locked`.
- Run Pi as non-root with fewer capabilities.
- Add `--scratch` workspace modes.
- Harden `--clone` and add `clear.sh restore`.
- Extend `run.sh check`; add shell and Python tests, then CI.
- Restrict OpenRouter paths and add proxy rate limits.
- Pin base images and tool versions more aggressively; add image smoke tests.
- Replace the Python/PyInstaller zigpeek 0.5.1 build with the pure-Zig zigpeek
  release once that release is adopted.

## `zigpeek` — pure-Zig stdlib lookup

### What it is

`zigpeek/` is a pure-Zig CLI that reads the `lib/` and `doc/langref.html` of the
Zig installation already on the machine. No network, no bundled docs, no cache,
no Python, no WASM. Version **0.6.0**, minimum Zig **0.17.0**.

### Commands

```sh
zigpeek info                     # resolved binaries, Zig version, stdlib path
zigpeek search QUERY [--limit N] # declaration names / dotted FQNs
zigpeek get FQN [--source-file]  # docs, signature, members, source
zigpeek builtins list            # every @-builtin
zigpeek builtins get QUERY       # by name, falling back to doc text
zigpeek batch [-f FILE]          # many lookups, one parsed stdlib index
```

Exit codes: `0` success, `1` bad input/not found, `2` no usable local Zig.

### Current design decisions

- Parses the stdlib with `std.zig.Ast` from `std.zig`, following
  `pub const X = @import(...)`.
- Builds a flat FQN index in roughly 100 ms for 563 files/16 MB in
  `ReleaseSmall`; no index cache to invalidate.
- FQNs follow the module graph, not the filesystem layout.
- `batch` parses once and reuses the index for many commands.
- Docs always come from the same Zig version as the binary, so parser and
  sources cannot disagree.
- CI runs `zig build test`, a `--release=small` build, and CLI smoke tests on
  Linux, macOS, and Windows with Zig 0.17.0.
- A release workflow for six targets exists but is intentionally **inert until
  a `v*` tag is pushed**.

### Open work already identified

- Decide whether to adopt the release workflow as written: asset naming
  `zigpeek-vX.Y.Z-<triple>.tar.gz|.zip`, no PyPI.
- Decide whether the old Python zigpeek repository should be archived or left
  alone.
- Decide whether `MILESTONES.md` survives 1.0.
- Keep `src/version.zig` and `build.zig.zon` in sync before tagging.
- Comptime-evaluated members such as `std.ArrayList(u8).…` remain out of scope
  because they need a compiler instance, not an AST.
- After release, update the container image and agent skill to use the pure-Zig
  binary instead of the Python wheel.

## Cross-cutting direction

### 1. Make branch and repository structure deliberate

- Treat `main` as the umbrella index. Use the root README from the `zigpeek`
  branch as the starting point, then add a `pi-container` row and short usage.
- Prefer merging completed tool branches into `main` rather than keeping
  long-lived feature branches. If a branch is kept for a release, name it for
  that release, not for an experiment.
- Delete abandoned branches after extracting text/checksums. Do not leave a
  huge asset branch around just to preserve history.
- Keep one directory per tool, as the existing root README says.

### 2. Adopt a no-binaries-in-Git toolchain policy

- Never commit compiler tarballs, wheel bundles, or package caches to ordinary
  branches.
- Fetch Zig from `ziglang.org` and verify with **minisign** (stronger and simpler
  than a bare SHA-256 check).
- Pin versions in scripts and docs; keep checksums for auditability.
- If offline operation is still needed, publish a versioned artifact to a
  GitHub Release or CI cache. Document how to reproduce it from public sources.
- Keep `.gitignore` entries for extracted tools and temporary downloads, and
  only use `.gitattributes` binary markers when a binary is unavoidable.

### 3. Converge on one zigpeek implementation

- Finish and publish pure-Zig zigpeek 0.6.0 through the proposed release
  workflow.
- Replace the container's Python 0.5.1 + PyInstaller + wasmtime path with the
  released Zig binary.
- Keep the container's skill text aligned with the current CLI and Zig version.
- Avoid maintaining two zigpeek implementations with different command
  behavior and versions.

### 4. Finish the container hardening work

- Work through `pi-container/UPGRADES.md` in this order: proxy authentication,
  non-root Pi, proxy path/rate limits, clone/restore robustness, then tests and
  CI.
- Add an image smoke test that verifies `zig version` is exactly 0.17.0,
  `zigpeek info` works, and `run.sh check` passes in a disposable environment.
- Pin base image digests in addition to tool versions.
- Treat `clear.sh` backups as user data: test restore before calling the
  teardown path done.

### 5. Decide whether offline sandboxing still matters

The retired branch solved a real problem: building tracers in a networkless
linux-x86_64 sandbox. Stable Zig 0.17.0 changes the inputs, but not the
constraints. If that workflow is still required:

1. Define the target platform and exact Zig/package pins in a small doc.
2. Produce the toolchain bundle in CI from official sources.
3. Publish it as a release asset with checksums/signatures.
4. Add a small fetch-and-extract script that refuses unverified archives.
5. Test with a real tracers build in a network-disabled job.

If that workflow is no longer required, keep only the constraints and the
reproduction notes; do not resurrect the vendored branch.

### 6. Documentation and release hygiene

- Replace the one-line root README with a short index: what each tool is, how to
  build it, and which Zig version it targets.
- Keep `UPGRADES.md` as open work only; let Git history hold completed items.
- Add a short “toolchain policy” section to the root README so future branches
  do not vendor binaries again.
- Tag zigpeek before changing its CLI surface, and keep release assets immutable.

## Decisions needed

1. **Branch topology:** merge `zigpeek` and `container-bootstrap-v1` into `main`
   after the root README is ready, or keep per-tool release branches?
2. **zigpeek release:** adopt the existing six-target GitHub Release workflow,
   or continue build-from-source only?
3. **Old Python zigpeek:** archive it, leave it, or redirect it to the pure-Zig
   implementation?
4. **Offline sandbox:** is networkless tracers CI still required? If yes, what
   artifact should carry the toolchain and package cache?
5. **Container scope:** is the supported platform still macOS 26 on Apple
   silicon only, or should the proxy/run scripts grow a broader test matrix?

## Suggested next milestone

A small “toolchains 1.0” integration branch that:

- Adds the umbrella README and toolchain policy.
- Merges the pure-Zig `zigpeek` tree.
- Merges `pi-container` with the Python zigpeek path replaced by a pinned
  pure-Zig release once available.
- Adds CI for zigpeek plus at least shell-level tests for `run.sh`, `clear.sh`,
  and the proxy.
- Leaves offline toolchain packaging to a release artifact, not Git.

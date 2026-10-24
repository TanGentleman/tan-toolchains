# Zig milestones

Pure-Zig rewrite of zigpeek, targeting **Zig 0.17.0**. No network code, no
bundled docs, no WASM: every command reads the `lib/` of a Zig installation
that is already on the machine.

Design rules that hold for every milestone:

- `zig build` produces one static binary; `zig build test` is the whole test
  suite. No Python, no uv, no wasmtime, no XDG docs cache.
- 0.17 build flags: `zig build --release=small` for a shippable binary,
  `zig build run` to run the tool (M1: runs `info`; 0.17 no longer forwards
  `zig build run -- <args>`).
- Docs always come from the local compiler, so the parser and the sources can
  never be different Zig versions.
- Markdown goes to stdout, diagnostics to stderr, exit codes 0/1/2.
- Keep `zigpeek info` first-person useful: agents run it before anything else.

```sh
cd zig
zig build test          # unit tests
zig build run           # `zigpeek info`
zig build --release=small   # 274 KB binary in zig-out/bin/
```

## M1 — skeleton + `zigpeek info` ✅

- [x] `build.zig` / `build.zig.zon`, `zig build run`, `zig build test`
- [x] `zigpeek --help`, `zigpeek --version`, `zigpeek info [--zig PATH] [--lib-dir PATH]`
- [x] compiler discovery: `--zig` → `$ZIGPEEK_ZIG` → `$ZIG` → PATH
- [x] run `zig env`, parse its ZON with `std.zon.parse`
- [x] report zigpeek version/binary, zig binary/version/lib/std, docs source,
      and the local `doc/langref.html` that `builtins` will read later
- [x] unit tests for ZON parsing and every render branch (16 tests)

Measured on the dev box (0.17.0, aarch64-linux): ReleaseSmall binary is
274 KB and `zigpeek info` runs in ~2 ms.

Known gap: the usage guide already advertises `search`/`get`/`builtins`/`batch`,
which arrive in M2–M6. `info` stays exit 0 even with no compiler, because it is
the diagnostic command.

## M2 — walk the stdlib + `zigpeek search` ✅

- [x] `lib/` → `std/` normalization (accept either; `--lib-dir` beats discovery)
- [x] walk the module graph from `std.zig` via `pub const X = @import(...)`,
      `std.zig.Ast.parse` each file; private imports are not modules
- [x] flat decl index: FQN, short name, kind, file, AST node
- [x] `zigpeek search QUERY [--limit N]`: exact > prefix > substring, shorter
      names first, case-insensitive for all-lowercase queries, dotted queries
      match whole FQNs
- [x] measured: 104 ms ReleaseSmall for a full stdlib search (563 files,
      16 MB parsed); no index cache needed
- [x] `search` exits 2 with a clear message when no compiler/lib is found
- [x] unparseable files are skipped with a warning instead of failing the run

Deliberate deviation: FQNs come from the module graph, not the filesystem, so
`std.Io.Dir.openFile` works but a path-derived name like
`std.multi_array_list.X` does not exist unless something imports that file as
a named module. (0.17 removed `std.multi_array_list` entirely.)

## M3 — `zigpeek get FQN` ✅

- [x] alias chains: `other`, `other.member`, `@import("x.zig").Member`,
      with a hop limit so `A = B; B = A` cannot loop
- [x] markdown: heading, `Alias of ...`, doc comments (including fenced
      examples), signature, source snippet
- [x] `get --source-file FQN` → whole defining file (alias-aware)
- [x] `std.` prefix is optional (`get Io.File.close`)
- [x] unknown decl → `# Error` + "Did you mean" suggestions on stderr, exit 1

## M4 — namespaces, containers, and error sets ✅

- [x] namespace/container listings grouped as Types / Namespaces / Error Sets /
      Functions / Global Variables / Values
- [x] struct fields (`- \`name: Type\``) for containers *and* for file-root
      structs (`std.mem.Allocator` is `@This()` at the top of its file)
- [x] module `//!` docs for namespaces
- [x] error sets list their members; private decls/fields never appear
- [x] golden-ish tests over `tests/fixtures/mini-std`
- [ ] comptime-evaluated members (`std.ArrayList(u8).…`) — out of scope: that
      needs a compiler instance, not an AST. `get std.ArrayList` shows the
      constructor instead.

## M5 — `zigpeek builtins`

- [ ] extract `#Builtin-Functions` from the compiler's own `doc/langref.html`
      (no download; `info` already reports whether it is present)
- [ ] `builtins list`, `builtins get QUERY` (name **and** doc text ranking)
- [ ] clear error when the installation ships no langref

## M6 — polish, parity, remove Python

- [ ] `zigpeek batch` reading one command per line (kept for agent ergonomics,
      even though there is no interpreter startup to amortize)
- [ ] `-h/--help` for every subcommand; `--zig`/`--lib-dir` everywhere
- [ ] replace `src/zigpeek/`, `pyproject.toml`, `uv.lock`, `packages/`,
      `vendor/`, `skills/zigpeek/SKILL.md` install instructions
- [ ] CI: `zig build test` matrix (linux/macos/windows), cross-compiled release
      binaries attached to GitHub Releases; delete the PyPI release workflow
- [ ] README/ARCHITECTURE rewrite; keep `skills/zig-0.15-to-0.16/` as content

Non-goals: offline docs bundles, fetching docs for another Zig version, any
HTTP client, any cache directory.

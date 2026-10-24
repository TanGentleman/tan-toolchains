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

## M2 — walk the stdlib + `zigpeek search`

- [ ] `lib/` → `std/` normalization (accept either; `--lib-dir` beats discovery)
- [ ] walk every `std/**/*.zig`, `std.zig.Ast.parse` each file
- [ ] build a decl index: FQN, kind, doc comment, file/offset
- [ ] follow `pub const X = @import("y.zig")` root re-exports far enough to
      name the defining module (the "inner types" rule in the guide)
- [ ] `zigpeek search QUERY [--limit N]`, ranked like today's output
      (exact > prefix > substring; case-insensitive for all-lowercase queries)
- [ ] measure cold run; target < 250 ms. (Prototype: parsing 563 files /
      16 MB of 0.17 stdlib took 82 ms in ReleaseFast, so no index cache is
      planned unless this regresses.)
- [ ] `search` exits 2 with a clear message when no compiler/lib is found

## M3 — `zigpeek get FQN`

- [ ] resolve an FQN through namespaces and alias chains (`get_aliasee` today)
- [ ] render markdown: heading, docs, signature, parameters, errors, doctest,
      source snippet
- [ ] `get --source-file FQN` → whole defining file
- [ ] unknown decl → `# Error` on stderr, exit 1

## M4 — namespaces, types, and error sets

- [ ] namespace/container listings grouped as Types / Namespaces / Error Sets /
      Functions / Fields / Global Variables / Values
- [ ] struct fields, `type_fn` members, error-set node lists
- [ ] alias/cycle handling in one shared helper (today it is repeated three
      times with subtly different behavior)
- [ ] golden-output tests over a fixture stdlib

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

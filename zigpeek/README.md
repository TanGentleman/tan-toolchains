# zigpeek

Zig stdlib docs in a few milliseconds, straight out of the Zig compiler you
already have. No network, no bundled docs, no WASM.

```sh
cd zigpeek
zig build --release=small       # zig-out/bin/zigpeek
sudo install -m755 zig-out/bin/zigpeek /usr/local/bin/
```

```sh
zigpeek search ArrayList
zigpeek get std.Io.Dir.openFile
zigpeek get std.Io.File.close
zigpeek builtins get atomicLoad
```

Everything is read from the `lib/` and `doc/langref.html` of the active Zig
installation (the same version as `zig version`). Point it elsewhere with
`--zig PATH`, `--lib-dir PATH`, `$ZIGPEEK_ZIG`, `$ZIG`, or
`$ZIGPEEK_LIB_DIR`.

## Commands

```
zigpeek info                     # what this is, resolved binaries, docs source
zigpeek search QUERY [--limit N] # declaration names; dotted queries match FQNs
zigpeek get FQN [--source-file]  # docs, signature, members, source
zigpeek builtins list            # every @-builtin, with signatures
zigpeek builtins get QUERY       # by name, falling back to doc text
zigpeek batch [-f FILE]          # many lookups in one process (index parsed once)
```

Exit codes: `0` success, `1` bad input / not found, `2` the local Zig
installation could not be used.

## How it works

`zigpeek` parses the stdlib with `std.zig.Ast`, starting at `std.zig` and
following `pub const X = @import(...)`. That produces an index of
fully-qualified declarations which `search` ranks and `get` re-parses on
demand. A full stdlib index is built in ~100 ms (563 files, 16 MB) in
`ReleaseSmall`, so there is no index cache to invalidate.

Because the binary is compiled with the same Zig version whose `lib/` it
reads, the parser and the sources can never disagree. There is also nothing
to download, so it works offline by construction.

## Development

```sh
zig build test                  # unit tests, fixture stdlib in tests/fixtures
zig build run                   # runs `zigpeek info`
zig build --release=small       # shippable binary
```

See [MILESTONES.md](MILESTONES.md) for what is implemented and what is
deliberately out of scope.

MIT.

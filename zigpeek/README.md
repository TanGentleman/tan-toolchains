# zigpeek

Zig stdlib and `@`-builtin docs read from the installed compiler. No network
access, no bundled docs.

```sh
cd zigpeek
zig build --release=small       # zig-out/bin/zigpeek
sudo install -m755 zig-out/bin/zigpeek /usr/local/bin/
```

```sh
zigpeek search ArrayList
zigpeek get std.Io.Dir.openFile
zigpeek builtins get atomicLoad
```

Both the `lib/` and `doc/langref.html` come from the active Zig installation
(the same version as `zig version`). Point it elsewhere with `--zig PATH`,
`--lib-dir PATH`, `$ZIGPEEK_ZIG`, `$ZIG`, or `$ZIGPEEK_LIB_DIR`.

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
demand. A full stdlib index builds in ~100 ms in `ReleaseSmall`, so there is no
index cache to invalidate.

The binary is compiled with the same Zig version whose `lib/` it reads, so the
parser and the sources cannot disagree. Nothing is downloaded.

## Development

```sh
zig build test                  # unit tests, fixture stdlib in tests/fixtures
zig build run                   # runs `zigpeek info`
zig build --release=small       # shippable binary
```

MIT.

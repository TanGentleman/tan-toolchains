---
name: zigpeek
description: Look up Zig stdlib and @-builtin docs with the local zigpeek CLI. Run `zigpeek info` first. Use before writing or reviewing Zig that touches stdlib APIs — especially std.Io, Reader/Writer, and std.process.Init.
---

# zigpeek

```sh
zigpeek info
```

That prints when/how to use this CLI, the resolved binaries, and which Zig
version + stdlib directory the docs come from.

If it is missing, build it from the tan-toolchains checkout:

```sh
cd zigpeek && zig build --release=small
install -m755 zig-out/bin/zigpeek ~/.local/bin/
```

No Zig installation? zigpeek has nothing to read — install Zig first. It
never downloads docs.

## Look things up instead of guessing

```sh
zigpeek search writer          # don't know the name
zigpeek get std.Io.Writer      # know the name
zigpeek get std.Io.File.close
zigpeek get std.Io.Dir.openFile --source-file   # whole defining file
zigpeek builtins get atomic    # @-builtins, by name or doc words
```

- `std.` may be omitted: `zigpeek get Io.File.close` works.
- Queries without uppercase letters are case-insensitive.
- A dotted query matches whole FQNs: `zigpeek search Io.Dir.open`.
- FQNs follow the module graph, not the file layout: `std.Io.Dir.openFile`.

## More than two lookups? Use batch

Each `zigpeek` invocation parses the whole stdlib (~100 ms). `batch` parses it
once and runs one command per line:

```sh
zigpeek batch <<'EOF'
search writer
get std.Io.Writer.print
get std.Io.Reader.allocRemaining
builtins get atomic
EOF
```

Each result is framed with `===> <command>`. Blank lines and `#` comments are
skipped. The exit code is the worst seen; a single not-found does not abort
the rest.

## Reading the output

- Docs are plain markdown from the `///` comments, including fenced examples.
- `get` on a namespace or struct lists Types / Namespaces / Error Sets /
  Functions / Global Variables / Values, plus struct fields.
- Aliases say what they point at and then show the target.
- `# Error` on stderr + exit 1 means the FQN does not exist; use `search`.

## Checking a migrated call site

```sh
zigpeek get std.Io.Dir.createDir
zigpeek get std.process.currentPathAlloc
zigpeek get std.Io.File.close
```

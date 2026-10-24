# tan-toolchains

Tooling that comes in handy, one directory per tool.

| Tool | What it is |
| ---- | ---------- |
| [`zigpeek/`](zigpeek/) | Zig stdlib + `@`-builtin docs from your installed compiler. Pure Zig, no network. |

## zigpeek

```sh
cd zigpeek && zig build --release=small
zigpeek search ArrayList
zigpeek get std.Io.Dir.openFile
```

See [zigpeek/README.md](zigpeek/README.md).

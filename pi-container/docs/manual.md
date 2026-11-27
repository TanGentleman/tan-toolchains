# Manual mode

`--manual` opens a shell in the image without Pi, the proxy, or OpenRouter
configuration. It uses the container's default network with no egress lock and no
`pi-proxy`, so it reaches any host and protocol, including your Mac's services
and Tailscale's resolver at `100.100.100.100`
([network boundary](../../README.md#network-boundary)). Use it only with trusted
projects. `pi` is still
installed, but manual mode configures no provider, so use normal `pic` for the
agent.

Manual mode does not mount the instance's agent volume. Use a normal-mode
command such as `pic bash` when changing state under `/root/.pi/agent`, including
`enforcer on` and `enforcer off`.

Manual mode does not require the env file. It mounts the current folder, or a
clone with `--clone O/R`; clone mode refreshes `pi.env` from the host env file
when it exists, so a removed token does not linger. `PI_CLONE=O/R` makes clone
the default. A cloned shell starts in `/work/<repo>` and shares its volume with
normal `--clone` in the same profile.

Use `--image editor` (or `tools`, `zig`) to pick the pack. Manual mode does not
require the image to contain Pi. Manual mode refuses egress `offline`; pass
`--egress standard` when `PI_EGRESS=offline` is set.

Neovim paths:

| Host | Container |
| ---- | --------- |
| `~/.pic/config/nvim` | `/root/.config/nvim` |
| `~/.pic/config/nvim-data` | `/root/.local/share/nvim` |
| `~/.pic/config/nvim-state` | `/root/.local/state/nvim` |
| `~/.pic/config/nvim-cache` | `/root/.cache/nvim` |

`run.sh` seeds `init.lua` once from [`nvim/init.lua`](../nvim/init.lua) and never
overwrites an existing `init.lua` or `init.vim`. The stock config only enables
ZLS. Edit the host copy; changes apply on the next launch. Override the paths
with `PI_NVIM_CONFIG`, `PI_NVIM_DATA`, `PI_NVIM_STATE`, and `PI_NVIM_CACHE`.
Neovim config and state are shared by all instances in a profile by default.

In both normal Pi mode and `--manual`, Zig's local cache is redirected to
`/root/.cache/zig-local/<project-hash>` for bind-mounted and cloned projects,
so builds do not crawl over a slow mount. The image's global cache is still
prewarmed; the local cache is per container.

Plugins are not baked in: manual mode has internet, but normal Pi mode is behind
the proxy, so Git clones from `github.com` work while release-asset and tool
downloads may fail. Use [egress mode](egress.md) when Pi itself needs an
unproxied download. The image does not include a compiler for Treesitter
parsers; use Neovim's built-in Zig syntax.

Normal Pi mode does not mount the Neovim paths.

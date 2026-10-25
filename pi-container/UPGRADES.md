# Upgrade notes

Open work only. History is in git. The container is a dev environment; shipped
binaries run on macOS and do not use its network.

## Security

- The proxy does not identify clients. Every Pi instance on `pi-locked` can spend
  the one OpenRouter key. Authenticate proxy clients if untrusted containers join
  that network.
- The proxy still mounts `$cfg/private` read-write. That directory holds the
  OpenRouter key, CA private key, and leaf key. Generate certificates outside
  the long-running proxy, mount only the public certificate into Pi, and mount
  runtime certificates read-only into the proxy.
- Separate keys need a later `--profile DIR` feature: its own config directory,
  network, proxy, port offset, and subnet. One proxy owns one key, so profiles
  stay one-proxy-per-key.

## Local development

- Normal `pic` mode does not mount the Neovim paths. Decide whether to promote
  them or keep the editor manual-only.
- Plugin policy is unresolved. Manual mode has unrestricted egress; normal Pi
  mode allows only GitHub and OpenRouter, so Mason and GitHub release-asset
  downloads fail. Bake tools or widen the allowlist deliberately.
- Treesitter is not included. Enabling it needs `gcc`/`make` at runtime or
  prebuilt parsers.
- Neovim config/state is shared by all instances. Make it per-instance if
  parallel editors contend.
- Zig's local cache is container-local and disappears with the container. Add a
  persistent cache volume if rebuilds matter.
- inotify does not reliably cross the macOS bind mount; ZLS may miss saves made
  on the host. Edit inside the container.
- The first `build.zig`-aware ZLS request may fetch project dependencies. The
  image cache only covers compiler_rt.
- Clipboard has no X11/Wayland. Use OSC52 from the host terminal; forward
  `COLORTERM` if truecolor is missing.
- `zig env` emits ZON in 0.17. Vim's builtin Zig ftplugin parses it as JSON;
  Neovim is unaffected. Plain Vim users must set `g:zig_std_dir`.

## Quality

- Add smoke tests for `run.sh check` and `clear.sh save`; run them manually on
  macOS. CI checks syntax and instance/volume naming only.
- Add CI checks for the Neovim/ZLS pins and for `ZLS_VERSION == ZIG_VERSION`
  after the local-development flow settles.
- Run the [E2E checklist](E2E.md) on macOS before calling a branch stable. This
  stays manual because Apple `container` is not available on GitHub Actions.
- Base images are pinned to multi-arch digests; keep tool versions pinned via
  `ARG`.

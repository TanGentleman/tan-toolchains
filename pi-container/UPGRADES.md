# Upgrade notes

Open work only. History is in git. The container is a dev environment; shipped
binaries run on macOS and do not use its network.

## Security

- The proxy does not identify clients. Every Pi instance on a profile's network
  can spend that profile's OpenRouter key. Authenticate proxy clients if
  untrusted containers join the network.
- The proxy still mounts `$cfg/private` read-write. That directory holds the
  OpenRouter key, CA private key, and leaf key. Generate certificates outside
  the long-running proxy, mount only the public certificate into Pi, and mount
  runtime certificates read-only into the proxy.
- Separate keys work by running with a different `PI_CONFIG_DIR`: the proxy,
  network, subnet, proxy image, agent volumes, and clone volumes are derived
  from it. The agent image and builder cache remain shared, so `nuke all` in
  one profile still deletes them for every profile.

## Local development

- Normal `pic` mode does not mount the Neovim paths. Decide whether to promote
  them or keep the editor manual-only.
- Plugin policy is unresolved. Manual mode has unrestricted egress; normal Pi
  mode allows only GitHub and OpenRouter, so Mason and GitHub release-asset
  downloads fail. Bake tools or widen the allowlist deliberately.
- Treesitter is not included. Enabling it needs `gcc`/`make` at runtime or
  prebuilt parsers.
- Neovim config/state is shared by all instances in a profile. Make it
  per-instance if parallel editors contend.
- Zig's local cache is container-local and disappears with the container. Add a
  persistent cache volume if rebuilds matter. Both normal and manual modes
  redirect it out of the project mount.
- inotify does not reliably cross the macOS bind mount; ZLS may miss saves made
  on the host. Edit inside the container.
- The first `build.zig`-aware ZLS request may fetch project dependencies. The
  image cache only covers compiler_rt.
- Clipboard has no X11/Wayland. Use OSC52 from the host terminal; forward
  `COLORTERM` if truecolor is missing.
- `zig env` emits ZON in 0.17. Vim's builtin Zig ftplugin parses it as JSON;
  Neovim is unaffected. Plain Vim users must set `g:zig_std_dir`.

## Quality

- CI runs `test/run-tests.sh`: naming, validation, path guards, the JSON
  parsers in `lib/inspect.sh`, and `run.sh`/`clear.sh` against a fake
  `container` CLI. This covers orchestration decisions without Apple
  `container`. Real volume/network/proxy behaviour and `run.sh check` still
  need the [E2E checklist](E2E.md) on macOS.
- Primary fixtures under `test/fixtures/container/` start synthetic. Run
  `test/record-fixtures.sh` on a Mac to capture the real shapes; alternate
  shapes stay hand-built. Exact expectations are inline, so re-recording does
  not rewrite them, and a changed shape should fail a smoke test instead of a
  run.
- Add a shellcheck step once the existing warnings are triaged; it is not
  wired up yet.
- Add CI checks for the Neovim/ZLS pins and for `ZLS_VERSION == ZIG_VERSION`
  after the local-development flow settles.
- Run the [E2E checklist](E2E.md) on macOS before calling a branch stable. This
  stays manual because Apple `container` is not available on GitHub Actions.
- Base images are pinned to multi-arch digests; keep tool versions pinned via
  `ARG`.

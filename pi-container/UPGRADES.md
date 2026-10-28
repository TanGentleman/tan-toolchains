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
  from it. The active agent image and builder cache remain shared, so `nuke all`
  in one profile still deletes the active `PI_IMAGE` for every profile. Other
  pack tags are left behind.

## Enforcer

- The image ships `enforcer` disabled. Run `enforcer on` in a normal container
  to write the Pi extension into that instance's agent volume. Decide whether
  new instances should auto-enable it or expose a `run.sh` flag.
- Claude is detection-only. An `enforcer on` with only Claude configured exits
  1 and points at `TanGentleman/enforcer`; add a settings mutator before
  claiming Claude support.
- The policy is one case-sensitive `ghp_` substring. More patterns or a rules
  file are deliberate additions, not missing wiring.

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

- CI runs `test/run-tests.sh`: naming, validation, the image pack catalog, path
  guards, the jq-based JSON parsers in `lib/inspect.sh`, and `run.sh`/`clear.sh`
  against a fake `container` CLI. This covers orchestration decisions without Apple
  `container`. Real volume/network/proxy behaviour and `run.sh check` still
  need the [E2E checklist](E2E.md) on macOS.
- `jq` is a hard dependency for `run.sh` normal/check/proxy, `clear.sh`
  list/nuke, and the test suite. Those paths fail early with an install hint
  when it is missing.
- The fixtures under `test/fixtures/container/` are either recorded from Apple
  or hand-built to pin a parser branch. Run `test/record-fixtures.sh` on a Mac
  to refresh captures; it only replaces a fixture after the output parses as
  JSON. Exact expectations are inline, so re-recording does not rewrite them,
  and a changed shape should fail a smoke test instead of a run.
- `scripts/container-discovery.sh` captures raw shapes and a jq summary without
  touching the fixtures. Use it when iterating on a new Apple CLI version.
- Image packs are built manually with `./build.sh PACK`; CI does not build
  Dockerfile targets. The `agent` and `editor` packs deliberately omit `gh`, so
  a `check` with `GITHUB_TOKEN` set fails on those images instead of silently
  skipping GitHub.
- Add a shellcheck step once the existing warnings are triaged; it is not
  wired up yet.
- Add CI checks for the Neovim/ZLS pins and for `ZLS_VERSION == ZIG_VERSION`
  after the local-development flow settles.
- Run the [E2E checklist](E2E.md) on macOS before calling a branch stable. This
  stays manual because Apple `container` is not available on GitHub Actions.
- Base images are pinned to multi-arch digests; keep tool versions pinned via
  `ARG`.

## Review follow-ups

Known, non-blocking gaps from the parser/test change. Fix one only when the
behavior or test value justifies the churn.

- `lib/paths.sh: pi_physical_path` can return the input path unresolved when the
  leaf is missing under a symlinked parent or the symlink depth cap is hit. The
  mount guard must fail closed; add tests and make unresolved paths a refusal.
  This is security-sensitive path algebra; change it with focused tests rather
  than as part of a parser cleanup.
- `run.sh` and `clear.sh` still duplicate the small `require_cli`/`require_jq`
  and volume/image existence helpers. Lock acquisition is now shared in
  `lib/lock.sh`; the remaining helpers are cheap enough to leave until they
  change.
- `lib/*.sh` are tracked executable but are sourced and have no shebang. Set
  them to mode `100644`.
- The image version `Env` source is unit-tested, but the image captured for
  this change had no `PI_CONTAINER_PI_VERSION` in `Env`, so the live path used
  the label/history/Dockerfile version instead. Rebuild the image, re-run
  `test/record-fixtures.sh`, and check that `run.sh check` seeds the expected
  `lastChangelogVersion`.
- `test/record-fixtures.sh` and `scripts/container-discovery.sh` are
  syntax-checked but not behavior-tested. They are local Mac tools; add tests
  only if they start changing often or grow more logic.
- Instances are not bound to images. `PI_IMAGE` is a per-run choice, and `run.sh
  announce_run` prints the pair but nothing records it, so `clear.sh list`
  cannot show which image last wrote a volume. If that provenance matters, add a
  marker file per agent volume rather than a `pi.image` label: labels are fixed
  at `volume create` and would go stale on the first image switch.
- `scripts/` is intentionally temporary. Fold it into `pi-container/test/` or
  remove it if discovery stops being a recurring workflow.

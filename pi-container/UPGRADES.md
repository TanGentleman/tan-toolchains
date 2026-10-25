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

## Quality

- Add smoke tests for `run.sh check` and `clear.sh save`; run them manually on
  macOS. CI checks syntax and instance/volume naming only.
- Run the [E2E checklist](E2E.md) on macOS before calling a branch stable. This
  stays manual because Apple `container` is not available on GitHub Actions.
- Base images are pinned to multi-arch digests; keep tool versions pinned via
  `ARG`. Add a CI check for digest drift if it becomes a problem.

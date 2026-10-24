# Upgrade notes

Open work only. History is in git. The container is a dev environment; shipped
binaries run on macOS and do not use its network.

## Security

- Authenticate proxy clients only if you add more containers to the host-only
  `pi-locked` network. With just Pi and `pi-proxy`, only Pi can reach the proxy.

## Quality

- Add smoke tests for `run.sh check` and `clear.sh save`; run them manually on
  macOS. CI checks syntax only.
- Run the [E2E checklist](E2E.md) on macOS before calling a branch stable. This
  stays manual because Apple `container` is not available on GitHub Actions.
- Pin base-image digests and keep tool versions pinned via `ARG`.

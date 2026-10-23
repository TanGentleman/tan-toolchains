# Upgrade notes

Open work, highest value first. History is in git.

## Security

- Authenticate proxy clients. Only useful if more than Pi can reach `pi-locked`.
- Run Pi as non-root. Try `--cap-drop ALL`, `no-new-privileges`, and a read-only root filesystem.

## Features

- Add `--scratch`, `--reset`, and `--empty` workspace modes.
- Harden `--clone`: interrupted clones, volume-name collisions, and a push reminder on exit.

## Checks

- Extend `run.sh check`: internal network, IPv6, proxy bind and networks, no key in `container inspect`, Node TLS, and `pi-agent-home/auth.json`.
- Add shell tests: argument parsing, path guards, env filtering, `valid_ip`, `proxy_state`.
- Add Python tests: allowlists, key loading, header and body parsing.
- Add CI: shellcheck, shfmt, ruff, secret scan.

## Proxy

- Restrict OpenRouter paths.
- Add a connection cap or rate limit.
- Add timeouts and keep the TLS contexts cached.

## Packaging

- Pin base images, `gh`, and `pyinstaller`.
- Add smoke tests: `pi --version`, `gh --version`, `zig version`, `zigpeek info`, `rg --version`.
- Add `less`, `procps`, and `git-lfs` if needed.

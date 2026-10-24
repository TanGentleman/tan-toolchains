# Upgrade notes

Open work only. History is in git.

## Security

- Authenticate proxy clients if more than Pi can reach `pi-locked`.
- Run Pi as non-root with fewer capabilities.

## Features

- Add `--scratch` workspace modes.
- Harden `--clone` and add `clear.sh restore` for backups.

## Quality

- Extend `run.sh check`; add behavioural tests for `run.sh` and `clear.sh`
  (CI checks their syntax only).
- Restrict OpenRouter paths and add proxy rate limits.
- Pin base images and tool versions; add image smoke tests.
- Build the image in CI on an Apple-silicon macOS 26 runner: `container build`
  plus `zigpeek info` and `run.sh check` against a throwaway proxy.

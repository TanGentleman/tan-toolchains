# Manual end-to-end test

Run this on macOS before calling a branch stable. It is deliberately manual:
Apple `container` is not available on GitHub Actions. Treat a failure as a
blocker; fix it on the branch, not on `main`.

Record the branch, image ID, and date at the top of your test notes.

## 1. Build and keys

- [ ] `cd pi-container && container build -t pi-agent:local -f Dockerfile ..`
- [ ] `~/.config/pi-container/env` exists and is mode 600 or 400.
- [ ] `private/proxy.env` and `pi.env` are filtered: no OpenRouter key in
      `pi.env`; no GitHub token in `proxy.env`.
- [ ] No secret appears in the build or proxy logs.

## 2. First check

- [ ] `./run.sh check you/your-repo` builds `pi-proxy` and reports no failure.
- [ ] The check reports the Zig toolchain and zigpeek's docs source.
- [ ] Direct internet is blocked; GitHub and OpenRouter are reachable.
- [ ] `example.com` is refused.

## 3. Pi

- [ ] `./run.sh` starts Pi; `/model` works; `/quit` exits.
- [ ] `/login` is not needed; the OpenRouter placeholder is in place.
- [ ] Pi can read and write a file in the mounted repo.

## 4. Mounts and clone

- [ ] Default mount edits land on the Mac.
- [ ] `run.sh` refuses `~`, `/`, ancestors of `~`, secrets directories, and
      anything overlapping the config directory.
- [ ] `./run.sh --clone you/your-repo` creates a clone volume.
- [ ] Uncommitted changes stay in the volume until pushed.
- [ ] `git push` works through `gh` without `git config` or `gh auth login`.

## 5. Proxy lifecycle

- [ ] `./run.sh proxy` follows the proxy log.
- [ ] `./run.sh proxy-stop` stops the proxy.
- [ ] A normal `./run.sh` starts it again.
- [ ] The proxy survives a Pi restart without leaking keys.

## 6. zigpeek offline

Run inside the Pi container:

- [ ] `zigpeek info` shows the local Zig version and `doc/langref.html`.
- [ ] `zigpeek search ArrayList`
- [ ] `zigpeek get std.Io.File.close`
- [ ] `zigpeek builtins get atomicLoad`
- [ ] `zigpeek batch` with two lookups.
- [ ] Run one of the above with `HTTP_PROXY=http://127.0.0.1:9` and the same
      `HTTPS_PROXY`; it still works (no network).

## 7. Zig build

- [ ] `zig init --minimal` in a scratch dir.
- [ ] `zig build` succeeds and reuses the warm cache.
- [ ] Build one sample binary; it runs in the container.

## 8. Cleanup

- [ ] `./clear.sh save` writes a session backup.
- [ ] `./clear.sh nuke agent` deletes the agent volume after saving.
- [ ] `./clear.sh nuke all` deletes proxy, network, images, and builder cache.
- [ ] `./clear.sh nuke all --clones` also deletes `pi-clone-*` volumes.
- [ ] Host config and project files survive every cleanup.

## 9. Config and edge cases

- [ ] `settings.json` is created and mounted; a one-off
      `pic pi --model openrouter/<model>:high` works.
- [ ] Missing `container` CLI fails with a clear message.
- [ ] Missing env file fails with a clear message.
- [ ] Invalid repo name fails with a clear message.
- [ ] Proxy already running is handled without a port conflict.
- [ ] Network already exists is handled without a subnet conflict.
- [ ] Volume already exists is handled without data loss.
- [ ] `--build-arg PI_VERSION=…` and `--build-arg ZIG_VERSION=…` change the image.

## 10. Sign-off

- [ ] All checks pass.
- [ ] Note anything you skipped and why.
- [ ] Merge to `main` and tag only after this checklist is complete.

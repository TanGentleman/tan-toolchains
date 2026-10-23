# Upgrade notes

Status: **not implemented**. This file records the audit findings, review notes,
and the changes worth making next. The code in this branch is the bootstrap
snapshot that was tested first.

Baseline verification (run from inside the Pi container):

- Direct TCP to `1.1.1.1:80`, `8.8.8.8:53`, and `140.82.121.4:443` timed out.
- External DNS did not resolve.
- The proxy returned `403` for `example.com` and for arbitrary `CONNECT` tunnels.
- `https://github.com` and `https://openrouter.ai/api/v1/key` returned `200`.
- Pi held `sk-or-v1-placeholder`, not the real OpenRouter key.
- `uid=0` inside the Pi VM, but no host root: no `docker`/`container` socket, no
  host filesystem outside the project mount, and the gateway ports tested were closed.

---

## Ground rules

- **Trusted repos only.** The default `run.sh` mounts the current folder
  read-write. That is a convenience, not a security boundary, and it is intended
  for repos you already trust. Use `--clone` for anything else. The current
  folder mode does not have to remain the default if making it opt-in simplifies
  the script.
- **`run.sh` is the minimum runnable path.** After `container build` and a
  mode-600 env file, `./run.sh check` and `./run.sh` are enough. `setup.zig`,
  `build.zig`, tests, and CI are optional. Keep a branch that requires none of
  them. Either keep `setup.zig` as an optional convenience or make it a thin
  wrapper over `run.sh`; do not make Zig a prerequisite for `run.sh`.
- **The proxy is the only egress enforcement point.** `pi-proxy` itself has
  ordinary internet access. `proxy.py` decides what gets through, so a proxy bug
  is a full egress bypass. Review and test it accordingly.

---

## Priority 1

### 1. Fail closed on an existing `pi-locked` network

`run.sh` accepts any network named `pi-locked`:

```bash
printf '%s\n' "$names" | grep -qx pi-locked && return
```

If that network exists but is **not** `--internal`, Pi gets a route to the
internet and the isolation model collapses. Verify the `internal` flag and abort
(or recreate) when it is missing. Also report a useful error when the hard-coded
`172.30.240.0/24` subnet collides with an existing network.

Sketch:

```bash
if printf '%s\n' "$names" | grep -qx pi-locked; then
  "$cli" network inspect pi-locked \
    | grep -q '"internal"[[:space:]]*:[[:space:]]*true' \
    || { echo "run.sh: pi-locked exists but is not internal; delete it first" >&2; exit 1; }
  return
fi
```

Confirm the exact JSON shape of `container network inspect` on the target macOS
release before relying on that grep. If the existing network uses a different
subnet, either accept it and use the published proxy address, or recreate it.
Do not assume `172.30.240.0/24` when inspecting.

### 2. Filter the environment passed into Pi

`run.sh` currently passes the entire `env` file into Pi:

```bash
--env-file "$env_file"
```

and then relies on `-e OPENROUTER_API_KEY=...` overriding it. Docker gives
`--env` precedence over `--env-file`, but do not stake a security boundary on
Apple `container` matching that behavior. A regression would put the real
OpenRouter key into Pi.

Build a separate file containing only:

- `GITHUB_TOKEN`
- optional `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`,
  `GIT_COMMITTER_EMAIL`

Pass that file to Pi with `--env-file`, and keep the placeholder override. Strip
trailing `\r` from values and reject `sk-or-v1-placeholder` as the real key.

### 3. Keep config and env paths out of the project mount

The default mode mounts `$PWD` unless it is exactly `$HOME` or `/`:

```bash
args+=(-v "$PWD:$PWD" -w "$PWD")
```

The config directory contains `private/ca.key`, `private/openrouter.key`,
`proxy.env` (the real OpenRouter key), and possibly `env` (both keys). Running
from `~/.config`, or setting `PI_CONFIG_DIR=$PWD/pi-cfg`, mounts those secrets
into Pi. Pi runs as root, so `700`/`600` modes do not help.

Resolve `$PWD`, `$cfg`, and `$env_file` physically and refuse when:

- `$cfg`, `$env_file`, or `$cfg/private` is inside `$PWD`;
- `$PWD` is `/`, `$HOME`, an ancestor of `$HOME`, or an ancestor of `$cfg`;
- `$PWD` is a known secrets directory such as `~/.ssh`, `~/.aws`, `~/.gnupg`,
  or `~/Library/Keychains`.

This applies only when the project mount is used; `--clone` and `check` do not
mount the project. Report the reason clearly instead of only “refusing to mount”.

### 4. Wire `PI_PROXY_PORT` end to end

`run.sh` reads `PI_PROXY_PORT`, and its health check uses it, but the proxy
container is created without `-e PI_PROXY_PORT=...`. The proxy therefore stays
on `8888` while `run.sh` checks the overridden port.

Pass the port at creation, validate it as `1..65535`, and recreate the proxy
container when the port changes. Keeping the port in the proxy state stamp is
enough.

### 5. Validate the proxy's locked-network bind address

`locked_ip()` currently picks the last non-default interface alphabetically. If
network ordering changes, or another network is attached, the proxy can bind to
an address Pi cannot reach, or to the default-facing interface.

Validate the candidate against an expected locked subnet
(`PI_PROXY_LOCKED_CIDR`, default `172.30.240.0/24`), reject `0.0.0.0` and the
default interface's address, and exit rather than publish a wrong address.
Validate an explicit `PI_PROXY_BIND` the same way.

### 6. Validate and rotate TLS certificates at startup

`ensure_certs()` only checks that `CERT`, `KEY`, and `CA` exist. It does not
check that the CA signs the leaf, and the leaf expires after 825 days. The
server TLS context is created per connection, so a bad pair fails on the first
request rather than at startup.

At startup:

- verify the CA signs the leaf (`openssl verify -CAfile`);
- check that the CA and leaf are not close to expiry
  (`openssl x509 -checkend`);
- regenerate on failure, or exit with a clear message;
- create and cache the server `SSLContext` before binding so failures are
  immediate.

Add `*.api.openrouter.ai` to the SAN list if regional OpenRouter hosts are used.

### 7. Make TLS work for non-Node clients

`NODE_EXTRA_CA_CERTS` covers Pi itself, but `curl` fails against OpenRouter with
the default trust store (`SSL certificate problem: unable to get local issuer
certificate`). Pass:

```bash
-e SSL_CERT_FILE=/etc/pi-proxy-ca/ca.pem
-e CURL_CA_BUNDLE=/etc/pi-proxy-ca/ca.pem
```

Consider `REQUESTS_CA_BUNDLE` and `PIP_CERT` if Python tooling is added later.

### 8. Keep the OpenRouter key out of the proxy's environment

`proxy.py` already supports `PI_ENV_FILE` and checks that the file is mode 600.
Use that instead of `--env-file "$cfg/proxy.env"`:

```bash
-v "$cfg/proxy.env:/private/proxy.env:ro" \
-e PI_ENV_FILE=/private/proxy.env
```

This keeps the key out of `container inspect pi-proxy`. If the proxy runs as
non-root, make the mounted file readable by that uid. The copy in `proxy.env`
remains an on-disk secret; document it and include it in cleanup instructions.

### 9. Authenticate proxy clients

The proxy has no client authentication. Pi is the intended client, but anything
else that can reach the proxy's `pi-locked` address can spend the OpenRouter
credits.

Add a per-run secret. Basic auth in the proxy URL is the simplest form that
works with git, curl, and Node:

- generate a random token in `run.sh` and store it in `$cfg/private`;
- pass it to Pi as `http://user:token@<proxy>:8888`;
- require the same credentials in `proxy.py` for `CONNECT`, OpenRouter
  requests, and `/health`;
- make `proxy_answers` send the credential too.

This does not stop a compromised Pi (by design), but it removes the
unauthenticated shared-key surface.

### 10. Fail closed when the proxy container drifts

`ensure_proxy` returns early when the proxy is `running`, even if the container
was manually changed. Assert the expected image, both networks (`default` and
`pi-locked`), and the intended port; recreate when they differ.

Prefer content hashes over mtimes for staleness. A single stamp made from
`proxy.py`, `Dockerfile.proxy`, `proxy.env`, and the port is sufficient; separate
the image hash from the runtime-config hash so a key change does not rebuild the
image. Accept `exited`/`created` states, and delete-and-recreate when the state
is unknown rather than falling through to `container run` with a name collision.

---

## Priority 2

### 11. Add a context-free workspace mode (`--scratch`)

Today `run.sh` requires a project context: it mounts `$PWD`, refuses `$HOME` and
`/`, and `--clone` needs a repository. Add a flag that starts Pi in a fresh
workspace with no host folder and no clone.

Suggested interface:

```bash
pic --scratch              # fresh named volume mounted at /work
pic --scratch --reset      # delete the volume first, then start clean
pic --scratch --empty      # tmpfs at /work; discarded when Pi exits
```

Implementation notes:

- Parse `--scratch`, `--reset`, and `--empty` before the mount-selection block.
- Use a named volume (default `pi-scratch`, override with `PI_SCRATCH_VOLUME`)
  mounted at `/work`, with `-w /work`.
- `--reset` should run `container volume delete` and ignore “not found”.
- `--empty` should use `--tmpfs /work` (or the Apple `container` equivalent).
- Make `--scratch` mutually exclusive with `--clone`.
- Only apply the `$HOME`/`/` refusal when neither `--scratch` nor `--clone` is
  in play, so `cd ~ && pic --scratch` works.
- Keep `pi-agent-home` mounted; only the project/workspace mount changes.
- Document the behavior in `README.md` under **Use** and **Limits**.

Acceptance criteria:

- `cd / && pic --scratch` starts Pi without a mount error.
- The workspace is `/work`; `git clone https://github.com/...` works through the
  proxy.
- `/quit` leaves `pi-scratch` intact; `pic --scratch --reset` starts empty.
- `pic --scratch --clone owner/repo` exits with a clear error.

### 12. Run Pi as a non-root user and drop capabilities

The image has no `USER`, so Pi is `uid 0` in its VM. That is not host root, but it
is still more privilege than needed, and root-owned files can appear in the
`virtiofs` project mount.

Suggested changes:

- Create a `pi` user in the `Dockerfile` and switch to it.
- Move the agent volume from `/root/.pi/agent` to the new user's home. Set
  `PI_CODING_AGENT_DIR` explicitly.
- Try `--cap-drop ALL`, `--security-opt no-new-privileges`, and a read-only root
  filesystem with a writable `/tmp` and home, if the installed Apple `container`
  release supports those flags.
- Chown or initialize the agent volume for the non-root uid on first run.
- Keep the PyInstaller `zigpeek` extraction path in mind: it needs a writable
  `$TMPDIR` when the root filesystem is read-only.
- If non-root files must remain editable on the Mac, verify how Apple `container`
  maps virtiofs ownership before choosing the uid/gid.

### 13. Strengthen `run.sh check`

- Test direct egress on `443` and UDP DNS, not only TCP `80`.
- Add an IPv6 direct-egress probe.
- Assert that `pi-locked` is `internal` as part of the check.
- Add host-side checks, because `check` runs inside Pi: proxy container networks,
  proxy bind address, and no real key in `container inspect pi-proxy` (after the
  `PI_ENV_FILE` change).
- Test the Pi/Node TLS path, not only `curl`.
- Warn loudly when the OpenRouter key has no credit limit (`limit: null`).
- Scan `pi-agent-home` for an `auth.json` containing a real key, which catches
  the “do not run `/login`” mistake.
- Keep the `example.com` and IP probes; they currently prove both DNS and proxy
  denial.
- Use `--noproxy '*'` for direct probes instead of only unsetting proxy
  variables.
- Check that `git var GIT_AUTHOR_IDENT` succeeds, and warn when the commit
  identity is unset.

### 14. Harden the proxy implementation

- Sanitize logged host/path/target values; a client on `pi-locked` can send ANSI
  escapes and `run.sh proxy` prints them to the terminal. Add timestamps.
- Add timeouts around body reads and slow connections.
- Cache the upstream `SSLContext`; today it is recreated per request.
- Consider restricting OpenRouter paths to the endpoints Pi needs.
- Add a connection cap or rate limit so a compromised client cannot exhaust the
  proxy.
- Validate `PI_PROXY_PORT` inside `proxy.py` as well.
- Add `Connection: close` to the tunnel error response and special-case clean
  EOFs so port scanners do not fill the log with `error EOFError`.
- Use `UPSTREAM_PORT` even when `UPSTREAM_HOST` is unset; today the port is
  ignored in that case.

### 15. Make `--clone` robust

- An interrupted clone leaves a directory without `.git`, so the next run fails
  with “destination already exists”. Detect that case and print a clear message
  (or clone to a temporary path and rename).
- Volume names can collide after lowercasing and replacing non-alphanumerics, and
  can exceed Apple's name limit. Append a short hash and truncate the slug.
- Tighten the `OWNER/REPO` regex to reject `..`, leading dots/dashes, and empty
  segments. Validate the `run.sh check OWNER/REPO` argument the same way.
- Print the volume name at startup and remind the user to `git push` on exit.
- Document that `--clone` does not include uncommitted changes.

### 16. Small hardening and correctness

- `NO_PROXY=` is empty, so even `localhost` goes through the proxy. Use
  `NO_PROXY=localhost,127.0.0.1,::1` (loopback only; no egress risk).
- `valid_ip` accepts `0.0.0.0`; reject it for published proxy addresses.
- `file_mode` may report the symlink's mode rather than the target's, so a
  correctly-permissioned symlinked env file is rejected. Follow symlinks and
  check readability and ownership explicitly.
- `proxy_state` splits JSON on `}`; prefer `container inspect --format` if it
  exists, or a real JSON parser. Accept more state spellings.
- Validate `PI_CPUS`, `PI_MEMORY`, `PI_PROXY_PORT`, and `PI_PROXY_WAIT` before
  passing them through.
- Pass `LANG`/`LC_ALL` (use `C.UTF-8` if unset), host `TZ`, and host
  `TERM`/`COLORTERM` instead of forcing `xterm-256color`.
- Set `PI_CODING_AGENT_DIR=/root/.pi/agent` explicitly.
- Add `run.sh --help` and reject unknown `--flags` so a typo does not become a
  command inside Pi.
- Add a simple lock around network/proxy setup so concurrent `pic` sessions do
  not race on builds, deletes, and env replacement.
- Pin base images by digest for reproducible builds.
- Confirm the Apple `container` flag names before adding capability/security
  options; they may differ between releases.

### 17. Fix `setup.zig` (or make it a thin wrapper)

- `setup.zig` finds the absolute path to `container` but does not export
  `CONTAINER_CLI` to `run.sh`; if `container` is not on `PATH`, steps 6 and 7
  fail. Pass it in the child environment.
- `hasKey` returns `false` on the first empty duplicate line instead of looking
  for a later non-empty value.
- The env file is read into a fixed 4096-byte buffer; a larger file aborts with
  an unhelpful error. Use `readFileAlloc` with a generous limit.
- Re-read and validate both keys after the editor returns, and loop or fail
  clearly when they are still empty.
- Add `Dockerfile.proxy` and `proxy.py` to the startup file check.
- Accept `-h`/`--help`, and check for Apple silicon in addition to macOS.
- Either document `zig build` in the README or fold the setup steps into
  `run.sh setup`, so the minimal path does not require Zig.

### 18. Add tests

`run.sh` has a `PI_SOURCE_ONLY` hook intended for tests, but there is no test
suite in this tree. Keep tests out of the minimal runnable branch, then add:

- shell tests for `valid_ip`, `file_mode`, `proxy_state`, the `pi-locked`
  internal-network assertion, and argument parsing for
  `--scratch`/`--reset`/`--empty`/`--clone`;
- `unittest` tests for `proxy.py` allowlists, `check_key`, and header/body
  parsing (the module is importable without starting the server);
- a version-consistency check between `Dockerfile`, `README.md`, and
  `setup.zig`.

### 19. Version-control and packaging hygiene

`.zig-cache/` and `zig-out/` were intentionally excluded from this import. Add a
`.gitignore` with at least:

```gitignore
.zig-cache/
zig-out/
*.pem
*.key
*.csr
*.srl
proxy.env
env
```

Add a `.dockerignore` for `.git`, `.zig-cache`, `zig-out`, and docs. Then, when
working outside the minimal branch:

- pin `gh` (the GitHub apt repo currently installs the latest), pin
  `pyinstaller` exactly (currently `6.*`), and pin base images by digest;
- add build-time smoke tests (`pi --version`, `gh --version`, `zig version`,
  `zigpeek info`, `rg --version`);
- add `less`, `procps`, and `git-lfs` if those tools are expected (LFS also
  needs its download hosts in the allowlist);
- add CI for `shellcheck`, `shfmt -d`, `ruff`, `py_compile`, `zig build`,
  `zig build test`, version consistency, and a secret scanner;
- add `build.zig.zon` and a `zig build test` step.

---

## Documented assumptions and limitations

- **Repo poisoning is out of scope for trusted repos.** The container protects
  host files outside the mount, but the agent can write files the host later
  executes: `.git/hooks/*`, `.git/config` (`core.hooksPath`, `core.fsmonitor`,
  `filter.*`, `include.path`), `.envrc` (direnv), and project `.pi`
  extensions/instructions. `--clone` keeps those writes out of the host checkout;
  pushes can still affect the remote, so use branch protection for anything
  important. Add `run.sh audit` to list non-sample hooks, local config, and
  attribute filters after a session.
- `/proc/net/route` shows a default route via `172.30.240.1`; blocking happens at
  the vmnet layer, not in the routing table. The README warning about macOS IP
  forwarding is accurate.
- The Pi VM can reach the Mac on the host-only subnet. Treat the Mac's services
  on that interface as exposed to a rooted VM; use the macOS firewall or a
  dedicated network if that matters.
- The project mount is writable, and the root Pi user can `chmod` files in it.
  A non-root user with a matching uid/gid would reduce root-owned artifacts.
- Certificates are long-lived and are not rotated automatically today. An expired
  leaf will break OpenRouter and `check`; document the reset procedure.
- `pi-agent-home` can contain prompts, code, and an `auth.json` if `/login` was
  used. Include it in cleanup instructions.
- `GH_TELEMETRY=0` is valid on gh 2.103 (verified); no change is needed there.

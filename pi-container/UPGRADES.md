# Upgrade notes

Status: **not implemented**. This file records the audit findings and the changes
worth making next. The code in this branch is the bootstrap snapshot that was
tested first.

Baseline verification (run from inside the Pi container):

- Direct TCP to `1.1.1.1:80`, `8.8.8.8:53`, and `140.82.121.4:443` timed out.
- External DNS did not resolve.
- The proxy returned `403` for `example.com` and for arbitrary `CONNECT` tunnels.
- `https://github.com` and `https://openrouter.ai/api/v1/key` returned `200`.
- Pi held `sk-or-v1-placeholder`, not the real OpenRouter key.
- `uid=0` inside the Pi VM, but no host root: no `docker`/`container` socket, no
  host filesystem outside the project mount, and the gateway ports tested were closed.

---

## Priority 1

### 1. Fail closed on an existing `pi-locked` network

`run.sh:37` accepts any network named `pi-locked`:

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
release before relying on that grep.

### 2. Add a context-free workspace mode (`--scratch`)

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
- `--reset` should run `container volume delete` and ignore "not found".
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

### 3. Run Pi as a non-root user and drop capabilities

The image has no `USER`, so Pi is `uid 0` in its VM. That is not host root, but it
is still more privilege than needed, and root-owned files can appear in the
`virtiofs` project mount.

Suggested changes:

- Create a `pi` user in the `Dockerfile` and switch to it.
- Move the agent volume from `/root/.pi/agent` to the new user's home.
- Try `--cap-drop ALL`, `--security-opt no-new-privileges`, and a read-only root
  filesystem with a writable `/tmp` and home, if the installed Apple `container`
  release supports those flags.
- Chown or initialize the agent volume for the non-root uid on first run.

### 4. Keep the OpenRouter key out of the proxy's environment

`proxy.py` already supports `PI_ENV_FILE` and checks that the file is mode 600.
Use that instead of `--env-file "$cfg/proxy.env"` (`run.sh:127`):

```bash
-v "$cfg/proxy.env:/private/proxy.env:ro" \
-e PI_ENV_FILE=/private/proxy.env
```

This keeps the key out of `container inspect pi-proxy`. If the proxy runs as
non-root, make the mounted file readable by that uid.

### 5. Make TLS work for non-Node clients

`NODE_EXTRA_CA_CERTS` covers Pi itself, but `curl` fails against OpenRouter with
the default trust store (`SSL certificate problem: unable to get local issuer
certificate`). Setting `SSL_CERT_FILE` to the mounted CA fixes it. Add:

```bash
-e SSL_CERT_FILE=/etc/pi-proxy-ca/ca.pem
-e CURL_CA_BUNDLE=/etc/pi-proxy-ca/ca.pem
```

Consider also `REQUESTS_CA_BUNDLE` if Python tooling is added later.

### 6. Authenticate proxy clients

The proxy has no client authentication. Pi is the intended client, but anything
else that can reach `172.30.240.6:8888` (another container on `pi-locked`, or the
Mac if it routes to that subnet) can spend the OpenRouter credits.

Add a per-run secret, for example:

- Generate a random token in `run.sh`.
- Pass it to Pi as `HTTP_PROXY`/`HTTPS_PROXY` credentials or a dedicated
  `Proxy-Authorization: Bearer ...` header.
- Require the same token in `proxy.py` for `CONNECT` and `/health`.

This does not stop a compromised Pi (by design), but it removes the
unauthenticated shared-key surface.

---

## Priority 2

### 7. Strengthen `run.sh check`

- Test direct egress on `443` and UDP DNS, not only TCP `80`.
- Add an IPv6 direct-egress probe.
- Assert that `pi-locked` is `internal` as part of the check.
- Keep the `example.com` name and IP probes; they currently prove both DNS and
  proxy denial.

### 8. Pass only intended secrets into Pi

`--env-file "$env_file"` forwards every line in the env file to the Pi
container. If unrelated secrets are ever added there, they enter the agent.
Build a filtered file (like `write_proxy_env` does) containing only:

- `GITHUB_TOKEN`
- optional `GIT_AUTHOR_*` / `GIT_COMMITTER_*` values

### 9. Small hardening and correctness

- `NO_PROXY=` is empty, so even `localhost` goes through the proxy. Use
  `NO_PROXY=localhost,127.0.0.1,::1` (loopback only; no egress risk).
- Tighten the `--clone` regex to reject `..`, leading dots, and leading dashes.
- Validate the `run.sh check OWNER/REPO` argument with the same regex.
- `proxy_state` splits JSON on `}`; prefer `container inspect --format` if it
  exists, or a real JSON parser.
- Pin base images by digest for reproducible builds.
- Confirm the Apple `container` flag names before adding capability/security
  options; they may differ between releases.

### 10. Add tests

`run.sh` has a `PI_SOURCE_ONLY` hook intended for tests, but there is no test
suite in this tree. Add shell tests for:

- `valid_ip`
- `file_mode`
- `proxy_state`
- the new `pi-locked` internal-network assertion
- argument parsing for `--scratch` / `--reset` / `--empty` / `--clone`

### 11. Version-control hygiene

`.zig-cache/` and `zig-out/` were intentionally excluded from this import. Add
a `.gitignore` with at least:

```gitignore
.zig-cache/
zig-out/
```

---

## Observed limitations (not necessarily fixable in `run.sh`)

- `/proc/net/route` shows a default route via `172.30.240.1`; blocking happens at
  the vmnet layer, not in the routing table. The README warning about macOS IP
  forwarding is accurate.
- The Pi VM can reach the Mac on the host-only subnet. Treat the Mac's services
  on that interface as exposed to a rooted VM; use the macOS firewall or a
  dedicated network if that matters.
- The project mount is writable, and the root Pi user can `chmod` files in it.
  A non-root user with a matching uid/gid would reduce root-owned artifacts.
- `GH_TELEMETRY=0` is valid on gh 2.103 (verified); no change is needed there.

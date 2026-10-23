# Pi in an Apple container

Run [Pi](https://pi.dev) on OpenRouter inside an Apple [`container`](https://github.com/apple/container)
VM. Pi's VM has no route to the internet. A second container, `pi-proxy`, is the only way out,
and it allows GitHub plus OpenRouter and nothing else.

The Mac needs `container` and nothing else. No Python, and no extra DNS setup.

```text
Mac
├── ~/.config/pi-container/env          both keys, mode 600
├── ~/.config/pi-container/proxy.env    copy of the OpenRouter key, mode 600
├── ~/.config/pi-container/pi.env       filtered GitHub token and commit identity, mode 600
├── ~/.config/pi-container/certs/       the proxy CA, mounted into Pi
├── ~/.config/pi-container/private/     the proxy's keys, mounted only into pi-proxy
├── pi-proxy                            stays up between Pi sessions
│     default network                   internet, so it can reach GitHub and OpenRouter
│     pi-locked network                 host-only. This is the only address it listens on
│     GitHub .............. tunnel
│     openrouter.ai ....... the proxy adds the real key
│     anything else ....... refused
└── Pi container, deleted when Pi exits. Attached only to pi-locked
      OPENROUTER_API_KEY    the placeholder sk-or-v1-placeholder, not your key
      GITHUB_TOKEN          your token. git sends it inside TLS, so the proxy cannot add it for you
      your project          mounted at the same path, or a private clone with --clone
      pi-agent-home         Pi's settings and sessions
```

The Pi image is tools only: Pi, git, gh, ripgrep, fd, Zig 0.17.0, and zigpeek. Nothing in
that Dockerfile enforces the network. Pi runs as root in the VM, so a firewall rule or a
proxy variable inside the image can be removed. The host-only network cannot. `pi-proxy`
is a separate VM, and it is the only container on `pi-locked` that also has a route out.

The image also warms Zig's global cache at build time. A cold `zig init` spends about a
minute compiling compiler_rt and the build runner; in a fresh Pi container it now takes
seconds, and the first `zig build` only has the per-project work left.

## Setup

macOS 26 and Apple silicon:

```bash
brew install container
container system start          # answer Y to install the default kernel
```

From this folder:

```bash
mkdir -p ~/.config/pi-container
printf 'OPENROUTER_API_KEY=\nGITHUB_TOKEN=\n\n# Optional: commit identity for git in the Pi container.\n# GIT_AUTHOR_NAME=\n# GIT_AUTHOR_EMAIL=\n' > ~/.config/pi-container/env
chmod 600 ~/.config/pi-container/env
open -e ~/.config/pi-container/env       # paste the keys after =, with no quotes

container build -t pi-agent:local .   # skip when that image is already built
./run.sh check you/your-repo
```

`check` creates the `pi-locked` network, builds the small proxy image, and starts `pi-proxy`.
It confirms Pi has the OpenRouter placeholder rather than your key, prints the key's credit
limit, checks GitHub, and checks that `example.com` is refused and that a direct connection
to an IP address fails.
It spends no OpenRouter credits. The first run is the slow one, because it builds `pi-proxy`.
`run.sh` is the only setup entry point you need; `build.zig` and `setup.zig` are an optional
convenience and do not have to be built to run Pi.

If an earlier try created the `host.container.internal` domain, delete it so iCloud Private Relay
can stay on:

```bash
sudo container system dns delete host.container.internal
```

## Use

```bash
alias pic=/path/to/pi-container/run.sh    # full path, in ~/.zshrc

cd ~/code/your-repo
pic                      # Pi. Edits land on your Mac
pic pi --continue
pic bash
pic --clone you/your-repo
```

`/model` picks an OpenRouter model (`:free` costs nothing). `/quit` exits and deletes the Pi
VM. `pi-proxy` keeps running. Do not run `/login`. That would save a real key into the Pi
settings volume.

The default mode mounts the current folder. Treat that as a convenience for repos you
already trust; use `--clone` for anything else. `run.sh --help` lists the flags.

`run.sh proxy` follows `pi-proxy`'s log. `run.sh proxy-stop` stops it. A normal `pic` starts
it again when it is not already up. Log lines start with a timestamp and then `listening`,
`allow`, `deny`, or `openrouter`.
`run.sh` waits until that listener answers a health check run inside `pi-proxy`, and Pi
uses that address.

## Keys

The env file stays on the Mac. `run.sh` refuses to start unless it is mode 600 or 400.
`run.sh` writes two mode-600 copies: `proxy.env` contains only the OpenRouter key, and
`pi.env` contains only the GitHub token and commit identity. Pi gets the filtered file,
not the original env file.

- **OpenRouter** is handed to `pi-proxy` as an environment variable, and to Pi as
  `sk-or-v1-placeholder`. The proxy puts the real key on the request. Set a credit limit
  on the key. Pi can still spend it, by asking the proxy to call OpenRouter, and Pi
  cannot read the key. `container inspect pi-proxy` shows it; a Pi container does not.
- **GitHub** is passed into Pi only. git and `gh` send it inside TLS to github.com, and a
  tunnel proxy cannot see or add that header. Make it a fine-grained token for **one repo**,
  with Contents and Pull requests set to Read and write, Workflows left off, and a short
  expiry. The proxy will not open a connection to any host except GitHub, so the token
  cannot be sent anywhere else. It can still be written into a prompt, which OpenRouter
  then sees.
- **Push:** no extra `git config` or `gh auth login` is needed. The image installs a
  system-level credential helper (`gh auth git-credential`), so HTTPS pushes use
  `GITHUB_TOKEN`, and `git@github.com:` remotes are rewritten to HTTPS.
- **Commits:** add `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` to the env file. `run.sh` uses
  them for both the author and committer (set `GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL`
  only when the committer should differ). With neither set, `git commit` fails; `git push`
  still works.

Pi's install ping and `gh` telemetry are turned off. `pi.dev` is not reachable anyway.

## Limits

- The proxy allows `github.com`, `api.github.com`, `codeload.github.com`,
  `objects.githubusercontent.com`, `raw.githubusercontent.com`, `uploads.github.com`,
  and `openrouter.ai` (and its subdomains). Package registries, `ziglang.org`, and
  everything else are refused.
- `pi-locked` is host-only. `run.sh` creates it as `172.30.240.0/24` when the name is not already there; an existing `pi-locked` network is left as it is.
  Pi can reach your Mac and other containers on that network. `pi-proxy` listens only on
  its `pi-locked` address, so a container on `default` cannot use the key.
- If the Mac is forwarding IP (`sysctl net.inet.ip.forwarding` prints `1`), a host-only
  network can still open TCP to the internet. `run.sh check` reports that as a direct
  connection. Forwarding is off unless a VPN or Internet Sharing turned it on.
- `run.sh` will not mount `~`, `/`, an ancestor of `~`, a secrets directory such as
  `~/.ssh`, or anything overlapping `~/.config/pi-container`. `--clone` keeps the repo in a
  volume until you `git push`; it does not include uncommitted changes.
- `PI_PROXY_PORT` (default 8888) sets the proxy port. The proxy container is recreated when
  the port or its config changes.
  `container volume list` shows `pi-agent-home` and any clone volumes.
- `PI_CPUS` (default 4) and `PI_MEMORY` (default 4G) size the Pi VM. The proxy VM is 1 CPU and 1G.
- Rebuild the Pi image with `--build-arg PI_VERSION=…` or `--build-arg ZIG_VERSION=…` to
  upgrade tools. Changing the proxy does not require that rebuild: `run.sh` rebuilds
  `pi-proxy` when `proxy.py` or `Dockerfile.proxy` changes.

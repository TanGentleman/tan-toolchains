# Playbooks

Each recipe is the whole path for one use. Details live in the references
linked at the end.

## Set up once

You need an Apple silicon Mac on macOS 26 and an OpenRouter key. This table is
everything the Mac itself needs; the images build every other tool, so there
is no Homebrew, Node, Zig or Go to install for normal use.

| What | Needed for | Install |
|---|---|---|
| Command Line Tools (`git`, `python3`) | cloning, `run-tests.sh` | `xcode-select --install` |
| Apple [`container`](https://github.com/apple/container/releases) | every VM | the signed `.pkg` below, once per Mac (admin); `container system start` in each account |
| `jq` | `run.sh`, `clear.sh`, tests | nothing: macOS 26 has `/usr/bin/jq` |
| [Tailscale](https://tailscale.com/download/macos) | fleet only | the app ([fleet step 5](../fleet/docs/macos.md#5-tailscale)) |
| [uv](https://docs.astral.sh/uv/) | `spikes/local-model` only | `curl -LsSf https://astral.sh/uv/install.sh \| sh` (per account, no admin) |
| Zig at the `ZIG_VERSION` pin (0.17.0); Go optional | `mac-e2e.sh ci` only, when changing the repo | [ziglang.org/download](https://ziglang.org/download/), [go.dev/dl](https://go.dev/dl/) |

```sh
xcode-select --install                      # skip if `git --version` works
V=1.7.1                                     # or the newest at github.com/apple/container/releases
curl -fLo /tmp/container.pkg "https://github.com/apple/container/releases/download/$V/container-$V-installer-signed.pkg"
sudo installer -pkg /tmp/container.pkg -target /   # puts container in /usr/local/bin for every account
```

Homebrew's `container` formula is the same CLI and also works, but use one
source, not both. The `.pkg` is preferred because it is on every account's
`PATH`; `brew` in a second account is not, and only the admin who owns
`/opt/homebrew` can install with it.

Then, in each account:

```sh
container system start
T=~/src/tan-toolchains     # your checkout; later blocks use $T
git clone https://github.com/TanGentleman/tan-toolchains $T
echo "alias pic=$T/pi-container/run.sh" >> ~/.zshrc && source ~/.zshrc
mkdir -p ~/.pic/config
printf 'OPENROUTER_API_KEY=\n# GITHUB_TOKEN=\n# GIT_AUTHOR_NAME=\n# GIT_AUTHOR_EMAIL=\n' > ~/.pic/config/env
chmod 600 ~/.pic/config/env && open -e ~/.pic/config/env
```

Pick the image, egress profile and model route with env vars, best in
aliases (a flag beats them):

```sh
alias mpic='PI_IMAGE=min pic --instance min'
alias opic='PI_IMAGE=min PI_EGRESS=offline PI_MODEL_URL=http://gateway:8090 pic --instance offline'
```
 `pic config` prints what is in effect and where each value came from;
`pic images` lists the packs.

| Env var / key | Values |
| --- | --- |
| `image` | `min` (Pi, git, jq, rg, fd), `full` (min + gh + enforcer; default), `zig` |
| `egress` | `standard` (GitHub + OpenRouter; default), `offline` (local model only), or your own profile |
| `model_url` | `openrouter` (default) or `http://gateway:8090` (a model server on this Mac) |

## 1. Pi on a repo on this Mac

```sh
cd $T/pi-container && ./build.sh full
pic check you/your-repo         # every line ok
cd ~/code/your-repo && pic      # or: pic --clone you/your-repo
```

Needs `GITHUB_TOKEN` in the env file for private repos and pushes.

## 2. Several chats from your phone on the min image

No GitHub token needed: sessions with an empty repo are scratch chats.

```sh
cd $T/pi-container && ./build.sh min && ./build.sh fleet
export PI_IMAGE=min             # in the shell that runs pic serve
pic config                      # image min (env), egress standard
```

Tailscale, once: install the macOS app, log in as yourself, turn on its CLI
integration (menu bar → Settings), and enable MagicDNS and HTTPS
Certificates at https://login.tailscale.com/admin/dns. Then:

```sh
pic serve --check               # one ok line per check, then: ready
caffeinate -i $T/pi-container/run.sh serve
```

Open `https://<this Mac's tailnet name>` on the phone (Tailscale on), leave
repo empty, and spawn. Each session is one chat; a node runs 2 turns at
once and answers `node busy` to a third. Each turn's line in the session
shows the image and egress it ran with.

With a token and a repo, sessions push to `fleet/<sid>` instead; the full
fleet checklist is [fleet/docs/macos.md](../fleet/docs/macos.md).

## 3. Offline with a local model

Pi reaches only a model server on this Mac: no GitHub, no openrouter.ai, no
token in the VM.

```sh
S=$T/spikes/local-model
$S/model install                  # once
$S/model serve --containers       # tab 1: owns the model; Ctrl-C unloads it
$S/model check && opic check && opic pi -p "say hi"    # tab 2
```

For a repo, make a local mirror first; offline turns clone it and keep
their commits in the session's `repo.bundle` (nothing is pushed):

```sh
git clone --mirror https://github.com/you/your-repo.git ~/.pic/config/mirrors/you/your-repo.git
git -C ~/.pic/config/mirrors/you/your-repo.git fetch --prune     # refresh later
git fetch ~/.pic/fleet/sessions/<sid>/state/repo.bundle 'refs/heads/*:refs/remotes/offline/*'   # take the work out
```

For fleet, export the three env vars before `pic serve`.

## Your own egress profile

Copy a built-in from `pi-container/egress/` to
`~/.pic/config/egress/NAME.json`, edit `tunnel` (hosts Pi may
reach), `model_url` (`any` or `private`) and `github_token`, then use
`PI_EGRESS=NAME`. `pic config` prints the hosts; `pic check` tests them.

To add hosts to a built-in profile instead, set `PI_EXTRA_TUNNEL=HOST[,HOST...]`
(or `https://HOST`) in the shell or the env file
([extra tunnel hosts](../pi-container/docs/configuration.md#extra-tunnel-hosts)).

## Upgrade `container`

In place; volumes and images stay:

```sh
cd $T/pi-container
./clear.sh export                             # backup of every pi volume, without auth.json
container system stop && /usr/local/bin/update-container.sh && container system start
container system kernel set --recommended    # otherwise VMs keep booting the old kernel
container builder delete --force && container delete --force pi-proxy
test/migrate-check.sh                         # no FAIL lines; compares volumes with the export
```

[container-1.7.1.md](../pi-container/docs/container-1.7.1.md) has what changed
from 1.6.1 and a full reinstall that keeps sessions and config.

## References

- [Network boundary](network-boundary.md): what Pi can reach, and how.
- [Configuration](../pi-container/docs/configuration.md): every file, flag and variable.
- [fleet README](../fleet/README.md): sessions, API, event log.
- [fleet on macOS](../fleet/docs/macos.md): the step-by-step fleet setup and its verification.

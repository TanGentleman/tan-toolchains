# Playbooks

Each recipe is the whole path for one use. Details live in the references
linked at the end.

## Set up once

An Apple silicon Mac on macOS 26 with Homebrew, an OpenRouter key, and
nothing else: the images build every tool.

```sh
brew install container jq && container system start
git clone https://github.com/TanGentleman/tan-toolchains ~/src/tan-toolchains
echo "alias pic=$HOME/src/tan-toolchains/pi-container/run.sh" >> ~/.zshrc && source ~/.zshrc
mkdir -p ~/.config/pi-container
printf 'OPENROUTER_API_KEY=\n# GITHUB_TOKEN=\n# GIT_AUTHOR_NAME=\n# GIT_AUTHOR_EMAIL=\n' > ~/.config/pi-container/env
chmod 600 ~/.config/pi-container/env && open -e ~/.config/pi-container/env
```

Pick the image, egress profile and model route with env vars, best in
aliases (a flag beats them; an optional `~/.config/pi-container/config.json`
with the same keys sets defaults under them):

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
cd ~/src/tan-toolchains/pi-container && ./build.sh full
pic check you/your-repo         # every line ok
cd ~/code/your-repo && pic      # or: pic --clone you/your-repo
```

Needs `GITHUB_TOKEN` in the env file for private repos and pushes.

## 2. Several chats from your phone on the min image

No GitHub token needed: sessions with an empty repo are scratch chats.

```sh
cd ~/src/tan-toolchains/pi-container && ./build.sh min && ./build.sh fleet
export PI_IMAGE=min             # in the shell that runs pic serve
pic config                      # image min (env), egress standard
```

Tailscale, once: install the macOS app, log in as yourself, turn on its CLI
integration (menu bar → Settings), and enable MagicDNS and HTTPS
Certificates at https://login.tailscale.com/admin/dns. Then:

```sh
pic serve --check               # one ok line per check, then: ready
caffeinate -i ~/src/tan-toolchains/pi-container/run.sh serve
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
S=~/src/tan-toolchains/spikes/local-model
$S/model install && $S/model up --containers && $S/model check
opic check && opic pi -p "say hi"
```

For a repo, make a local mirror first; offline turns clone it and keep
their commits in the session's `repo.bundle` (nothing is pushed):

```sh
git clone --mirror https://github.com/you/your-repo.git ~/.config/pi-container/mirrors/you/your-repo.git
git -C ~/.config/pi-container/mirrors/you/your-repo.git fetch --prune     # refresh later
git fetch ~/.fleet/sessions/<sid>/state/repo.bundle 'refs/heads/*:refs/remotes/offline/*'   # take the work out
```

For fleet, export the three env vars before `pic serve`. `$S/model down` unloads the
model.

## Your own egress profile

Copy a built-in from `pi-container/egress/` to
`~/.config/pi-container/egress/NAME.json`, edit `tunnel` (hosts Pi may
reach), `model_url` (`any` or `private`) and `github_token`, then use
`PI_EGRESS=NAME`. `pic config` prints the hosts; `pic check` tests them.

## References

- [Network boundary](../README.md#network-boundary): what Pi can reach, and how.
- [Configuration](../pi-container/docs/configuration.md): every file, flag and variable.
- [fleet README](../fleet/README.md): sessions, API, event log.
- [fleet on macOS](../fleet/docs/macos.md): the step-by-step fleet setup and its verification.

# fleet on macOS: a Mac you spawn Pi agents on from your phone

From a clean Mac to `fleetd` on your tailnet, with one harness, `pi-ctr`:
each turn runs Pi in pi-container's VM, on a fresh clone of the repo you
pick, and pushes the result to a `fleet/<session>` branch. You spawn and
steer sessions from the phone UI. The Mac needs Homebrew, Apple
`container` and Tailscale. It needs no Go, Node or agent CLIs on the host.

Run each block in Terminal (zsh), in order. Run `setopt interactivecomments`
first (add it to `~/.zshrc` to keep it): without it zsh passes a trailing
`# comment` to the command as arguments. Each step ends with a check; do not
go on until it passes.

The Mac checklist is in
[pi-container/E2E.md](../../pi-container/E2E.md#fleet-node-pi-ctr).

## Before you start

- An Apple silicon Mac on macOS 26 you can log in to as an admin. The image
  is arm64-only.
- An [OpenRouter](https://openrouter.ai) key.
- A GitHub fine-grained token (step 4) and a repo for the agents to work on.
- A [Tailscale](https://tailscale.com) account. Free is enough.

## 0. What you end up with

| Thing | Where |
|---|---|
| Repo | `~/src/tan-toolchains` |
| `fleetd` binary | `~/src/tan-toolchains/fleet/bin/fleetd`, built in a container by `build.sh fleet` |
| Agent image | `pi-agent:local`, built by `build.sh` |
| OpenRouter key and GitHub token | `~/.config/pi-container/env`, mode 600. The proxy reads the key; `fleetd` never has it |
| Session data | `~/.fleet` (transcripts and Pi session files) |
| Code each session wrote | branch `fleet/<sid>` in the repo you picked |
| Logs | the terminal running `pic serve`; per turn, `~/.fleet/sessions/<sid>/stderr-N.log` |

## 1. Homebrew, container, jq

```sh
xcode-select --install          # skip if it says already installed
# Homebrew (https://brew.sh):
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install container jq
container system start
```

Check: `container system status` succeeds and `jq --version` prints a version.

## 2. Repo

```sh
mkdir -p ~/src && git clone https://github.com/TanGentleman/tan-toolchains ~/src/tan-toolchains
echo "alias pic=$HOME/src/tan-toolchains/pi-container/run.sh" >> ~/.zshrc
alias pic=$HOME/src/tan-toolchains/pi-container/run.sh
cd ~/src/tan-toolchains/pi-container
```

## 3. Build the image and fleetd

```sh
./build.sh                # pi-agent:local; the first build takes a while
./build.sh fleet          # fleet/bin/fleetd, compiled in a pinned Go image
file ../fleet/bin/fleetd  # Mach-O 64-bit executable arm64
../fleet/bin/fleetd -h 2>&1 | head -3
```

`build.sh fleet` runs `go build` inside `golang:1.27.4` (pinned by digest in
`build.sh`) with `GOTOOLCHAIN=local` and `GOPROXY=off`, so nothing is
downloaded but the image. Rerun it after every `git pull`.

## 4. Keys

Make a GitHub **fine-grained** token (Settings → Developer settings →
Fine-grained tokens):

- Repository access: **Only select repositories**, the ones agents may push to.
- Permissions: **Contents: Read and write**. Metadata: Read is added for you.
- Nothing else. In particular **not Workflows** and **not Administration**.

What that means: the token sits inside the VM, so anything a turn runs can
use it. It can push any branch of the selected repos, but not change
`.github/workflows` (GitHub rejects the push, and the turn fails with "the
token has no Workflows permission") and not change settings or branch
protection. `pi-ctr` itself only pushes `fleet/<sid>`. Protect your default
branch with a ruleset if a turn must never touch it.

```sh
mkdir -p ~/.config/pi-container
cat > ~/.config/pi-container/env <<'EOF'
OPENROUTER_API_KEY=
GITHUB_TOKEN=
GIT_AUTHOR_NAME=
GIT_AUTHOR_EMAIL=
EOF
chmod 600 ~/.config/pi-container/env
open -e ~/.config/pi-container/env
pic check you/your-repo
```

Check: `pic check` reports the placeholder key in Pi, OpenRouter and GitHub
reachable, and `example.com` and direct connections blocked.

The real key stays in this file and the proxy. Pi gets
`sk-or-v1-placeholder`, and the proxy swaps in the real key for
`openrouter.ai` only. Don't export `OPENROUTER_API_KEY` in your shell:
`pic serve` refuses to start if it is set, so `fleetd` can't inherit it.

## 5. Tailscale

1. Install the standalone app from https://tailscale.com/download/macos
   (or `brew install --cask tailscale-app`) and open it. Allow the VPN
   configuration, then turn on the Tailscale network extension under System
   Settings → General → Login Items & Extensions → Network Extensions (it asks
   for your password). Then log in **as yourself**, not with a tagged auth
   key: `fleetd`'s owner is a tailnet login.
2. Menu bar icon → Settings → CLI integration → install, so `tailscale` is
   on `PATH`. Check: `tailscale version`.
3. Admin console → DNS (https://login.tailscale.com/admin/dns): enable
   MagicDNS and HTTPS Certificates. `tailscale serve` needs both.

## 6. Serve it

```sh
pic serve --check
```

It prints one `ok` or `FAIL` line for each of: Tailscale running and
logged in as a user (not a tagged device), HTTPS certificates on for this
Mac's name, the container system, the image, the key and token in the env
file, no real key in this shell, `fleetd` built, and port 7433 free. If any
line says `FAIL`, `pic serve` won't start; fix it and rerun.

```sh
caffeinate -i pic serve
```

`pic serve` runs `fleetd` and `tailscale serve --https=443` in the
foreground (Ctrl-C stops both). `-name`, `-url` and `-owner` default to this
Mac's Tailscale host name, `https://<name>.<tailnet>.ts.net` and your login;
pass them to override; another `-owner` adds a login, and owners can do
everything (README, "What access means"). `caffeinate -i` stops idle sleep; closing a laptop's lid still
sleeps it.

Check, in a second terminal:

```sh
URL=https://$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')
curl -si "$URL/v1/node" | head -1       # HTTP/2 200
curl -s "$URL/v1/node" | jq .harnesses  # ["pi-ctr"]
```

Ctrl-C `pic serve`, then check `tailscale serve status` shows no config.

## 7. Spawn from the phone

Open `$URL` on the phone with the Tailscale app on. Fill in:

- **harness**: `pi-ctr`, the only one unless you add `-harness`
- **repo**: `you/your-repo` (one the token can push to). Empty means no
  clone: Pi works in an empty `/work` on the VM's disk, nothing from the Mac
  is mounted, and its files are gone after the turn. Only the transcript
  carries over.
- **branch**: where the first turn starts; empty means the default branch
- **model**: empty uses `settings.json`'s default
- **prompt**

Each turn:

1. Starts a fresh VM on the `pi-locked` network, with only this session's
   state folder mounted.
2. Clones the repo into the VM's disk at `/work/<repo>` and checks out
   `fleet/<sid>`. On the first turn, or the first turn of a fork, there is
   no such branch, so it checks out the session's base: the fork point, or
   the branch you picked.
3. Runs Pi on the session's transcript.
4. Stages everything and refuses to push files over 10 MiB
   (`PI_CTR_MAX_FILE_BYTES`) or anything that looks like a GitHub token,
   including the exact `GITHUB_TOKEN` value. Then it commits and pushes to
   `fleet/<sid>`.

A failed Pi turn is still pushed, because its transcript is kept. An
aborted turn pushes nothing, and its transcript goes back to the last
finished turn. The session page shows each push as a `pi_ctr.push` line, and
the session's `commit` is the latest one pushed.

Check: after the first turn, `git ls-remote https://github.com/you/your-repo fleet/<sid>`
prints the commit the session shows.

Only Pi's session file and the adapter's `agent.json` are kept between
turns. Anything else Pi writes to its state folder, extensions included, is
deleted after the turn, so nothing a turn installs carries over.

## 8. Upgrading and removing

```sh
cd ~/src/tan-toolchains && git pull && cd pi-container && ./build.sh && ./build.sh fleet
# then restart pic serve
```

To remove: stop `pic serve` and delete `~/.fleet` (every session) and
`~/.config/pi-container/env`. Host CLIs (`fleetd agent pi`, `claude`,
`codex`) still work as custom harnesses, outside the VM; see the fleet README.

## Troubleshooting

| Symptom | Check |
|---|---|
| `pic serve` prints `FAIL` lines | Each line says what to fix. |
| `jq: parse error` | The reply is an error message, not JSON. Run the `curl` without `jq`. |
| `421 unexpected Host` | You passed a `-url` that doesn't match the name you curl. Drop it; `pic serve` reads it from Tailscale. |
| `no tailnet identity` at `127.0.0.1:7433` | Expected. Use `$URL`, which goes through `tailscale serve`. |
| `401` / `403` | No identity header (not through `tailscale serve`), or your login is not an `-owner`. |
| `409` on input | A turn is still running; wait for `exited`, or abort it. |
| Turn fails, `push refused: ...` | The reason is in the session's last `exited`. Workflows: the token can't change `.github/workflows`, by design. |
| Turn fails, `cannot check out fleet/<sid>` or `cannot fetch base` | The token can't read the repo, or the base commit was force-pushed away. |
| Turn fails before Pi starts | `~/.fleet/sessions/<sid>/stderr-N.log` has `run.sh`'s message, e.g. the image or proxy. |
| Turn exits 3 | Pi's saved session is gone or changed; fork from an earlier checkpoint. |
| Unreachable from the phone | The Mac is asleep or `pic serve` is not running. |

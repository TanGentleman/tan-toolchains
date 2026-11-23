# fleet on macOS: a Mac you spawn Pi agents on from your phone

From a clean Mac to `fleetd` on your tailnet, with one harness, `pi-ctr`:
each turn runs Pi in pi-container's VM, on a fresh clone of the repo you
pick, and pushes the result to a `fleet/<session>` branch. You spawn and
steer sessions from the phone UI. The Mac needs Homebrew, Apple
`container` and Tailscale. It needs no Go, Node or agent CLIs on the host.

Run each block in Terminal (zsh), in order. Run `setopt interactivecomments`
first (add it to `~/.zshrc` to keep it): without it zsh passes a trailing
`# comment` to the command as arguments. Each step ends with a check; do not
go on until it passes. What a session and a turn are, and the security
model: [the fleet README](../README.md).

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

## 3. Test, then build the image and fleetd

```sh
./test/run-tests.sh       # pic's scripts against a fake container: "run-tests.sh: all tests passed"
./build.sh                # pi-agent:local; the first build takes a while
./build.sh fleet          # fleet's tests, then fleet/bin/fleetd, in a pinned Go image
file ../fleet/bin/fleetd  # Mach-O 64-bit executable arm64
../fleet/bin/fleetd -h 2>&1 | head -3
```

`build.sh fleet` runs `fleet`'s `go vet` and tests, then `go build`, inside
`golang:1.27.4` (pinned by digest in `build.sh`) with `GOTOOLCHAIN=local` and
`GOPROXY=off`, so nothing is downloaded but the image. It prints `ok` for each
package; if a test fails it prints `FAIL` and builds nothing. Rerun it after
every `git pull`.

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
pass them to override. Another `-owner` adds a login; owners can do
everything, so add only people you would give a shell (README, "Security
model"). `caffeinate -i` stops idle sleep; closing a laptop's lid still
sleeps it.

Check, in a second terminal. These three lines define `$URL` and two
helpers that later steps use; paste them into every new terminal.

```sh
URL=https://$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')
sessions() { curl -sS --fail-with-body "$URL/v1/sessions" | jq -r '.[] | .sid + "  " + .title'; }
st() { curl -sS --fail-with-body "$URL/v1/sessions/${1:?usage: st SID}" | jq '{harness, repo, branch, base, commit, running}'; }
```

```sh
curl -sS --fail-with-body "$URL/v1/node" | jq .harnesses   # ["pi-ctr"]
```

## 7. Spawn from the phone

Open `$URL` on the phone with the Tailscale app on. Fill in:

- **repo**: `you/your-repo`, one the token can push to. Empty makes a
  scratch session: the form says so, and anything Pi writes is gone after
  each turn.
- **branch**: where the first turn starts; empty means the default branch.
- **model**: empty uses `settings.json`'s default.
- **prompt**

Each turn runs in a fresh VM, clones the repo, runs Pi on the transcript so
far, and pushes to `fleet/<sid>` unless a guardrail refuses (a file over
10 MiB, or anything that looks like a GitHub token). The README's
[A turn](../README.md#a-turn) has every step.

A session's id (`sid`) is the part of the phone's URL after `#`, without the
`#`. `sessions` lists them all. Check, after the first turn ends:

```sh
sid=s0123456789abcdef   # yours, from `sessions`
st $sid                 # harness "pi-ctr", running false, commit set
git ls-remote https://github.com/you/your-repo fleet/$sid   # the same commit
```

## 8. Verify before relying on it

Do this once per new Mac and before calling a branch stable. Each item is
one check; a failure is a blocker. Use a throwaway repo so nothing touches
real work:

```sh
REPO=you/fleet-e2e      # private, with a README; add it to the token's repos
```

Keep `pic serve` running in one terminal and use another, with the step 6
helpers pasted, from `~/src/tan-toolchains/pi-container`.

### Isolation (do these first; the security model depends on them)

- [ ] The key is not in fleetd: `ps eww -p $(pgrep -x fleetd) | grep -c OPENROUTER_API_KEY`
      prints `0`.
- [ ] A turn's VM can't reach fleetd, the Mac or another tailnet device.
      Spawn any session on `$REPO`, wait for its turn to end, set `sid`, then:

      ```sh
      MAC=${URL#https://}
      PEER=$(tailscale status --json | jq -r '[.Peer[].DNSName][0] | rtrimstr(".")')
      GW=$(container network inspect pi-locked | jq -r '.[0].status.ipv4Gateway')
      echo "$MAC $PEER $GW"   # three non-empty values
      pic --fleet-state ~/.fleet/sessions/$sid/state bash -c '
        for u in "https://$1/v1/node" "https://$2/" "http://$3:7433/v1/node"; do
          curl -sS -m 5 -o /dev/null "$u" && echo "FAIL via proxy: $u" || echo "ok via proxy: $u"
          env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy curl -sS --noproxy "*" -m 5 -o /dev/null "$u" \
            && echo "FAIL direct: $u" || echo "ok direct: $u"
        done' check "$MAC" "$PEER" "$GW"
      ```

      All six lines say `ok`. Any `FAIL` means a turn can act as you on
      fleetd: stop and report it.
- [ ] `pic proxy` (in a third terminal, during the turns below) shows only
      `openrouter.ai` and GitHub hosts.

### A turn

- [ ] Spawn on `$REPO`, branch empty, prompt `Create hello.txt containing hi.`
      The turn ends with `exited` code 0.
- [ ] `st $sid`: `harness` is `pi-ctr`; `base` equals
      `git ls-remote https://github.com/$REPO main` at spawn; `commit` equals
      `git ls-remote https://github.com/$REPO fleet/$sid`; that commit has
      `hello.txt`.
- [ ] A second prompt makes a commit whose parent is the first, and Pi
      remembers the first turn.
- [ ] Fork it from the UI: the fork's `base` is the parent's `commit`, and
      its first turn pushes `fleet/<fork sid>` on top.
- [ ] Scratch: spawn with repo empty and prompt `Create note.txt containing hi`,
      then send `Does note.txt exist? Run ls.` Pi remembers the first turn,
      `note.txt` is gone, and nothing was pushed.
- [ ] Startup time: note `first_output_ms` of three turns:
      `curl -sS "$URL/v1/sessions/$sid/events" | grep -o 'first_output_ms[^,]*'`.

### Refusals

- [ ] Abort: prompt `Run sleep 120 in bash, then create late.txt`, press
      Abort. `exited` says `aborted`, `fleet/$sid` is unchanged, `container ls`
      shows no `fleet-$sid`, and the next turn continues the transcript.
- [ ] Workflow: prompt `Create .github/workflows/x.yml with on: push`. The turn
      fails with `push refused` naming `.github/workflows`; `fleet/$sid` is
      unchanged.
- [ ] Token: prompt `Write the value of $GITHUB_TOKEN into token.txt`. The turn
      fails with `push refused`; nothing is pushed.
- [ ] Owners only (needs a second tailnet login): from a device logged in as
      it, `$URL` answers 403.

### Crash and restart

- [ ] Start a turn with `Run sleep 120 in bash`, then `kill -9 $(pgrep -x fleetd)`.
      `pic serve` exits. Within a few seconds `container ls` has no
      `fleet-$sid` and `pgrep -f pi-ctr` prints nothing.
- [ ] Start `pic serve` again: the session ends with `exited` reason
      `node restarted`, and the next prompt continues the transcript and
      `fleet/$sid`.
- [ ] Two sessions spawned within a second of each other both finish.
- [ ] Ctrl-C `pic serve`: `tailscale serve status` shows no config and
      `container ls` no `fleet-` container.

### `pic serve --check` refusals (optional)

Each of these makes `pic serve --check` print a `FAIL` line and exit non-zero:
Tailscale logged out, HTTPS certificates off, `container system stop`,
`PI_IMAGE=nope:local`, `GITHUB_TOKEN` removed from the env file, `chmod 644`
on the env file, `OPENROUTER_API_KEY=x pic serve --check`. Restore each
before the next.

### What runs where

| Where | Runs | Needs |
|---|---|---|
| CI, every push | fleet's Go tests with real Pi behind `proxy.py`, `fleet/e2e/pi-ctr.sh`, pic's script tests | nothing from you |
| Step 3 | pic's script tests; fleet's Go tests in the Go image (real-Pi tests skip there) | `container`, `jq` |
| Step 4, `pic check` | the real VM, proxy and network lock | key, token |
| Step 6, `pic serve --check` | Tailscale, HTTPS certificates, image, keys, port | Tailscale |
| Step 8 | the VM's isolation, GitHub refusals, crash cleanup, the phone | `$REPO`, the phone |

pi-container's own checklist, [E2E.md](../../pi-container/E2E.md), covers
interactive `pic` (instances, mounts, Neovim, cleanup); fleet doesn't need it.

## 9. Upgrading and removing

```sh
cd ~/src/tan-toolchains && git pull && cd pi-container && ./build.sh && ./build.sh fleet
# then restart pic serve
```

To remove: stop `pic serve` and delete `~/.fleet` (every session) and
`~/.config/pi-container/env`.

## Troubleshooting

Run the failing `curl` with `-sS -i` and without `jq`: the status line and
body say what's wrong.

| Symptom | Cause |
|---|---|
| `pic serve` prints `FAIL` lines | Each line says what to fix. |
| `404 page not found` | The path is wrong: usually `$sid` is empty or starts with `#`. |
| `no such session` | `$sid` is not one of `sessions`. |
| `jq: parse error` | The reply is an error message, not JSON (see above). |
| `401` / `no tailnet identity` | The request didn't go through `tailscale serve`; use `$URL`, not `127.0.0.1:7433`. |
| `403` | Your login is not an `-owner`. |
| `421 unexpected Host` | You passed a `-url` that doesn't match the name you curl. Drop it. |
| `409` on input | A turn is still running; wait for `exited`, or abort it. |
| Turn fails, `push refused: ...` | The reason is in the session's last `exited`. |
| Turn fails, `cannot check out fleet/<sid>` or `cannot fetch base` | The token can't read the repo, or the base commit was force-pushed away. |
| Turn fails before Pi starts | `~/.fleet/sessions/<sid>/stderr-N.log` has `run.sh`'s message. |
| Turn exits 3 | Pi's saved session is gone or changed; fork from an earlier checkpoint. |
| A session shows `Unreadable` in red | Its log was written by another `fleetd` version. The node skips it and leaves it unchanged; move `~/.fleet/sessions/<sid>` out to clear the line. |
| `fleet-<sid>` still in `container ls` after a crash | Start `pic serve` again; it stops the leftover before anything else. |
| Unreachable from the phone | The Mac is asleep or `pic serve` is not running. |

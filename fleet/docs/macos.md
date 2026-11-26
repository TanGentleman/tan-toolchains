# fleet on macOS

From a clean Mac to spawning Pi sessions from your phone. Each turn runs Pi
in pi-container's VM on a fresh clone of the repo you pick and pushes to a
`fleet/<session>` branch. The Mac needs Homebrew, Apple `container` and
Tailscale; no Go, Node or agent CLIs. What a session and a turn are, and the
security model: [the fleet README](../README.md).

Run each block in Terminal (zsh), in order, and don't go on until its check
passes. First run `setopt interactivecomments` (add it to `~/.zshrc`):
without it, zsh passes a trailing `# comment` to the command.

## Before you start

- An Apple silicon Mac on macOS 26, with an admin login.
- An [OpenRouter](https://openrouter.ai) key.
- A GitHub repo for the agents, and a fine-grained token for it (step 4).
- A [Tailscale](https://tailscale.com) account (free is enough) and the
  Tailscale app on your phone.

| What | Where |
|---|---|
| Repo | `~/src/tan-toolchains` |
| `fleetd` | `~/src/tan-toolchains/fleet/bin/fleetd`, built by `build.sh fleet` |
| Agent image | `pi-full:local`, built by `build.sh full`; `~/.config/pi-container/config.json` can pick `min` or `zig` |
| Node config | `~/.config/pi-container/config.json` (image, egress, model_url); `pic config` prints it, `GET /v1/node` serves it |
| OpenRouter key, GitHub token | `~/.config/pi-container/env`, mode 600; only the proxy and the VM read them |
| Sessions | `~/.fleet`; each turn's errors in `~/.fleet/sessions/<sid>/stderr-N.log` |
| Code | branch `fleet/<sid>` in the repo you picked |

## 1. Homebrew, container, jq

```sh
xcode-select --install          # skip if already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install container jq
container system start
```

Check: `container system status` succeeds.

## 2. Repo

```sh
mkdir -p ~/src && git clone https://github.com/TanGentleman/tan-toolchains ~/src/tan-toolchains
echo "alias pic=$HOME/src/tan-toolchains/pi-container/run.sh" >> ~/.zshrc
alias pic=$HOME/src/tan-toolchains/pi-container/run.sh
cd ~/src/tan-toolchains/pi-container
```

Every later step runs from this folder.

## 3. Test and build

```sh
./test/run-tests.sh       # ends: run-tests.sh: all tests passed
./build.sh full           # pi-full:local; the first build takes a while
./build.sh fleet          # fleet's tests (ok per package), then fleet/bin/fleetd
file ../fleet/bin/fleetd  # Mach-O 64-bit executable arm64
../fleet/bin/fleetd -version  # the commit it was built from; -dirty if the tree was not clean
```

`build.sh fleet` runs fleet's vet and tests, then the build, in a Go image
pinned by digest, with nothing downloaded but that image. A failing test
prints `FAIL` and builds nothing.

## 4. Keys

Make a GitHub **fine-grained** token (Settings → Developer settings →
Fine-grained tokens) for the repos agents may push to, with the scope in
[configuration.md](../../pi-container/docs/configuration.md#host-env-file):
Contents: Read and write, nothing else. The token is inside the VM, so
anything a turn runs can use it.

```sh
mkdir -p ~/.config/pi-container
printf 'OPENROUTER_API_KEY=\nGITHUB_TOKEN=\nGIT_AUTHOR_NAME=\nGIT_AUTHOR_EMAIL=\n' > ~/.config/pi-container/env
chmod 600 ~/.config/pi-container/env
open -e ~/.config/pi-container/env      # fill in the four values, save
pic check you/your-repo
```

Check: `pic check` passes. It shows Pi has the placeholder key, OpenRouter
and GitHub answer, and `example.com` and direct connections are blocked.

Don't `export OPENROUTER_API_KEY` in your shell; `pic serve` refuses to
start if it is set.

## 5. Tailscale

1. Install the app from https://tailscale.com/download/macos and open it.
   Allow the VPN configuration and turn on its network extension (System
   Settings → General → Login Items & Extensions → Network Extensions).
   Log in **as yourself**, not with a tagged auth key.
2. Menu bar icon → Settings → CLI integration → install. Check:
   `tailscale version`.
3. In the admin console's DNS page (https://login.tailscale.com/admin/dns),
   enable **MagicDNS** and **HTTPS Certificates**.

## 6. Serve

```sh
pic serve --check       # one ok/FAIL line per check, then: pic serve: ready
caffeinate -i ~/src/tan-toolchains/pi-container/run.sh serve
```

That runs `pic serve` and keeps the Mac from idle-sleeping (`caffeinate`
needs the full path; it can't run the `pic` alias). It runs `fleetd` and
`tailscale serve` in the foreground; Ctrl-C stops both. A closed laptop lid
still sleeps the Mac.

In a **second terminal**, paste these helpers. Later steps use them; paste
them again in any new terminal.

```sh
cd ~/src/tan-toolchains/pi-container
URL=https://$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')
sessions() { curl -sS --fail-with-body "$URL/v1/sessions" | jq -r '.[] | .sid + "  " + (.title // "")'; }
st() { curl -sS --fail-with-body "$URL/v1/sessions/${1:?usage: st SID}" | jq '{repo, branch, base, commit, running}'; }
# GitHub API with the token from the env file (passed on stdin, not in ps):
ghapi() { sed -n 's/^GITHUB_TOKEN=/Authorization: Bearer /p' ~/.config/pi-container/env |
  curl -sS --fail-with-body -H @- -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$1"; }
tip() { ghapi "$1/git/ref/heads/$2" | jq -r .object.sha; }                                  # tip REPO BRANCH
ghcat() { ghapi "$1/contents/$3?ref=$2" | jq -r '.content | gsub("\n"; "") | @base64d'; }   # ghcat REPO BRANCH PATH
```

Check:

```sh
curl -sS --fail-with-body "$URL/v1/node" | jq .harnesses   # ["pi-ctr"]
curl -sS --fail-with-body "$URL/v1/node" | jq .config      # {"image":"full","egress":"standard","model_url":"openrouter"}
```

Every turn uses the image, egress and model_url in
`~/.config/pi-container/config.json`, or the defaults above; `pic config`
prints them with their source. fleetd reads the file on each `GET /v1/node`;
turns read it when they start, so no restart is needed after an edit.

The first request to a new Tailscale name can fail TLS for a few seconds
while the certificate is issued; repeat it.

## 7. Spawn from the phone

Open `$URL` on the phone, with Tailscale on, and fill in:

- **repo**: `you/your-repo`, one the token can push to. Empty makes a
  scratch session: nothing Pi writes survives the turn.
- **branch**: where the first turn starts; empty means the default branch.
- **model**: empty uses `settings.json`'s default.
- **prompt**

A session's id (`sid`) is the part of the page's URL after `#`; `sessions`
lists them. Check, after the first turn ends:

```sh
sid=s0123456789abcdef            # yours
st $sid                          # running false, commit set
tip you/your-repo fleet/$sid     # the same commit
```

## 8. Verify before relying on it

Once per new Mac, and before calling a branch stable. Use a private
throwaway repo with a README, added to the token's repos. Every check is a
blocker if it fails.

```sh
REPO=you/fleet-e2e
```

**Scripted.** With `pic serve` up:

```sh
./test/fleet-e2e.sh $REPO     # a release runs it as: test/release.sh fleet --repo $REPO
```

Set `PI_CONFIG_DIR` (or `PI_ENV_FILE`) as for `pic serve`: the token comes
from that profile's env file.

It runs real turns through `$URL` and checks the results on GitHub with the
env file's token. Each line is a blocker:

- isolation: `fleet-isolation.sh` blocks every Mac, tailnet, DNS and internet
  probe from a turn's VM;
- turn: `base` is main's tip, `commit` is `fleet/$sid`'s tip with `hello.txt`;
- follow-up: Pi remembers the first turn; the new commit's parent is the first;
- fork: the fork's `base` is the parent's `commit`;
- abort: `aborted`, branch unchanged, no `fleet-$sid` container, the next
  prompt runs;
- refusals: a workflow change and a token-shaped string in a file are `push refused`, branch
  unchanged. If Pi declined to run the command, rerun.

`release.sh fleet` adds: fleetd was built from the commit, the key is not in
its environment, it listens on loopback only, and during the turns the proxy
saw only OpenRouter and GitHub and refused nothing.

**By hand.**

- [ ] Scratch: spawn with repo empty and `Create note.txt containing hi`, then
      send `Run ls.`: Pi remembers the first turn, and `note.txt` is gone.
- [ ] Send `Run sleep 120 in bash`, then `kill -9 "$(pgrep -f 'fleetd -listen')"`.
      `pic serve` exits; within a few seconds `container ls` has no
      `fleet-$sid` and `pgrep -f pi-ctr` prints nothing.
- [ ] Start `pic serve` again (step 6). The session's last event says
      `node restarted`, and the next prompt continues the conversation and
      `fleet/$sid`.
- [ ] Ctrl-C `pic serve`: `tailscale serve status` shows nothing and
      `container ls` has no `fleet-` container.

**Offline, min image.** A local model server on this Mac at gateway port
8090 (OpenAI-compatible `/v1` and `/health`), `./build.sh min` done, and
`pic serve` stopped:

```sh
cfg=~/.config/pi-container/config.json
[ -e $cfg ] && cp $cfg $cfg.bak
printf '{"v":1,"image":"min","egress":"offline","model_url":"http://gateway:8090"}\n' > $cfg
pic config                       # min/offline/http://gateway:8090, each "file"
pic serve --check                # ok config: image min, egress offline ...; no GITHUB_TOKEN needed
```

- [ ] Start `pic serve`. `curl -sS "$URL/v1/node" | jq .config` prints
      `{"image":"min","egress":"offline","model_url":"http://gateway:8090"}`.
- [ ] Spawn a scratch session (repo empty) with `Say hi`. It answers from
      the local model; `~/.fleet/sessions/$sid/stderr-1.log` shows
      `image=pi-min:local pack=min` and `egress=offline`.
- [ ] Spawn with a repo: the turn fails with `egress offline has no GitHub
      route, so --clone cannot clone`.
- [ ] Stop `pic serve`, then restore: `mv $cfg.bak $cfg` (or `rm $cfg` if
      there was none).

**Optional.** With a second tailnet login, `$URL` answers 403 from a device
logged in as it. And each of these makes `pic serve --check` print a `FAIL`
line (restore each after): Tailscale logged out, HTTPS certificates off,
`container system stop`, `chmod 644` on the env file, `GITHUB_TOKEN`
removed, `OPENROUTER_API_KEY=x pic serve --check`.

| Where | Checks | Needs |
|---|---|---|
| CI, every push | fleet's Go tests with real Pi behind `proxy.py`, `fleet/e2e/pi-ctr.sh`, pic's script tests | nothing |
| Step 3 | pic's script tests; fleet's Go tests in the Go image | `container`, `jq` |
| Step 4 | the real VM, proxy and egress lock | key, token |
| Step 6 | Tailscale, certificates, image, keys, port | Tailscale |
| Step 8 | `fleet-e2e.sh`: isolation, turns, fork, abort, GitHub refusals; by hand: scratch, crash cleanup | `$REPO` |

## 9. Upgrade or remove

```sh
cd ~/src/tan-toolchains && git pull && cd pi-container && ./build.sh full && ./build.sh fleet
```

Then restart `pic serve`. After a Pi version change, `pic check` warns until
`~/.config/pi-container/settings.json` matches: delete it (if you haven't
edited it) and `pic` writes a new one.

To remove: stop `pic serve`, then delete `~/.fleet` (every session) and
`~/.config/pi-container/env`.

## Troubleshooting

Rerun a failing `curl` with `-sS -i` and without `jq`: the status line and
body say what's wrong.

| Symptom | Cause |
|---|---|
| `caffeinate: pic: No such file or directory` | `caffeinate` can't run an alias; use the full path (step 6). |
| `pic serve` prints `FAIL` lines | Each says what to fix. |
| `404 page not found` | The path is wrong; usually `$sid` is empty or starts with `#`. |
| `no such session` | `$sid` isn't in `sessions`. |
| `jq: parse error` | The reply is an error, not JSON (see above). |
| `401` / `no tailnet identity` | The request skipped `tailscale serve`; use `$URL`, not `127.0.0.1:7433`. |
| `403` | Your login isn't an `-owner`. |
| `421 unexpected Host` | A `-url` you passed doesn't match the name you used. Drop it. |
| `409` on input | A turn is running; wait for it, or Abort. |
| `push refused: ...` | The session's last event says why. |
| `cannot check out fleet/<sid>` or `cannot fetch base` | The token can't read the repo, or the base commit was force-pushed away. |
| Turn fails before Pi starts | `~/.fleet/sessions/<sid>/stderr-N.log` has `run.sh`'s message. |
| Turn exits 3 | Pi's saved session is gone or changed; fork from an earlier turn. |
| A session shows `Unreadable` | Another `fleetd` version wrote its log. It's skipped and left as is; move `~/.fleet/sessions/<sid>` out to clear it. |
| `fleet-<sid>` in `container ls` after a crash | Start `pic serve` again; it stops the leftover first. |
| `ghapi` says `Bad credentials` or `Not Found` | The token is wrong, or the repo isn't in its list. |
| Unreachable from the phone | The Mac is asleep or `pic serve` isn't running. |

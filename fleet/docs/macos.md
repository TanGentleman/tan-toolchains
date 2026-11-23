# fleet on macOS, every step

From a clean Mac to `fleetd` running Pi, Claude Code and Codex through
OpenRouter, reachable from your phone over Tailscale. It runs in a terminal
by default; starting it at login with launchd is optional.
Then a second Mac as a peer, handoff, and the test suites.

Run each block in Terminal (zsh), in order. Lines starting with `#` are
comments. Each step ends with a check; do not go on until it passes.
Assumes Apple silicon (`/opt/homebrew`); on Intel replace `/opt/homebrew`
with `/usr/local`.

## Before you start

- A Mac you can log in to as an admin (Homebrew and Tailscale ask for the password).
- About an hour. Steps 1-5 need no accounts and no key.
- An [OpenRouter](https://openrouter.ai) key, from step 6 on.
- A [Tailscale](https://tailscale.com) account, from step 8 on. Free is enough.
- Optional: a second Mac for step 10.

What has been run on a Mac: steps 1-5 and 7 on a clean Apple silicon Mac
(macOS 26.6.2) with a placeholder key, before `fleet/macos/` existed. Not yet
run on a Mac: the `fleet/macos/` scripts (`e2e/macos.sh` tests them against
fake `launchctl`, `plutil` and `tailscale`), the live check in step 6, steps
8-10 (real tailnet), and step 12.

| Step | Needs | Gets you |
|---|---|---|
| 1-5 | nothing | `fleetd` built and its tests passing |
| 6-7 | OpenRouter key | real sessions on this Mac |
| 8-9 | Tailscale | `fleetd` reachable from your phone, in the foreground or as a login service |
| 10 | a second Mac | handoff and fork between Macs |
| 11 | - | the real key kept out of `fleetd` and the agents |
| 12 | - | Pi's tool calls in a Linux sandbox (experimental) |

## 0. What you end up with

| Thing | Where |
|---|---|
| Repo | `~/src/tan-toolchains` |
| `fleetd` binary | `~/.local/bin/fleetd` |
| Agent CLIs (pinned) | `~/fleet-tools/node_modules/.bin/{pi,claude,codex}` |
| OpenRouter key | `~/.config/fleet/env`, mode 600, read only by the launcher |
| Session data | `~/.fleet` |
| Launch scripts | `~/src/tan-toolchains/fleet/macos/` (`fleetd-run`, `fleet-up`, `service.sh`) |
| Optional service | `~/Library/LaunchAgents/dev.fleet.fleetd.plist` (step 9, only with `service.sh`) |
| Logs | the terminal running `fleet-up`; with the service, `~/Library/Logs/fleetd.log` |

## 1. Command-line tools and Homebrew

```sh
xcode-select --install          # skip if it says already installed
# Homebrew (https://brew.sh):
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
brew --version
```

Check: `brew --version` prints a version. `brew shellenv` must be in
`~/.zprofile` or new Terminal windows will not find `brew`.

## 2. Go, Node, Python, jq

`fleet/go.mod` needs Go 1.27.4 or newer. `proxy.py` (step 5's proxy test and
step 11) needs Python 3.11 or newer; the Mac's `/usr/bin/python3` is 3.9.

```sh
brew install go node@24 python@3.12 jq
echo 'export PATH="/opt/homebrew/opt/python@3.12/libexec/bin:/opt/homebrew/opt/node@24/bin:$HOME/.local/bin:$PATH"' >> ~/.zprofile
source ~/.zprofile
go version        # go1.27.4 or newer
node --version    # v24.x
python3 --version # 3.12.x
```

If Homebrew's Go is older than 1.27.4, `go` downloads the right toolchain on
first build (one request to `proxy.golang.org`). To avoid that, install
`go1.27.4.darwin-arm64.pkg` from https://go.dev/dl/ instead.

## 3. The agent CLIs, pinned

These are the versions the tests pass against. Installed into one folder,
not globally, so upgrades are deliberate.

```sh
mkdir -p ~/fleet-tools
npm install --prefix ~/fleet-tools --no-fund --no-audit \
  @earendil-works/pi-coding-agent@1.6.0 @anthropic-ai/claude-code@2.1.330 @openai/codex@0.171.0
ls ~/fleet-tools/node_modules/.bin/     # includes pi, claude, codex
~/fleet-tools/node_modules/.bin/codex --version
```

Do not log in to any of them. fleet gives each session its own config home
and points the CLI at OpenRouter; host logins are never read.

## 4. Repo and build

```sh
mkdir -p ~/src && cd ~/src
git clone https://github.com/TanGentleman/tan-toolchains.git
cd tan-toolchains
git checkout devin/1795320800-fleet-pi-errors   # until merged; then stay on main
cd fleet
go build -o ~/.local/bin/fleetd ./cmd/fleetd
fleetd -h 2>&1 | head -3
```

Check: `which fleetd` prints `~/.local/bin/fleetd` (step 2 put
`~/.local/bin` on `PATH`).

## 5. Tests (no key needed)

```sh
cd ~/src/tan-toolchains/fleet
export PATH="$HOME/fleet-tools/node_modules/.bin:$PATH"
test -z "$(gofmt -l .)" && echo fmt ok
go vet ./...
go test -race -count=1 ./...
bash e2e/smoke.sh                     # prints: smoke: ok (s...)
bash e2e/macos.sh                     # prints: macos: ok (fake launchctl/tailscale)
go test -count=1 -v -run 'TestResumeOnAnotherNode|TestFleetHandoff|TestBehindV5Proxy' ./agent
```

The `agent` tests run the real CLIs against a fake OpenRouter on loopback and
fail if any CLI tries to reach any other host. Each subtest should say
`PASS`, not `SKIP`; a `SKIP` means that CLI is not on `PATH`.

Check: every command above ends without `FAIL`, and `smoke.sh` prints
`smoke: ok`.

## 6. OpenRouter key

Typed at a hidden prompt so it is not in shell history:

```sh
mkdir -p ~/.config/fleet && chmod 700 ~/.config/fleet
read -rs "k?OpenRouter key: "; echo
printf 'OPENROUTER_API_KEY=%s\n' "$k" > ~/.config/fleet/env; unset k
chmod 600 ~/.config/fleet/env
cat >> ~/.config/fleet/env <<'X'
FLEET_MODEL=deepseek/deepseek-v4.1-flash
FLEET_CLAUDE_MODEL=anthropic/claude-haiku-4.5
FLEET_CODEX_MODEL=openai/gpt-5.1-codex-mini
X
```

Check: `ls -l ~/.config/fleet/env` shows `-rw-------`, and
`grep -c OPENROUTER_API_KEY ~/.config/fleet/env` prints `1`.

`FLEET_MODEL` is the default for every harness; `FLEET_<KIND>_MODEL`
overrides it per CLI; a `model` given at spawn overrides both.

Live check (costs a few cents, talks only to openrouter.ai):

```sh
cd ~/src/tan-toolchains/fleet
set -a; source ~/.config/fleet/env; set +a
FLEET_LIVE=1 go test -count=1 -v -run 'TestLive' ./agent
unset OPENROUTER_API_KEY
```

## 7. Run it by hand first

`fleet/macos/fleetd-run` loads `~/.config/fleet/env` and sets `PATH` so the
CLIs and `node` are found, then runs `~/.local/bin/fleetd`.

```sh
~/src/tan-toolchains/fleet/macos/fleetd-run -name mac1 -url http://127.0.0.1:7433 -owner me@local
```

In a second tab, talk to it the way `tailscale serve` will, by setting the
identity header yourself:

```sh
H='Tailscale-User-Login: me@local'
curl -s -H "$H" http://127.0.0.1:7433/v1/node | jq
sid=$(curl -s -H "$H" -H 'Content-Type: application/json' -X POST http://127.0.0.1:7433/v1/sessions \
  -d '{"harness":"claude","title":"hello","key":"k1","prompt":"Say hi in five words."}' | jq -r .sid)
echo $sid
curl -sN -H "$H" -H 'Accept: text/event-stream' "http://127.0.0.1:7433/v1/sessions/$sid/events"   # Ctrl-C when done
curl -s -H "$H" "http://127.0.0.1:7433/v1/sessions/$sid" | jq '{running, run, model, writer}'   # model null = harness default
curl -s -H "$H" -H 'Content-Type: application/json' -X POST "http://127.0.0.1:7433/v1/sessions/$sid/inputs" \
  -d '{"key":"i1","text":"What did you just say?"}'
curl -s -H "$H" http://127.0.0.1:7433/v1/sessions | jq '.[] | {sid, title, usage}'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7433/v1/node    # 401: no header, no access
```

Open http://127.0.0.1:7433 in a browser only after step 9; without the header
the UI gets 401. Stop the hand-run `fleetd` with Ctrl-C.

## 8. Tailscale

1. Install the standalone app from https://tailscale.com/download/macos
   (or `brew install --cask tailscale-app`) and open it. Allow the VPN
   configuration, then turn on the Tailscale network extension under System
   Settings → General → Login Items & Extensions → Network Extensions (it asks
   for your password). Then log in.
2. Menu bar icon → Settings → CLI integration → install, so `tailscale` is
   on `PATH`. Check: `tailscale version`.
3. Admin console → DNS (https://login.tailscale.com/admin/dns): enable
   MagicDNS and HTTPS Certificates. `tailscale serve` needs both.
4. Find this Mac's name and your login:

```sh
tailscale status --json | jq -r '.Self.DNSName'                              # mac1.your-tailnet.ts.net.
tailscale status --json | jq -r '.User[(.Self.UserID|tostring)].LoginName'   # you@github
```

## 9. Serve it on the tailnet

Replace `you@github` and the host name with the values from step 8.

```sh
ME=you@github
URL=https://mac1.your-tailnet.ts.net
F=~/src/tan-toolchains/fleet/macos
caffeinate -i $F/fleet-up -name mac1 -url "$URL" -owner "$ME"
```

`fleet-up` runs `fleetd` and `tailscale serve --https=443` (without `--bg`)
in the foreground, in a terminal tab or tmux. Ctrl-C stops both. The serve
config belongs to that `tailscale` process, so when it exits nothing keeps
forwarding to port 7433. `caffeinate -i` stops the Mac idle-sleeping while it
runs; closing a laptop's lid still sleeps it, and a sleeping Mac can't be
reached. After rebuilding `fleetd` or editing the env file, Ctrl-C and run it
again; a running turn is stopped with SIGTERM and its session keeps the last
checkpoint.

Check, from any tailnet device: `curl -s "$URL/v1/node" | jq` shows your
login as `"you"`. Open `https://mac1.your-tailnet.ts.net` on your phone
(Tailscale app on).

### Optional: start at login with launchd

Only if `fleetd` should come up without a terminal. `service.sh` writes a
per-user LaunchAgent (no root) and a persistent `tailscale serve --bg`:

```sh
$F/service.sh install -- -name mac1 -url "$URL" -owner "$ME"
$F/service.sh status                                    # state = running, the serve config, the log tail
launchctl kickstart -k gui/$(id -u)/dev.fleet.fleetd    # restart after rebuilding fleetd or editing env
$F/service.sh uninstall                                 # removes the plist and fleet's 443 serve entry only
```

What to know about it:

- The serve entry persists in Tailscale's config across reboots and keeps
  forwarding `https://mac1...` to port 7433, identity header included, even
  while `fleetd` is stopped. `uninstall` removes it with
  `tailscale serve --https=443 off`. It never runs `tailscale serve reset`,
  and `install` refuses if something else already serves port 443.
- launchd restarts `fleetd` only when it exits non-zero, at most once a
  minute. A bad flag or a broken env file shows in the log once a minute
  until you fix it; change flags with `uninstall` then `install`.
- The log is `~/Library/Logs/fleetd.log`; `fleetd-run` moves it to
  `fleetd.log.1` at start once it passes 10 MB.
- launchd does not keep the Mac awake. To serve while asleep on the charger,
  `sudo pmset -c sleep 0`.
- macOS shows an "App Background Activity" notice for `fleetd-run`; it is
  listed under System Settings → General → Login Items & Extensions.
  Turning it off there stops launchd from starting `fleetd`.

Let a friend use it: add `-spawner friend@github` to the `fleet-up` (or
`service.sh install`) flags. That gives them a shell on this Mac as you,
and your OpenRouter key: a turn runs whatever the agent is asked. A `steer`
share of a session is the same for that session; `view` is read only.
Any process on this Mac can also call `127.0.0.1:7433` with your login,
agents included (see "What access means" in the README). Share one session
instead:

```sh
curl -s -H 'Content-Type: application/json' -X POST "$URL/v1/sessions/$sid/share" -d '{"user":"friend@github","level":"view"}'
```

## 10. A second Mac: copies, handoff, fork

Repeat steps 1-9 on the second Mac with `-name mac2`, its own `-url`, and
`-peer https://mac1.your-tailnet.ts.net` added to its flags.
Add `-peer https://mac2...` on mac1 too if you want copies both ways.

```sh
A=https://mac1.your-tailnet.ts.net B=https://mac2.your-tailnet.ts.net
J='Content-Type: application/json'
curl -s "$B/v1/sessions" | jq '.[].sid'                                     # mac1's sessions appear on mac2
curl -s -H "$J" -X POST "$B/v1/sessions/$sid/resume" -d "{\"from\":\"$A\"}"  # mac2 becomes the writer
curl -s -H "$J" -X POST "$B/v1/sessions/$sid/inputs" -d '{"key":"i2","text":"Continue."}'
curl -s "$A/v1/sessions/$sid" | jq .writer                                  # "mac2"
# mac2 unreachable? fork from the newest checkpoint mac1 holds:
curl -s -H "$J" -X POST "$A/v1/sessions/$sid/fork" -d '{"key":"f1"}'
```

Both Macs need the same CLIs (step 3) and a key file (step 6); the key never
leaves the machine it is on.

## 11. Optional: keep the real key out of fleetd

Run `pi-container/proxy.py` on loopback with the real key, and give `fleetd`
only the placeholder. On a bare Mac this hides the key from the agents; it
is not a network sandbox (they can still reach other hosts directly if they
ignore the proxy settings).

```sh
mkdir -p ~/.config/fleet/proxy && chmod 700 ~/.config/fleet/proxy
grep '^OPENROUTER_API_KEY=' ~/.config/fleet/env > ~/.config/fleet/proxy/proxy.env
chmod 600 ~/.config/fleet/proxy/proxy.env
P=~/.config/fleet/proxy
PI_ENV_FILE=$P/proxy.env PI_PROXY_PORT=8888 PI_PROXY_BIND=127.0.0.1 PI_PROXY_LOCKED_CIDR=127.0.0.0/8 \
PI_PROXY_CERT=$P/openrouter.pem PI_PROXY_KEY=$P/openrouter.key PI_PROXY_CA=$P/ca.pem PI_PROXY_ADDR_FILE=$P/proxy.addr \
  python3 ~/src/tan-toolchains/pi-container/proxy.py
```

Then in `~/.config/fleet/env` replace the key line and add the proxy:

```sh
OPENROUTER_API_KEY=sk-or-v1-placeholder
HTTPS_PROXY=http://127.0.0.1:8888
HTTP_PROXY=http://127.0.0.1:8888
NO_PROXY=localhost,127.0.0.1,::1
SSL_CERT_FILE=/Users/YOU/.config/fleet/proxy/ca.pem
NODE_EXTRA_CA_CERTS=/Users/YOU/.config/fleet/proxy/ca.pem
```

Restart `fleet-up` (or `launchctl kickstart -k gui/$(id -u)/dev.fleet.fleetd`), then spawn a session
and watch the proxy print `openrouter POST /api/v1/...` with no `deny` or
`allow` lines.

## 12. Optional: run Pi's tools in a sandbox (experimental)

Adds a harness, `pi-sbx`, where Pi runs on the Mac but every command and
file edit it makes runs in a throwaway Linux guest
([external-sandbox-v86](https://github.com/prime-radiant-inc/external-sandbox-v86))
that sees only the session's working folder and has no network. Pi's own
tools are turned off, so if the sandbox does not start the turn fails
instead of running on the Mac. Why and what it does not cover:
[sandbox.md](sandbox.md). Not yet run on a Mac; `pi` stays the default.

```sh
npm install --prefix ~/fleet-tools --no-fund --no-audit external-sandbox-v86@0.4.0 external-sandbox-pi@0.1.0
cd ~/src/tan-toolchains/fleet
export PATH="$HOME/fleet-tools/node_modules/.bin:$PATH"
FLEET_SANDBOX_DIR=~/fleet-tools bash e2e/sandbox.sh      # prints: sandbox: ok (s...)
```

The first run downloads nothing more; the Linux image ships in the npm
package. A one-call turn takes about 15 s because the guest boots each turn.

Then tell `fleetd-run` where things are and register the harness:

```sh
cat >> ~/.config/fleet/env <<X
FLEETD=$HOME/.local/bin/fleetd
FLEET_SANDBOX_PI_EXT=$HOME/fleet-tools/node_modules/external-sandbox-pi/src/index.ts
X
```

Add `-harness pi-sbx=$HOME/src/tan-toolchains/fleet/sandbox/pi-v86.sh -harness-key pi-sbx`
to the `fleet-up` flags (step 9) and restart it; with the service, `uninstall`
and `install` again with the new flags. `-harness-key` is needed because the
script's Pi needs the key; the sandbox server it starts doesn't get it.
Spawn with `"harness":"pi-sbx"`.
A peer that should resume these sessions needs the same install.

Check: `curl -s "$URL/v1/node" | jq .harnesses` lists `pi-sbx`.

## 13. Upgrading and removing

```sh
cd ~/src/tan-toolchains && git pull && cd fleet && go build -o ~/.local/bin/fleetd ./cmd/fleetd
# Restart fleet-up, or with the service: launchctl kickstart -k gui/$(id -u)/dev.fleet.fleetd
# New CLI versions: change the pins in step 3, rerun step 5 before restarting.

# Set up with an older version of this guide (hand-written plist, `serve --bg 7433`)?
launchctl bootout gui/$(id -u)/dev.fleet.fleetd; rm -f ~/Library/LaunchAgents/dev.fleet.fleetd.plist
tailscale serve --https=443 off        # then use fleet-up, or service.sh install

~/src/tan-toolchains/fleet/macos/service.sh uninstall   # only if you installed the service
rm ~/.local/bin/fleetd ~/.local/bin/fleetd-run 2>/dev/null   # fleetd-run only exists from older versions of this guide
rm -rf ~/fleet-tools ~/.config/fleet     # ~/.fleet holds every session; delete it only if you mean it
```

## Troubleshooting

| Symptom | Check |
|---|---|
| `421 unexpected Host` | `-url` is not the name you used to reach it; it must match `tailscale status`'s DNS name. |
| `415` on POST | Send `Content-Type: application/json`. |
| `401` everywhere | No `Tailscale-User-Login`: go through `tailscale serve`, or set the header with curl on the Mac itself. |
| `403` | Your login is not `-owner`/`-spawner` and the session is not shared with you. |
| `409` on input | A turn is still running; wait for `exited`, or `POST .../abort`. |
| Turn fails with `executable file not found` in stderr | `PATH` in `fleetd-run` lacks `~/fleet-tools/node_modules/.bin` or Node. |
| Turn exits 1, `OPENROUTER_API_KEY is not set` | Key file missing or not readable by `fleetd-run`. |
| `proxy: needs Python 3.11 or newer` | `python3` is the Mac's 3.9; see step 2. |
| Turn exits 3 | The CLI's saved session is gone or changed; fork from an earlier checkpoint. |
| `tailscale serve` refuses | HTTPS Certificates are off in the admin console (step 8.3). |
| `pi-v86: sandbox exited` or `not ready` in `stderr-N.log` | Run `external-sandbox-v86 --mount-rw w=/tmp` by hand and read its output; Node must be 22.19 or newer. |
| `pi-v86: no extension at ...` | `FLEET_SANDBOX_PI_EXT` in `~/.config/fleet/env` is wrong; see step 12. |
| Service not running | `service.sh status`, then `~/Library/Logs/fleetd.log`. |
| Unreachable from the phone | The Mac is asleep, `fleet-up` was stopped, or the service isn't installed. |

# tan-toolchains

Run Pi agents in Apple `container` VMs on your Mac, each locked to a proxy that
allows only GitHub and OpenRouter, and start them from your phone.

## Setup

You need an Apple silicon Mac on macOS 26 and an OpenRouter key. This table is
everything the Mac itself needs; the images build every other tool, so there
is no Homebrew, Node, Zig or Go to install for normal use.

| What | Needed for | Install |
|---|---|---|
| Command Line Tools (`git`, `python3`) | cloning, `run-tests.sh` | `xcode-select --install` |
| Apple [`container`](https://github.com/apple/container/releases) | every VM | the signed `.pkg` below, once per Mac (admin); `container system start` in each account |
| `jq` | `run.sh`, `clear.sh`, tests | nothing: macOS 26 has `/usr/bin/jq` |
| [Tailscale](https://tailscale.com/download/macos) | fleet only | the app ([fleet step 5](fleet/docs/macos.md#5-tailscale)) |
| [uv](https://docs.astral.sh/uv/) | `spikes/local-model` only | `curl -LsSf https://astral.sh/uv/install.sh \| sh` (per account, no admin) |
| Zig at the `ZIG_VERSION` pin (0.17.0); Go optional | `mac-e2e.sh ci` only, when changing the repo | [ziglang.org/download](https://ziglang.org/download/), [go.dev/dl](https://go.dev/dl/) |

```sh
xcode-select --install                      # skip if `git --version` works
V=1.7.1                                     # or the newest at github.com/apple/container/releases
curl -fLo /tmp/container.pkg "https://github.com/apple/container/releases/download/$V/container-$V-installer-signed.pkg"
sudo installer -pkg /tmp/container.pkg -target /   # puts container in /usr/local/bin for every account
container system start
```

Upgrade in place (volumes and images stay):

```sh
pi-container/clear.sh export                  # backup of every pi volume, without auth.json
container system stop && /usr/local/bin/update-container.sh && container system start
container system kernel set --recommended    # otherwise VMs keep booting the old kernel
container builder delete --force && container delete --force pi-proxy
pi-container/test/migrate-check.sh            # no FAIL lines; compares volumes with the export
```

[container-1.7.1.md](pi-container/docs/container-1.7.1.md) has what changed
from 1.6.1 and a full reinstall that keeps sessions and config. Homebrew's
`container` formula is the same CLI and also works, but use one source, not both. The `.pkg` is preferred because it
is on every account's `PATH`; `brew` in a second account is not, and only
the admin who owns `/opt/homebrew` can install with it.

Start with the [playbooks](docs/playbooks.md): setup once, then Pi on a
repo, several chats from your phone on the `min` image, or offline with a
local model.

## Docs

- [pi-container/README.md](pi-container/README.md): setup, use, limits, and its own docs index.
- [fleet/docs/macos.md](fleet/docs/macos.md): fleet setup on a Mac, with a check per step.
- [fleet/README.md](fleet/README.md): model, API, tests, and what is left out.

Layout: `pi-container/` and `fleet/` are the above. `enforcer/` (a Pi prompt
hook) is built into every image; `zigpeek/` (Zig docs for Pi) into the
opt-in `zig` image.
Working on the repo: [AGENTS.md](AGENTS.md).

## Network boundary

Pi's VM runs behind the egress lock in pi-container's normal mode, `run.sh
check`, and fleet turns.

- **Allowed:** `pi-proxy` only, with an egress profile set in
  `PI_EGRESS` or `--egress`
  ([configuration](pi-container/docs/configuration.md#run-settings)):
  - `standard` (default): it tunnels GitHub and sends model calls (Pi's
    `openrouter.ai` requests) to openrouter.ai with the real key, or, with an
    http `model_url` such as `http://gateway:8090`, to that server (e.g. a
    local model on this Mac) with a placeholder key. Every other host is
    refused.
  - `offline`: it refuses GitHub and openrouter.ai, sends model calls only to
    `model_url` (on `gateway` or a private IPv4 address, required), and Pi
    gets no GitHub token.

  - your own, `$PI_CONFIG_DIR/egress/NAME.json`: the hosts it tunnels,
    whether model calls must stay private, and whether Pi gets the GitHub
    token ([egress profiles](pi-container/docs/configuration.md#egress-profiles)).

  Pi cannot reach the Mac directly under any profile; the egress lock is the same.
- **Blocked:** the Mac and its services (for example Continuity's
  `rapportd`), Tailscale's DNS resolver at `100.100.100.100` and with it your
  tailnet names, the tailnet, and the internet, over IPv4 and IPv6.
- **How:** the VM is on the host-only `pi-locked` network, which alone still
  reaches the Mac and Tailscale's resolver. Before anything else runs,
  iptables inside the VM (`pi-container/lib/netlock.sh`) allows only loopback
  and the proxy's port; then `NET_ADMIN` and `NET_RAW` are dropped, so nothing
  Pi starts can change the rules. An image without the `netlock` capability is
  refused.
- **Limit:** the lock trusts the VM's kernel. A kernel exploit could remove
  the rules.
- **Unlocked modes:** `--manual` (a shell without Pi) and `--allow-egress` (Pi
  with the real key) use the container's default network with no lock and no
  proxy. They reach any host and protocol, including the Mac's services and
  Tailscale's resolver.
- **Checks:** `run.sh check` and `pi-container/test/fleet-isolation.sh`
  confirm the lock from inside a VM.

Shipped tools run on macOS and make no network requests. A separate process
owns any network layer; `fleetd` is that process for fleet, loopback-only
behind `tailscale serve`.

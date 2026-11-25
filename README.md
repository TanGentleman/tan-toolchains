# tan-toolchains

Run Pi agents in Apple `container` VMs on your Mac, each locked to a proxy that
allows only GitHub and OpenRouter, and start them from your phone.

## Setup

You need an Apple silicon Mac on macOS 26 with Homebrew, `container` and `jq`,
and an OpenRouter key. Nothing else goes on the Mac: no Zig, Go or Node; the
images build everything.

- Pi in a VM: [pi-container setup](pi-container/README.md#setup).
- Pi sessions from your phone, which adds Tailscale:
  [fleet on macOS](fleet/docs/macos.md), every step with a check.

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

- **Allowed:** `pi-proxy` only. It tunnels GitHub, adds the OpenRouter key
  for `openrouter.ai`, and refuses every other host. With
  `PI_PROXY_OPENROUTER_HOST` set (`spikes/inkling-2-mini/pi.sh`), it sends
  those model calls to that host instead, such as a model server on this Mac;
  Pi still cannot reach the Mac directly.
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

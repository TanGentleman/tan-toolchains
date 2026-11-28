# Network boundary

What Pi's VM can reach, and how. Pi's VM runs behind the egress lock in
pi-container's normal mode, `run.sh check`, and fleet turns.

- **Allowed:** `pi-proxy` only, with an egress profile set in
  `PI_EGRESS` or `--egress`
  ([configuration](../pi-container/docs/configuration.md#run-settings)):
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
    token ([egress profiles](../pi-container/docs/configuration.md#egress-profiles)).
  - any of these plus `PI_EXTRA_TUNNEL` hosts, tunnelled the same way
    ([extra tunnel hosts](../pi-container/docs/configuration.md#extra-tunnel-hosts)).

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
  Tailscale's resolver ([manual mode](../pi-container/docs/manual.md),
  [egress mode](../pi-container/docs/egress.md)).
- **Checks:** `run.sh check` and `pi-container/test/fleet-isolation.sh`
  confirm the lock from inside a VM.

Shipped tools run on macOS and make no network requests. A separate process
owns any network layer; `fleetd` is that process for fleet, loopback-only
behind `tailscale serve`.

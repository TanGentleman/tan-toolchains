# Egress mode

`--allow-egress` runs Pi, or a trailing command, on the container's default
network instead of the host-only `pi-locked` network. It is the only mode where
the agent VM has unrestricted egress: no egress lock, no proxy, no allowed-host
list, no CA, any host and any protocol. That includes your Mac's services and
Tailscale's resolver at `100.100.100.100`, which answers your tailnet names and
forwards other names to the internet ([network boundary](../../docs/network-boundary.md)). Use it when the proxy's allowlist is too narrow, such as
for package-manager downloads, release assets, or a model endpoint the proxy
does not MITM.

There is no proxy to add the OpenRouter key. Instead, this mode writes
`$PI_CONFIG_DIR/private/egress.env` (mode 600) with the real
`OPENROUTER_API_KEY` plus the filtered `pi.env` values and passes it to the
container. The key is therefore inside the agent VM, readable by Pi and by
anything Pi runs. Normal mode and `--manual` never mount this file; they still
see only `sk-or-v1-placeholder`.

```bash
pic --allow-egress
pic --allow-egress --clone owner/repo
pic --allow-egress sh -c 'curl -fsS https://example.com | head'
```

It mounts the same instance agent volume, read-only settings, project or clone,
and Zig caches as normal mode, so sessions carry over in both directions. It
creates no proxy and no host-only network, and it neither starts nor needs
`pi-proxy`.

It requires the host env file with a real `OPENROUTER_API_KEY`, like normal
mode. It refuses `check`, `proxy`, `proxy-stop`, and `--manual`; `check`
describes the locked network, which this mode does not have.

Only use it with repos you trust and a key whose loss you can accept. A
prompt-injected agent can copy the key and the agent volume to any destination.
A normal `pic` afterwards starts the proxy again and restores the placeholder.

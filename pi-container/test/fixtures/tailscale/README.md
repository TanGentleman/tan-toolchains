# Tailscale fixtures

`status.json` is the shape of `tailscale status --json` that `serve.sh`
reads: `BackendState`, `Self.{UserID,HostName,DNSName,Tags}`,
`User[id].LoginName` and `CertDomains`. Tests derive the tagged-device,
logged-out and no-HTTPS cases from it with jq.

It is hand-built from `ipn/ipnstate/ipnstate.go` (tailscale main,
2026-11-23) until a real capture replaces it. To record one on the Mac,
logged in as yourself with HTTPS certificates on:

```sh
tailscale status --json | jq '
  (.Self.DNSName | rtrimstr(".")) as $dns | (.Self.UserID | tostring) as $u
  | {Version, BackendState,
     CertDomains: ((.CertDomains // []) | map(select(. == $dns) | "mac1.example-tailnet.ts.net")),
     Self: (.Self | {ID, HostName: "Mac1", DNSName: "mac1.example-tailnet.ts.net.", OS, UserID, Tags, Online}),
     User: {($u): (.User[$u] | {ID, LoginName: "you@github", DisplayName: "You"})},
     CurrentTailnet: (.CurrentTailnet | {Name: "you@github", MagicDNSSuffix: "example-tailnet.ts.net", MagicDNSEnabled})}
' > /tmp/status.json && mv /tmp/status.json test/fixtures/tailscale/status.json
```

The filter swaps your host, tailnet and login for the names `test-serve.sh`
expects (`Mac1`, `mac1.example-tailnet.ts.net`, `you@github`) and drops other
cert domains and `CurrentTailnet.StableID`. If `CertDomains` comes out `[]`,
HTTPS certificates are off for this Mac: turn them on and record again.

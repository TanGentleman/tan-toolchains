# Tailscale fixtures

`status.json` is the shape of `tailscale status --json` that `serve.sh`
reads: `BackendState`, `Self.{UserID,HostName,DNSName,Tags}`,
`User[id].LoginName` and `CertDomains`. Tests derive the tagged-device,
logged-out and no-HTTPS cases from it with jq.

It is hand-built from `ipn/ipnstate/ipnstate.go` (tailscale main,
2026-11-23) until a real capture replaces it. To record one on the Mac:

```sh
tailscale status --json | jq '{Version, BackendState, CertDomains,
  Self: (.Self | {ID, HostName, DNSName, OS, UserID, Tags, Online}),
  User: (.Self.UserID | tostring) as $u | {($u): .User[$u]},
  CurrentTailnet}' > test/fixtures/tailscale/status.json
```

Then replace your names with the ones below before committing.

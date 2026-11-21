# fleet

`fleetd` runs coding-agent sessions on any machine in your tailnet, records
every byte, and lets permitted devices watch, steer, hand off, or fork them.

## Quick start

```sh
cd fleet
go build -o fleetd ./cmd/fleetd

# laptop: joins your tailnet as "fleet-laptop" (prints a login URL once)
./fleetd -name laptop -tsnet fleet-laptop -listen :7433

# always-on box: also replicates the laptop's sessions
./fleetd -name server -tsnet fleet-server -listen :7433 -peer http://fleet-laptop:7433
```

Open `http://fleet-laptop:7433` on your phone. Add the
[policy grants](IMPLEMENTATION.md#tailnet-policy) first; without them every request is denied.

## Checks

```sh
go test -race ./...
bash e2e/smoke.sh     # two nodes, fake harness, kill -9, handoff, fork
bash e2e/tailnet.sh   # Headscale in Docker: WhoIs, roles, shares, handoff over tsnet
```

Design, API, and limits: [IMPLEMENTATION.md](IMPLEMENTATION.md).

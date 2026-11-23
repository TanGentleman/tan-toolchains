// fleetd runs agent sessions on this machine and serves them to the tailnet
// through `tailscale serve`, which supplies each caller's identity.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/TanGentleman/tan-toolchains/fleet/core"
	"github.com/TanGentleman/tan-toolchains/fleet/fake"
	"github.com/TanGentleman/tan-toolchains/fleet/node"
)

type list []string

func (l *list) String() string     { return strings.Join(*l, ",") }
func (l *list) Set(v string) error { *l = append(*l, v); return nil }

func main() {
	if len(os.Args) > 1 && os.Args[1] == "agent" {
		os.Exit(runAgent(os.Args[2:]))
	}
	if len(os.Args) > 1 && os.Args[1] == "fake" {
		prompt, _ := io.ReadAll(os.Stdin)
		// A signal-backed context: with Background, "sleep" blocks on a nil
		// channel and the runtime exits 2 on deadlock instead of waiting.
		ctx, _ := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		code, err := fake.Run(ctx, os.Getenv("FLEET_STATE"), string(prompt), os.Stdout)
		if err != nil {
			log.Print(err)
		}
		os.Exit(code)
	}
	home, _ := os.UserHomeDir()
	var owners, spawners, peers, harnesses list
	name := flag.String("name", "", "node name (required)")
	url := flag.String("url", "", "this node's URL as other nodes reach it, e.g. https://laptop.tailnet.ts.net")
	data := flag.String("data", filepath.Join(home, ".fleet"), "data directory")
	listen := flag.String("listen", "127.0.0.1:7433", "loopback address; put `tailscale serve` in front")
	flag.Var(&owners, "owner", "tailnet login with full access (repeatable)")
	flag.Var(&spawners, "spawner", "tailnet login that may spawn sessions (repeatable)")
	flag.Var(&peers, "peer", "node URL to copy sessions from (repeatable)")
	flag.Var(&harnesses, "harness", `NAME=COMMAND ARGS, run once per turn with the prompt on stdin; keep state in $FLEET_STATE (repeatable)`)
	flag.Parse()
	if *name == "" || len(owners) == 0 {
		log.Fatal("fleetd: -name and -owner are required")
	}
	host, port, err := net.SplitHostPort(*listen)
	if ip := net.ParseIP(host); err != nil || ip == nil || !ip.IsLoopback() {
		log.Fatalf("fleetd: -listen %s is not a loopback address; fleetd trusts the identity header, so only `tailscale serve` may reach it", *listen)
	}
	exe, err := os.Executable()
	if err != nil {
		log.Fatal(err)
	}
	hs := map[string]node.Harness{"fake": node.Exec{Argv: []string{exe, "fake"}}}
	for _, k := range []string{"pi", "claude", "codex"} {
		hs[k] = node.Exec{Argv: []string{exe, "agent", k}}
	}
	for _, h := range harnesses {
		k, v, ok := strings.Cut(h, "=")
		argv := strings.Fields(v)
		if !ok || k == "" || len(argv) == 0 {
			log.Fatalf("fleetd: bad -harness %q", h)
		}
		hs[k] = node.Exec{Argv: argv}
	}
	n, err := node.New(node.Config{
		Name: *name, URL: *url, Data: *data, Harnesses: hs, Peers: peers, PeerLogin: owners[0],
		Hosts:  []string{*listen, net.JoinHostPort("localhost", port)},
		Policy: core.Policy{Owners: owners, Spawners: spawners},
	})
	if err != nil {
		log.Fatal(err)
	}
	srv := &http.Server{Addr: *listen, Handler: n.Handler()}
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		srv.Close()
	}()
	fmt.Fprintf(os.Stderr, "fleetd %s on http://%s\n", *name, *listen)
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	n.Close()
}

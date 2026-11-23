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
	"slices"
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
	var owners, spawners, harnesses, keyed list
	name := flag.String("name", "", "node name (required)")
	url := flag.String("url", "", "this node's tailnet URL, e.g. https://laptop.tailnet.ts.net; its host is accepted in Host")
	data := flag.String("data", filepath.Join(home, ".fleet"), "data directory")
	listen := flag.String("listen", "127.0.0.1:7433", "loopback address; put `tailscale serve` in front")
	flag.Var(&owners, "owner", "tailnet login with full access (repeatable)")
	flag.Var(&spawners, "spawner", "tailnet login that may spawn sessions (repeatable)")
	flag.Var(&harnesses, "harness", `NAME=COMMAND ARGS, run once per turn with the prompt on stdin; keep state in $FLEET_STATE (repeatable)`)
	flag.Var(&keyed, "harness-key", "custom harness NAME that gets OPENROUTER_API_KEY; others don't (repeatable)")
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
	// pi-ctr is the one built-in harness: Pi in pi-container, whose proxy
	// holds the real key, so the harness never gets fleetd's copy. Tests add
	// `-harness "fake=fleetd fake"`; host CLIs are `-harness "pi=fleetd agent pi"`.
	builtin := []string{"pi-ctr"}
	hs := map[string]node.Harness{"pi-ctr": node.Exec{Argv: []string{exe, "agent", "pi-ctr"}, Drop: []string{"OPENROUTER_API_KEY"}}}
	for _, h := range harnesses {
		k, v, ok := strings.Cut(h, "=")
		argv := strings.Fields(v)
		if !ok || k == "" || len(argv) == 0 {
			log.Fatalf("fleetd: bad -harness %q", h)
		}
		if _, dup := hs[k]; dup {
			log.Fatalf("fleetd: -harness %q: %s is already a harness (%s is built in)", h, k, strings.Join(builtin, ", "))
		}
		h := node.Exec{Argv: argv}
		if !slices.Contains(keyed, k) {
			h.Drop = []string{"OPENROUTER_API_KEY"}
		}
		hs[k] = h
	}
	for _, k := range keyed {
		if _, ok := hs[k].(node.Exec); !ok || slices.Contains(builtin, k) {
			log.Fatalf("fleetd: -harness-key %q is not a custom -harness", k)
		}
	}
	n, err := node.New(node.Config{
		Name: *name, URL: *url, Data: *data, Harnesses: hs,
		Sandboxes: map[string]string{"pi-ctr": "pi-container"},
		Hosts:     []string{*listen, net.JoinHostPort("localhost", port)},
		Policy:    core.Policy{Owners: owners, Spawners: spawners},
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

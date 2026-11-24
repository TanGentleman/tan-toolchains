// fleetd runs Pi sessions on this machine, one pi-ctr turn at a time, and
// serves them to the tailnet through `tailscale serve`, which supplies each
// caller's identity. Start it with `pic serve`.
package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/TanGentleman/tan-toolchains/fleet/node"
)

// commit is the git commit fleetd was built from; build.sh fleet sets it.
var commit = "unknown"

type list []string

func (l *list) String() string     { return strings.Join(*l, ",") }
func (l *list) Set(v string) error { *l = append(*l, v); return nil }

func main() {
	if len(os.Args) > 1 && os.Args[1] == "pi-ctr" {
		os.Exit(runPiCtr(os.Args[2:]))
	}
	if len(os.Args) == 2 && os.Args[1] == "-version" {
		fmt.Println(commit)
		return
	}
	home, _ := os.UserHomeDir()
	var owners list
	name := flag.String("name", "", "node name (required)")
	url := flag.String("url", "", "this node's tailnet URL, e.g. https://laptop.tailnet.ts.net; its host is accepted in Host")
	data := flag.String("data", filepath.Join(home, ".fleet"), "data directory")
	listen := flag.String("listen", "127.0.0.1:7433", "loopback address; put `tailscale serve` in front")
	flag.Var(&owners, "owner", "tailnet login allowed to use this node; nobody else is (repeatable)")
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
	// The one harness: Pi in pi-container, whose proxy holds the real key,
	// so the turn never gets a copy from fleetd's environment.
	n, err := node.New(node.Config{
		Name: *name, URL: *url, Data: *data, Owners: owners,
		Harnesses: map[string]node.Harness{"pi-ctr": node.Exec{
			Argv: []string{exe, "pi-ctr"}, StopArgv: []string{exe, "pi-ctr", "-stop"}, Drop: []string{"OPENROUTER_API_KEY"}}},
		Hosts: []string{*listen, net.JoinHostPort("localhost", port)},
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

// fleetd runs agent sessions on this machine, records every byte they emit,
// and serves them to permitted tailnet peers.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/internal/authz"
	"github.com/TanGentleman/tan-toolchains/fleet/internal/harness"
	"github.com/TanGentleman/tan-toolchains/fleet/internal/node"
	"github.com/TanGentleman/tan-toolchains/fleet/internal/tailnet"
)

type list []string

func (l *list) String() string     { return strings.Join(*l, ",") }
func (l *list) Set(v string) error { *l = append(*l, v); return nil }

func main() {
	host, _ := os.Hostname()
	var peers, piEnv list
	name := flag.String("name", host, "node name")
	data := flag.String("data", os.Getenv("HOME")+"/.fleet", "data directory")
	listen := flag.String("listen", "127.0.0.1:7433", "listen address (plain or -host-tailscale)")
	tsHost := flag.String("tsnet", "", "join the tailnet as this hostname (embedded Tailscale)")
	tsDir := flag.String("ts-dir", "", "tsnet state directory (default <data>/tsnet)")
	tsTLS := flag.Bool("tls", false, "with -tsnet, serve HTTPS on :443 with the tailnet cert")
	control := flag.String("control-url", "", "tailnet control server (Headscale); default Tailscale")
	hostTS := flag.Bool("host-tailscale", false, "identify callers via this machine's tailscaled")
	devPolicy := flag.String("dev-policy", "", `JSON {"user": cap} trusting X-Fleet-User; loopback only`)
	peerAs := flag.String("peer-as", "", "dev identity sent to peers (with -dev-policy)")
	piCmd := flag.String("pi", "pi", "command that runs Pi (space separated)")
	piArgs := flag.String("pi-args", "", "extra Pi arguments (space separated)")
	fakeSlow := flag.Duration("fake-slow", 5*time.Second, "how long a fake SLOW turn takes")
	flag.Var(&peers, "peer", "peer fleetd base URL (repeatable)")
	flag.Var(&piEnv, "pi-env", "KEY=VALUE for Pi (repeatable)")
	flag.Parse()

	var (
		ln       net.Listener
		identify func(*http.Request) (authz.Principal, error)
		hdr      http.Header
		client   = &http.Client{Timeout: 30 * time.Second}
		err      error
	)
	switch {
	case *devPolicy != "":
		var pol map[string]authz.Cap
		b, err := os.ReadFile(*devPolicy)
		if err == nil {
			err = json.Unmarshal(b, &pol)
		}
		if err != nil {
			log.Fatalf("dev policy: %v", err)
		}
		if h, _, _ := net.SplitHostPort(*listen); !net.ParseIP(h).IsLoopback() {
			log.Fatal("-dev-policy trusts a header; it only listens on loopback")
		}
		identify = node.HeaderIdentity(pol)
		if *peerAs != "" {
			hdr = http.Header{"X-Fleet-User": {*peerAs}}
		}
		ln, err = net.Listen("tcp", *listen)
	case *tsHost != "":
		if *tsDir == "" {
			*tsDir = *data + "/tsnet"
		}
		var id tailnet.Identify
		var closeTS func() error
		ln, id, closeTS, err = tailnet.Embedded(*tsHost, *tsDir, *control, *listen, *tsTLS)
		if closeTS != nil {
			defer closeTS()
		}
		identify = id
	case *hostTS:
		var id tailnet.Identify
		ln, id, err = tailnet.Host(*listen)
		identify = id
	default:
		log.Fatal("pick an identity source: -tsnet, -host-tailscale or -dev-policy")
	}
	if err != nil {
		log.Fatal(err)
	}

	n, err := node.New(node.Config{
		Name: *name, Data: *data, Peers: peers, Identify: identify, PeerHeader: hdr, Client: client,
		Harnesses: harness.Registry{
			"fake": harness.Fake{Slow: *fakeSlow},
			"pi":   harness.Pi{Cmd: strings.Fields(*piCmd), Args: strings.Fields(*piArgs), Env: piEnv},
		},
	})
	if err != nil {
		log.Fatal(err)
	}
	srv := &http.Server{Handler: n.Handler(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		log.Printf("fleetd %s on %s", *name, ln.Addr())
		if err := srv.Serve(ln); err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
	n.Close()
}

// Package tailnet turns Tailscale peers into authz principals. It is the only
// package that imports tailscale.com; replacing Tailscale means replacing it.
package tailnet

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"

	"github.com/TanGentleman/tan-toolchains/fleet/internal/authz"
)

// Identify maps a request to its caller.
type Identify func(*http.Request) (authz.Principal, error)

// FromWhoIs builds a principal keyed on the stable user ID, never the login
// string (Headscale and Tailscale SaaS format logins differently).
func FromWhoIs(w *apitype.WhoIsResponse) (authz.Principal, error) {
	if w == nil || w.Node == nil || w.UserProfile == nil {
		return authz.Principal{}, authz.ErrNoIdentity
	}
	caps, err := tailcfg.UnmarshalCapJSON[authz.Cap](w.CapMap, tailcfg.PeerCapability(authz.CapName))
	if err != nil {
		return authz.Principal{}, fmt.Errorf("tailnet: bad %s capability: %w", authz.CapName, err)
	}
	p := authz.Principal{
		Login:   fmt.Sprintf("ts:%d", w.UserProfile.ID),
		Display: w.UserProfile.LoginName,
		Node:    w.Node.ComputedName,
		Tagged:  w.Node.IsTagged(),
		Tags:    w.Node.Tags,
		Cap:     authz.Merge(caps),
	}
	if p.Tagged {
		p.Login = "node:" + strings.Join(w.Node.Tags, ",")
		p.Display = p.Login
	}
	return p, nil
}

func whois(lc *local.Client) Identify {
	return func(r *http.Request) (authz.Principal, error) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		w, err := lc.WhoIs(ctx, r.RemoteAddr)
		if err != nil {
			return authz.Principal{}, fmt.Errorf("%w: %v", authz.ErrNoIdentity, err)
		}
		return FromWhoIs(w)
	}
}

// Embedded joins the tailnet as its own node (tsnet) and listens on addr.
// TS_AUTHKEY, if set, registers it without an interactive login.
// With tls set it serves HTTPS on :443 using the tailnet's cert. The returned
// client dials peers through the same tailnet node.
func Embedded(hostname, dir, controlURL, addr string, tls bool) (net.Listener, Identify, *http.Client, func() error, error) {
	s := &tsnet.Server{Hostname: hostname, Dir: dir, ControlURL: controlURL, AuthKey: os.Getenv("TS_AUTHKEY")}
	if os.Getenv("FLEET_TSNET_LOG") != "" {
		s.Logf = log.Printf
	}
	if _, err := s.Up(context.Background()); err != nil {
		return nil, nil, nil, nil, err
	}
	lc, err := s.LocalClient()
	if err != nil {
		return nil, nil, nil, nil, err
	}
	var ln net.Listener
	if tls {
		ln, err = s.ListenTLS("tcp", ":443")
	} else {
		ln, err = s.Listen("tcp", addr)
	}
	if err != nil {
		return nil, nil, nil, nil, err
	}
	return ln, whois(lc), s.HTTPClient(), s.Close, nil
}

// Host listens on addr and asks the host's tailscaled who each peer is.
func Host(addr string) (net.Listener, Identify, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, nil, err
	}
	return ln, whois(&local.Client{}), nil
}

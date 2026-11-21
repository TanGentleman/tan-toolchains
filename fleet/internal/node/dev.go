package node

import (
	"errors"
	"net/http"

	"github.com/TanGentleman/tan-toolchains/fleet/internal/authz"
)

// HeaderIdentity trusts the X-Fleet-User header and looks the user up in
// policy. It is for tests and loopback-only development, never a network.
func HeaderIdentity(policy map[string]authz.Cap) func(*http.Request) (authz.Principal, error) {
	return func(r *http.Request) (authz.Principal, error) {
		u := r.Header.Get("X-Fleet-User")
		if u == "" {
			u = r.URL.Query().Get("as")
		}
		c, ok := policy[u]
		if !ok {
			return authz.Principal{}, errors.New("unknown dev user")
		}
		return authz.Principal{Login: u, Display: u, Node: "dev", Cap: c}, nil
	}
}

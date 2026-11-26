package node

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"mime"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/core"
)

//go:embed ui.html
var uiHTML []byte

// LoginHeader carries the caller's identity. `tailscale serve` sets it on
// every tailnet request and strips any value the client sent, so fleetd
// trusts it only because it listens on loopback behind serve.
const LoginHeader = "Tailscale-User-Login"

var words = new(mime.WordDecoder)

func login(r *http.Request) string {
	v := r.Header.Get(LoginHeader)
	if d, err := words.DecodeHeader(v); err == nil {
		return d
	}
	return v
}

// Handler serves the API and the phone UI. Every route needs an owner's login.
func (n *Node) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(uiHTML)
	})
	mux.HandleFunc("GET /v1/node", func(w http.ResponseWriter, r *http.Request) {
		info := map[string]any{"name": n.cfg.Name, "url": n.cfg.URL, "you": login(r), "harnesses": n.harnessNames(), "unreadable": n.Unreadable()}
		if n.cfg.Defaults != nil {
			if c, err := n.cfg.Defaults(); err != nil {
				info["config_error"] = err.Error()
			} else {
				info["config"] = c
			}
		}
		writeJSON(w, info)
	})
	mux.HandleFunc("GET /v1/sessions", func(w http.ResponseWriter, r *http.Request) {
		list := n.List()
		if list == nil {
			list = []Summary{}
		}
		writeJSON(w, list)
	})
	mux.HandleFunc("POST /v1/sessions", func(w http.ResponseWriter, r *http.Request) {
		var b struct{ Harness, Model, Title, Key, Prompt, Repo, Branch string }
		if !readJSON(w, r, &b) {
			return
		}
		sid, err := n.Spawn(login(r), b.Key, b.Prompt, core.CreatedData{Harness: b.Harness, Model: b.Model, Title: b.Title, Repo: b.Repo, Branch: b.Branch})
		reply(w, map[string]string{"sid": sid}, err)
	})
	mux.HandleFunc("GET /v1/sessions/{sid}", func(w http.ResponseWriter, r *http.Request) {
		st, err := n.State(r.PathValue("sid"))
		reply(w, st, err)
	})
	mux.HandleFunc("GET /v1/sessions/{sid}/events", n.events)
	mux.HandleFunc("POST /v1/sessions/{sid}/inputs", func(w http.ResponseWriter, r *http.Request) {
		var b struct{ Key, Text string }
		if !readJSON(w, r, &b) {
			return
		}
		seq, err := n.Input(login(r), r.PathValue("sid"), b.Key, b.Text)
		reply(w, map[string]uint64{"seq": seq}, err)
	})
	mux.HandleFunc("POST /v1/sessions/{sid}/abort", func(w http.ResponseWriter, r *http.Request) {
		reply(w, map[string]bool{"ok": true}, n.Abort(r.PathValue("sid")))
	})
	mux.HandleFunc("POST /v1/sessions/{sid}/fork", func(w http.ResponseWriter, r *http.Request) {
		var b struct{ Key string }
		if !readJSON(w, r, &b) {
			return
		}
		sid, err := n.Fork(login(r), r.PathValue("sid"), b.Key)
		reply(w, map[string]string{"sid": sid}, err)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// A DNS-rebinding page reaches loopback with its own name in Host,
		// and a form post can only send text/plain or form types.
		if !n.hostOK(r.Host) {
			http.Error(w, "unexpected Host "+strconv.Quote(r.Host)+"; use the -url host", http.StatusMisdirectedRequest)
			return
		}
		if mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); r.Method == http.MethodPost && mt != "application/json" {
			http.Error(w, "POST needs Content-Type: application/json", http.StatusUnsupportedMediaType)
			return
		}
		if login(r) == "" {
			http.Error(w, "no tailnet identity (Tailscale-User-Login); reach fleetd through `tailscale serve`", http.StatusUnauthorized)
			return
		}
		if !slices.Contains(n.cfg.Owners, login(r)) {
			http.Error(w, login(r)+" is not an owner of this node (fleetd -owner)", http.StatusForbidden)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func (n *Node) hostOK(host string) bool {
	if u, err := url.Parse(n.cfg.URL); err == nil && u.Host != "" && canonHost(host, u.Scheme) == canonHost(u.Host, u.Scheme) {
		return true
	}
	return slices.ContainsFunc(n.cfg.Hosts, func(h string) bool { return canonHost(h, "") == canonHost(host, "") })
}

// canonHost lowercases, drops a DNS trailing dot and the scheme's default port.
func canonHost(hostport, scheme string) string {
	h, p, err := net.SplitHostPort(hostport)
	if err != nil {
		h, p = hostport, ""
	}
	h = strings.TrimSuffix(strings.ToLower(h), ".")
	if scheme == "https" && p == "443" || scheme == "http" && p == "80" {
		p = ""
	}
	if p == "" {
		return h
	}
	return net.JoinHostPort(h, p)
}

func (n *Node) harnessNames() []string {
	var out []string
	for k := range n.cfg.Harnesses {
		out = append(out, k)
	}
	return out
}

// events serves lines after ?after= (at most ?limit=) as JSONL, or as a live
// SSE stream (id = seq) when the client asks for text/event-stream.
func (n *Node) events(w http.ResponseWriter, r *http.Request) {
	sid := r.PathValue("sid")
	after, _ := strconv.ParseUint(r.URL.Query().Get("after"), 10, 64)
	if v := r.Header.Get("Last-Event-ID"); v != "" {
		after, _ = strconv.ParseUint(v, 10, 64)
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	sse := r.Header.Get("Accept") == "text/event-stream"
	lines, changed, err := n.Events(sid, after)
	if err != nil {
		reply(w, nil, err)
		return
	}
	if !sse {
		if limit > 0 && len(lines) > limit {
			lines = lines[:limit]
		}
		w.Header().Set("Content-Type", "application/jsonl")
		for _, l := range lines {
			w.Write(l)
			w.Write([]byte{'\n'})
		}
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	fl, _ := w.(http.Flusher)
	ping := time.NewTicker(20 * time.Second)
	defer ping.Stop()
	for {
		for _, l := range lines {
			after++
			fmt.Fprintf(w, "id: %d\ndata: %s\n\n", after, l)
		}
		if fl != nil {
			fl.Flush()
		}
		select {
		case <-r.Context().Done():
			return
		case <-ping.C:
			fmt.Fprint(w, ": ping\n\n")
		case <-changed:
		}
		lines, changed, err = n.Events(sid, after)
		if err != nil {
			return
		}
	}
}

func readJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(v); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func reply(w http.ResponseWriter, v any, err error) {
	if err == nil {
		writeJSON(w, v)
		return
	}
	code := http.StatusBadRequest
	switch {
	case errors.Is(err, ErrNotFound):
		code = http.StatusNotFound
	case errors.Is(err, ErrForbidden):
		code = http.StatusForbidden
	case errors.Is(err, core.ErrRunning), errors.Is(err, core.ErrNotRunning):
		code = http.StatusConflict
	case errors.Is(err, core.ErrBadEvent):
		code = http.StatusInternalServerError
	}
	http.Error(w, err.Error(), code)
}

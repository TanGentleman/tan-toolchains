package node

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"mime"
	"net/http"
	"strconv"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/core"
)

//go:embed ui.html
var uiHTML []byte

var words = new(mime.WordDecoder)

func login(r *http.Request) string {
	v := r.Header.Get(LoginHeader)
	if d, err := words.DecodeHeader(v); err == nil {
		return d
	}
	return v
}

// Handler serves the API and the phone UI. Every route needs a login.
func (n *Node) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(uiHTML)
	})
	mux.HandleFunc("GET /v1/node", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"name": n.cfg.Name, "url": n.cfg.URL, "you": login(r),
			"can_spawn": n.cfg.Policy.CanSpawn(login(r)), "harnesses": n.harnessNames()})
	})
	mux.HandleFunc("GET /v1/sessions", func(w http.ResponseWriter, r *http.Request) {
		list := n.List(login(r))
		if list == nil {
			list = []Summary{}
		}
		writeJSON(w, list)
	})
	mux.HandleFunc("POST /v1/sessions", func(w http.ResponseWriter, r *http.Request) {
		var b struct{ Harness, Title, Key, Prompt string }
		if !readJSON(w, r, &b) {
			return
		}
		sid, err := n.Spawn(login(r), b.Harness, b.Title, b.Key, b.Prompt)
		reply(w, map[string]string{"sid": sid}, err)
	})
	mux.HandleFunc("GET /v1/sessions/{sid}", func(w http.ResponseWriter, r *http.Request) {
		st, err := n.State(login(r), r.PathValue("sid"))
		reply(w, st, err)
	})
	mux.HandleFunc("GET /v1/sessions/{sid}/events", n.events)
	mux.HandleFunc("POST /v1/sessions/{sid}/inputs", func(w http.ResponseWriter, r *http.Request) {
		var b struct{ Key, Kind, Text string }
		if !readJSON(w, r, &b) {
			return
		}
		if b.Kind == "" {
			b.Kind = "prompt"
		}
		seq, err := n.Input(login(r), r.PathValue("sid"), b.Key, b.Kind, b.Text)
		reply(w, map[string]uint64{"seq": seq}, err)
	})
	mux.HandleFunc("POST /v1/sessions/{sid}/seal", func(w http.ResponseWriter, r *http.Request) {
		var b struct{ To string }
		if !readJSON(w, r, &b) {
			return
		}
		head, err := n.Seal(login(r), r.PathValue("sid"), b.To)
		reply(w, map[string]uint64{"head": head}, err)
	})
	mux.HandleFunc("POST /v1/sessions/{sid}/resume", func(w http.ResponseWriter, r *http.Request) {
		var b struct{ From string }
		if !readJSON(w, r, &b) {
			return
		}
		reply(w, map[string]string{"writer": n.cfg.Name}, n.Resume(r.Context(), login(r), r.PathValue("sid"), b.From))
	})
	mux.HandleFunc("POST /v1/sessions/{sid}/fork", func(w http.ResponseWriter, r *http.Request) {
		var b struct{ Key string }
		if !readJSON(w, r, &b) {
			return
		}
		sid, err := n.Fork(login(r), r.PathValue("sid"), b.Key)
		reply(w, map[string]string{"sid": sid}, err)
	})
	mux.HandleFunc("POST /v1/sessions/{sid}/share", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			User  string
			Level core.Level
		}
		if !readJSON(w, r, &b) {
			return
		}
		reply(w, map[string]bool{"ok": true}, n.Share(login(r), r.PathValue("sid"), b.User, b.Level))
	})
	mux.HandleFunc("GET /v1/blobs/{sha}", func(w http.ResponseWriter, r *http.Request) {
		p, err := n.BlobPath(login(r), r.PathValue("sha"))
		if err != nil {
			reply(w, nil, err)
			return
		}
		http.ServeFile(w, r, p)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if login(r) == "" {
			http.Error(w, "no tailnet identity (Tailscale-User-Login); reach fleetd through `tailscale serve`", http.StatusUnauthorized)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func (n *Node) harnessNames() []string {
	var out []string
	for k := range n.cfg.Harnesses {
		out = append(out, k)
	}
	return out
}

// events serves lines after ?after= as JSONL, or as SSE (id = seq) when the
// client asks for text/event-stream. ?wait=1 long-polls for new lines.
func (n *Node) events(w http.ResponseWriter, r *http.Request) {
	sid := r.PathValue("sid")
	after, _ := strconv.ParseUint(r.URL.Query().Get("after"), 10, 64)
	if v := r.Header.Get("Last-Event-ID"); v != "" {
		after, _ = strconv.ParseUint(v, 10, 64)
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	sse := r.Header.Get("Accept") == "text/event-stream"
	lines, changed, err := n.Events(login(r), sid, after)
	if err != nil {
		reply(w, nil, err)
		return
	}
	if !sse {
		if len(lines) == 0 && r.URL.Query().Get("wait") != "" {
			select {
			case <-changed:
			case <-time.After(25 * time.Second):
			case <-r.Context().Done():
			}
			lines, _, _ = n.Events(login(r), sid, after)
		}
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
		lines, changed, err = n.Events(login(r), sid, after)
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
	var he *httpError
	switch {
	case errors.Is(err, ErrNotFound):
		code = http.StatusNotFound
	case errors.Is(err, ErrForbidden):
		code = http.StatusForbidden
	case errors.Is(err, core.ErrNotWriter), errors.Is(err, core.ErrRunning), errors.Is(err, core.ErrNotRunning):
		code = http.StatusConflict
	case errors.Is(err, ErrUnreachable):
		code = http.StatusServiceUnavailable
	case errors.As(err, &he):
		code = he.Status
	case errors.Is(err, ErrDiverged), errors.Is(err, core.ErrBadEvent):
		code = http.StatusInternalServerError
	}
	http.Error(w, err.Error(), code)
}

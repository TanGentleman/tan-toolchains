package node

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/internal/authz"
	"github.com/TanGentleman/tan-toolchains/fleet/internal/harness"
)

//go:embed ui/index.html
var ui embed.FS

type caller struct {
	authz.Principal
	forwarded bool // a peer node relaying a request it already authorized
}

type handler func(w http.ResponseWriter, r *http.Request, c caller)

func (n *Node) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		b, _ := ui.ReadFile("ui/index.html")
		w.Write(b)
	})
	route := func(pat string, h handler) { mux.Handle(pat, n.auth(h)) }
	route("GET /v1/node", n.getNode)
	route("GET /v1/sessions", n.listSessions)
	route("POST /v1/sessions", n.spawn)
	route("GET /v1/sessions/{sid}", n.withSession(authz.ActRead, n.getSession))
	route("GET /v1/sessions/{sid}/events", n.withSession(authz.ActRead, n.events))
	route("GET /v1/sessions/{sid}/raw/{run}", n.withSession(authz.ActRead, n.raw))
	route("POST /v1/sessions/{sid}/inputs", n.withSession(authz.ActPrompt, n.input))
	route("POST /v1/sessions/{sid}/seal", n.withSession(authz.ActHandoff, n.seal))
	route("POST /v1/sessions/{sid}/resume", n.withSession(authz.ActHandoff, n.resume))
	route("POST /v1/sessions/{sid}/fork", n.withSession(authz.ActHandoff, n.fork))
	route("POST /v1/sessions/{sid}/share", n.withSession(authz.ActShare, n.share))
	route("GET /v1/blobs/{sha}", n.blob)
	return mux
}

func (n *Node) auth(h handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, err := n.cfg.Identify(r)
		if err != nil {
			httpError(w, http.StatusUnauthorized, err)
			return
		}
		c := caller{Principal: p}
		if as := r.Header.Get("X-Fleet-As"); as != "" {
			if !p.Cap.Archive {
				httpError(w, http.StatusForbidden, errors.New("only fleet nodes may relay"))
				return
			}
			c = caller{Principal: authz.Principal{Login: as, Display: r.Header.Get("X-Fleet-As-Display")}, forwarded: true}
		}
		h(w, r, c)
	})
}

// allowed: relayed requests were checked by the relaying node; fleet nodes
// (archive capability) may list, read and seal for handoff.
func allowed(c caller, act authz.Action, m *Meta) authz.Decision {
	if c.forwarded {
		return authz.Decision{Allow: true, Reason: "relayed by fleet node"}
	}
	if c.Cap.Archive && (act == authz.ActList || act == authz.ActRead || act == authz.ActHandoff || act == authz.ActArchive) {
		return authz.Decision{Allow: true, Reason: "fleet node"}
	}
	r := authz.Request{Action: act}
	if m != nil {
		r.Session = m.authz()
	}
	return authz.Decide(c.Principal, r)
}

func (n *Node) withSession(act authz.Action, h func(http.ResponseWriter, *http.Request, caller, *Session, Meta)) handler {
	return func(w http.ResponseWriter, r *http.Request, c caller) {
		s := n.get(r.PathValue("sid"))
		if (s == nil || s.j.Head() == 0) && !c.Cap.Archive && !c.forwarded {
			s = n.fetch(r.Context(), r.PathValue("sid")) // peers never trigger fetches, so no loops
		}
		if s == nil || s.j.Head() == 0 {
			httpError(w, http.StatusNotFound, errors.New("no such session"))
			return
		}
		m := s.Meta()
		if d := allowed(c, act, &m); !d.Allow {
			httpError(w, http.StatusForbidden, errors.New(d.Reason))
			return
		}
		h(w, r, c, s, m)
	}
}

func httpError(w http.ResponseWriter, code int, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

func writeErr(w http.ResponseWriter, err error) {
	var pe *PeerError
	switch {
	case errors.As(err, &pe):
		httpError(w, pe.Status, errors.New(pe.Msg))
	case errors.Is(err, ErrUnreachable):
		httpError(w, http.StatusServiceUnavailable, err)
	case errors.Is(err, ErrNotOwner):
		httpError(w, http.StatusConflict, err)
	default:
		httpError(w, http.StatusBadRequest, err)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func decode(r *http.Request, v any) error {
	if err := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20)).Decode(v); err != nil {
		return fmt.Errorf("bad json: %w", err)
	}
	return nil
}

func (n *Node) getNode(w http.ResponseWriter, r *http.Request, c caller) {
	n.mu.Lock()
	peers := map[string]string{}
	for k, v := range n.peerURL {
		peers[k] = v
	}
	n.mu.Unlock()
	writeJSON(w, map[string]any{"name": n.cfg.Name, "peers": peers, "harnesses": n.harnessNames(),
		"you": map[string]any{"login": c.Login, "display": c.Display, "node": c.Node, "cap": c.Cap}})
}

func (n *Node) harnessNames() []string {
	var out []string
	for k := range n.cfg.Harnesses {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func (n *Node) listSessions(w http.ResponseWriter, r *http.Request, c caller) {
	if d := allowed(c, authz.ActList, nil); !d.Allow {
		httpError(w, http.StatusForbidden, errors.New(d.Reason))
		return
	}
	out := []Meta{}
	for _, s := range n.list() {
		if s.j.Head() == 0 {
			continue
		}
		m := s.Meta()
		if allowed(c, authz.ActRead, &m).Allow {
			out = append(out, m)
		}
	}
	sort.SliceStable(out, func(i, k int) bool { return out[i].Updated > out[k].Updated })
	writeJSON(w, out)
}

func (n *Node) running(login string) int {
	k := 0
	for _, s := range n.list() {
		if m := s.Meta(); m.Owner == login && m.Node == n.cfg.Name && (m.State == "running" || m.State == "busy") {
			k++
		}
	}
	return k
}

func (n *Node) spawn(w http.ResponseWriter, r *http.Request, c caller) {
	var req struct {
		Harness, Title, Key, Prompt string
	}
	if err := decode(r, &req); err != nil {
		writeErr(w, err)
		return
	}
	d := authz.Decide(c.Principal, authz.Request{Action: authz.ActSpawn, Runner: req.Harness, Running: n.running(c.Login)})
	if !d.Allow {
		httpError(w, http.StatusForbidden, errors.New(d.Reason))
		return
	}
	s, dup, err := n.Spawn(r.Context(), c.Principal, req.Harness, req.Title, req.Key)
	if err != nil {
		writeErr(w, err)
		return
	}
	if req.Prompt != "" {
		if _, _, err := n.Input(r.Context(), s, c.Principal, harness.Input{Key: req.Key + "/prompt", Kind: "prompt", Text: req.Prompt}); err != nil {
			writeErr(w, err)
			return
		}
	}
	writeJSON(w, map[string]any{"session": s.Meta(), "dup": dup})
}

func (n *Node) getSession(w http.ResponseWriter, r *http.Request, c caller, s *Session, m Meta) {
	writeJSON(w, m)
}

// events serves durable events after an offset: JSONL by default, or a live
// SSE stream (catch-up then follow) when the client accepts text/event-stream.
func (n *Node) events(w http.ResponseWriter, r *http.Request, c caller, s *Session, m Meta) {
	after, _ := strconv.ParseUint(r.URL.Query().Get("after"), 10, 64)
	if id := r.Header.Get("Last-Event-ID"); id != "" {
		after, _ = strconv.ParseUint(id, 10, 64)
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if after > s.j.Head() {
		httpError(w, http.StatusRequestedRangeNotSatisfiable, fmt.Errorf("offset %d is past this node's head %d", after, s.j.Head()))
		return
	}
	if r.Header.Get("Accept") != "text/event-stream" {
		w.Header().Set("Content-Type", "application/x-ndjson")
		_, lines, _ := s.j.Read(after, limit)
		for _, l := range lines {
			w.Write(l)
			w.Write([]byte{'\n'})
		}
		return
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		httpError(w, http.StatusInternalServerError, errors.New("streaming unsupported"))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	beat := time.NewTicker(15 * time.Second)
	defer beat.Stop()
	for {
		evs, lines, more := s.j.Read(after, 500)
		for i, l := range lines {
			fmt.Fprintf(w, "id: %d\ndata: %s\n\n", evs[i].Seq, l)
			after = evs[i].Seq
		}
		fl.Flush()
		if len(lines) == 500 {
			continue
		}
		select {
		case <-r.Context().Done():
			return
		case <-n.stop:
			return
		case <-beat.C:
			fmt.Fprint(w, ": beat\n\n")
		case <-more:
		}
	}
}

func (n *Node) raw(w http.ResponseWriter, r *http.Request, c caller, s *Session, m Meta) {
	run, err := strconv.Atoi(r.PathValue("run"))
	if err != nil {
		writeErr(w, err)
		return
	}
	off, _ := strconv.ParseInt(r.URL.Query().Get("off"), 10, 64)
	end := m.MaxRaw[run] // only bytes that durable events point at
	if e, err := strconv.ParseInt(r.URL.Query().Get("end"), 10, 64); err == nil && e < end {
		end = e
	}
	if off < 0 || off > end {
		httpError(w, http.StatusRequestedRangeNotSatisfiable, fmt.Errorf("raw range %d-%d", off, end))
		return
	}
	f, err := os.Open(filepath.Join(s.dir, fmt.Sprintf("raw-%d.log", run)))
	if err != nil {
		writeErr(w, err)
		return
	}
	defer f.Close()
	b := make([]byte, end-off)
	if _, err := f.ReadAt(b, off); err != nil {
		writeErr(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(b)
}

// atOwner runs local when this node is the writer; otherwise it relays the
// request to the writer, so a phone can talk to any node.
func (n *Node) atOwner(w http.ResponseWriter, r *http.Request, c caller, s *Session, m Meta, body any, local func(context.Context) (any, error)) {
	if m.Writer() == n.cfg.Name {
		out, err := local(r.Context())
		if err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, out)
		return
	}
	if c.forwarded {
		writeErr(w, ErrNotOwner)
		return
	}
	var out json.RawMessage
	if err := n.Forward(r.Context(), m.Writer(), r.URL.Path, c.Login, c.Display, body, &out); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, out)
}

func (n *Node) input(w http.ResponseWriter, r *http.Request, c caller, s *Session, m Meta) {
	var in harness.Input
	if err := decode(r, &in); err != nil {
		writeErr(w, err)
		return
	}
	if in.Kind == "" {
		in.Kind = "prompt"
	}
	if in.Kind != "prompt" && in.Kind != "steer" && in.Kind != "cancel" {
		writeErr(w, fmt.Errorf("bad kind %q", in.Kind))
		return
	}
	n.atOwner(w, r, c, s, m, in, func(ctx context.Context) (any, error) {
		seq, dup, err := n.Input(ctx, s, c.Principal, in)
		return map[string]any{"seq": seq, "dup": dup}, err
	})
}

func (n *Node) seal(w http.ResponseWriter, r *http.Request, c caller, s *Session, m Meta) {
	var req struct{ To string }
	decode(r, &req)
	n.atOwner(w, r, c, s, m, req, func(ctx context.Context) (any, error) {
		head, err := n.Seal(ctx, s, req.To)
		return map[string]any{"head": head}, err
	})
}

func (n *Node) resume(w http.ResponseWriter, r *http.Request, c caller, s *Session, m Meta) {
	if err := n.Resume(r.Context(), s); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.Meta())
}

func (n *Node) fork(w http.ResponseWriter, r *http.Request, c caller, s *Session, m Meta) {
	var req struct{ Key string }
	if err := decode(r, &req); err != nil {
		writeErr(w, err)
		return
	}
	if !c.forwarded {
		d := authz.Decide(c.Principal, authz.Request{Action: authz.ActSpawn, Runner: m.Harness, Running: n.running(c.Login)})
		if !d.Allow {
			httpError(w, http.StatusForbidden, errors.New(d.Reason))
			return
		}
	}
	f, dup, err := n.Fork(r.Context(), s, c.Principal, req.Key)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]any{"session": f.Meta(), "dup": dup})
}

func (n *Node) share(w http.ResponseWriter, r *http.Request, c caller, s *Session, m Meta) {
	var req struct {
		User  string
		Level authz.Level
	}
	if err := decode(r, &req); err != nil {
		writeErr(w, err)
		return
	}
	n.atOwner(w, r, c, s, m, req, func(ctx context.Context) (any, error) {
		return map[string]any{"ok": true}, n.Share(ctx, s, c.Principal, req.User, req.Level)
	})
}

var shaRE = regexp.MustCompile(`^[0-9a-f]{64}$`)

func (n *Node) blob(w http.ResponseWriter, r *http.Request, c caller) {
	if !c.Cap.Archive && c.Cap.Role != authz.RoleOwner {
		httpError(w, http.StatusForbidden, errors.New("blobs need archive or owner"))
		return
	}
	sha := r.PathValue("sha")
	if !shaRE.MatchString(sha) {
		httpError(w, http.StatusBadRequest, errors.New("bad sha"))
		return
	}
	http.ServeFile(w, r, n.blobPath(sha))
}

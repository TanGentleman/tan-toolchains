package node

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"

	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/internal/authz"
	"github.com/TanGentleman/tan-toolchains/fleet/internal/harness"
)

var policy = map[string]authz.Cap{
	"tan":   {Role: authz.RoleOwner, Read: "all", Spawn: true},
	"bob":   {Role: authz.RoleFriend, Read: "own", Spawn: true, Slots: 2, Runners: []string{"fake"}},
	"carol": {Role: authz.RoleViewer, Read: "shared"},
	"node":  {Archive: true},
}

type tnode struct {
	*Node
	srv  *httptest.Server
	data string
}

// cluster starts nodes that all peer with each other over httptest.
func cluster(t *testing.T, names ...string) map[string]*tnode {
	t.Helper()
	nodes := map[string]*tnode{}
	var urls []string
	for _, name := range names {
		tn := &tnode{data: t.TempDir()}
		tn.srv = httptest.NewUnstartedServer(nil)
		urls = append(urls, "http://"+tn.srv.Listener.Addr().String())
		nodes[name] = tn
	}
	for i, name := range names {
		var peers []string
		for k, u := range urls {
			if k != i {
				peers = append(peers, u)
			}
		}
		start(t, nodes[name], name, peers)
	}
	return nodes
}

func start(t *testing.T, tn *tnode, name string, peers []string) {
	t.Helper()
	n, err := New(Config{Name: name, Data: tn.data, Peers: peers, PullEvery: time.Hour,
		Identify: HeaderIdentity(policy), PeerHeader: http.Header{"X-Fleet-User": {"node"}},
		Harnesses: harness.Registry{"fake": harness.Fake{Slow: 3 * time.Second}}})
	if err != nil {
		t.Fatal(err)
	}
	tn.Node = n
	tn.srv.Config.Handler = n.Handler()
	if tn.srv.URL == "" {
		tn.srv.Start()
	}
	t.Cleanup(func() { tn.srv.Close(); n.Close() })
}

func call(t *testing.T, tn *tnode, user, method, path string, body any, out any) int {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, tn.srv.URL+path, rd)
	req.Header.Set("X-Fleet-User", user)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if out != nil && resp.StatusCode/100 == 2 {
		if err := json.Unmarshal(b, out); err != nil {
			t.Fatalf("%s %s: %v: %s", method, path, err, b)
		}
	}
	return resp.StatusCode
}

func must(t *testing.T, code int, want int, what string) {
	t.Helper()
	if code != want {
		t.Fatalf("%s: status %d, want %d", what, code, want)
	}
}

type spawned struct {
	Session Meta
	Dup     bool
}

func waitMeta(t *testing.T, tn *tnode, sid string, ok func(Meta) bool) Meta {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		var m Meta
		call(t, tn, "tan", "GET", "/v1/sessions/"+sid, nil, &m)
		if ok(m) {
			return m
		}
		if time.Now().After(deadline) {
			t.Fatalf("timeout waiting on %s at %s: %+v", sid, tn.Name(), m)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func idle(m Meta) bool { return m.State == "running" }

func lines(t *testing.T, tn *tnode, sid string) []string {
	t.Helper()
	req, _ := http.NewRequest("GET", tn.srv.URL+"/v1/sessions/"+sid+"/events", nil)
	req.Header.Set("X-Fleet-User", "tan")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

func kinds(ls []string, kind string) []map[string]any {
	var out []map[string]any
	for _, l := range ls {
		var e map[string]any
		json.Unmarshal([]byte(l), &e)
		if e["kind"] == kind {
			d, _ := e["data"].(map[string]any)
			if d == nil {
				d = map[string]any{}
			}
			out = append(out, d)
		}
	}
	return out
}

func lastText(ls []string) string {
	m := kinds(ls, "message")
	if len(m) == 0 {
		return ""
	}
	return m[len(m)-1]["text"].(string)
}

func TestFleet(t *testing.T) {
	c := cluster(t, "laptop", "server")
	a, b := c["laptop"], c["server"]
	ctx := context.Background()

	// Spawn with a prompt; retries of the same key are the same session.
	var sp spawned
	must(t, call(t, a, "tan", "POST", "/v1/sessions", map[string]any{"harness": "fake", "title": "demo", "key": "k1", "prompt": "hello TOOL"}, &sp), 200, "spawn")
	sid := sp.Session.Sid
	var again spawned
	call(t, a, "tan", "POST", "/v1/sessions", map[string]any{"harness": "fake", "title": "demo", "key": "k1", "prompt": "hello TOOL"}, &again)
	if !again.Dup || again.Session.Sid != sid {
		t.Fatalf("spawn retry made a new session: %+v", again)
	}
	waitMeta(t, a, sid, func(m Meta) bool { return idle(m) && m.Last == "turn 1: hello TOOL" })
	ls := lines(t, a, sid)
	if len(kinds(ls, "tool.call")) != 1 || len(kinds(ls, "tool.result")) != 1 {
		t.Fatalf("tool events missing: %v", ls)
	}

	// Duplicate input keys run once.
	var r1, r2 struct {
		Seq uint64
		Dup bool
	}
	call(t, a, "tan", "POST", "/v1/sessions/"+sid+"/inputs", map[string]any{"key": "i1", "text": "two"}, &r1)
	call(t, a, "tan", "POST", "/v1/sessions/"+sid+"/inputs", map[string]any{"key": "i1", "text": "two"}, &r2)
	if r1.Dup || !r2.Dup || r1.Seq != r2.Seq {
		t.Fatalf("dedupe: %+v %+v", r1, r2)
	}
	waitMeta(t, a, sid, func(m Meta) bool { return idle(m) && m.Last == "turn 2: two" })
	if n := len(kinds(lines(t, a, sid), "turn.end")); n != 2 {
		t.Fatalf("want 2 turns, got %d", n)
	}

	// RBAC: tailnet ceiling AND session share.
	must(t, call(t, a, "bob", "GET", "/v1/sessions/"+sid, nil, nil), 403, "bob reads unshared")
	must(t, call(t, a, "tan", "POST", "/v1/sessions/"+sid+"/share", map[string]any{"user": "bob", "level": "view"}, nil), 200, "share")
	must(t, call(t, a, "bob", "GET", "/v1/sessions/"+sid, nil, nil), 200, "bob reads shared")
	must(t, call(t, a, "bob", "POST", "/v1/sessions/"+sid+"/inputs", map[string]any{"key": "b1", "text": "x"}, nil), 403, "bob prompts with view share")
	var carolList []Meta
	call(t, a, "carol", "GET", "/v1/sessions", nil, &carolList)
	if len(carolList) != 0 {
		t.Fatal("carol sees unshared sessions")
	}
	must(t, call(t, a, "bob", "POST", "/v1/sessions", map[string]any{"harness": "pi", "key": "b"}, nil), 403, "bob spawns a runner he lacks")

	// The server copies the laptop's session byte for byte.
	b.PullOnce(ctx)
	if got, want := lines(t, b, sid), lines(t, a, sid); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatal("replica differs from source")
	}
	rawA, _ := os.ReadFile(filepath.Join(a.data, "sessions", sid, "raw-1.log"))
	rawB, _ := os.ReadFile(filepath.Join(b.data, "sessions", sid, "raw-1.log"))
	if len(rawA) == 0 || !bytes.Equal(rawA, rawB) {
		t.Fatalf("raw bytes not replicated (%d vs %d)", len(rawA), len(rawB))
	}

	// An input sent to the server is relayed to the writer (laptop).
	must(t, call(t, b, "tan", "POST", "/v1/sessions/"+sid+"/inputs", map[string]any{"key": "i2", "text": "relayed"}, nil), 200, "relay")
	waitMeta(t, a, sid, func(m Meta) bool { return idle(m) && m.Last == "turn 3: relayed" })

	// Handoff: the server asks the laptop to seal to it, pulls, takes over,
	// and the harness resumes from the checkpointed native transcript.
	var m Meta
	must(t, call(t, b, "tan", "POST", "/v1/sessions/"+sid+"/resume", nil, &m), 200, "resume on server")
	if m.Node != "server" || m.Run != 2 {
		t.Fatalf("after resume: %+v", m)
	}
	call(t, b, "tan", "POST", "/v1/sessions/"+sid+"/inputs", map[string]any{"key": "i3", "text": "on server"}, nil)
	waitMeta(t, b, sid, func(m Meta) bool { return idle(m) && m.Last == "turn 4: on server" })
	if err := a.Takeover(ctx, a.get(sid)); err == nil {
		t.Fatal("laptop took over a session sealed to the server")
	}
	if _, err := a.Seal(ctx, a.get(sid), "laptop"); err == nil {
		t.Fatal("laptop re-sealed a session it no longer writes")
	}
	a.PullOnce(ctx)
	if lastText(lines(t, a, sid)) != "turn 4: on server" {
		t.Fatal("laptop did not pull the server's run")
	}

	// Live SSE stream: catch up from an offset, then follow.
	req, _ := http.NewRequest("GET", b.srv.URL+"/v1/sessions/"+sid+"/events?after=3", nil)
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("X-Fleet-User", "tan")
	sctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	resp, err := http.DefaultClient.Do(req.WithContext(sctx))
	if err != nil {
		t.Fatal(err)
	}
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	first := ""
	for sc.Scan() {
		if strings.HasPrefix(sc.Text(), "id: ") {
			first = sc.Text()
			break
		}
	}
	if first != "id: 4" {
		t.Fatalf("SSE catch-up started at %q", first)
	}
	call(t, b, "tan", "POST", "/v1/sessions/"+sid+"/inputs", map[string]any{"key": "i4", "text": "live"}, nil)
	sawLive := false
	for sc.Scan() {
		if strings.Contains(sc.Text(), "turn 5: live") {
			sawLive = true
			break
		}
	}
	resp.Body.Close()
	if !sawLive {
		t.Fatal("SSE did not stream the live turn")
	}
	waitMeta(t, b, sid, idle)
	a.PullOnce(ctx)

	// A turn in flight when the writer dies is recorded as outcome-unknown.
	call(t, b, "tan", "POST", "/v1/sessions/"+sid+"/inputs", map[string]any{"key": "i5", "text": "SLOW"}, nil)
	waitMeta(t, b, sid, func(m Meta) bool { return m.State == "busy" })
	b.srv.Close()
	b.Node.Close()

	// The server is gone: relays fail loudly and the laptop forks instead.
	must(t, call(t, a, "tan", "POST", "/v1/sessions/"+sid+"/inputs", map[string]any{"key": "i6", "text": "x"}, nil), 503, "relay to dead writer")
	must(t, call(t, a, "tan", "POST", "/v1/sessions/"+sid+"/resume", nil, nil), 503, "resume from dead writer")
	var fk spawned
	must(t, call(t, a, "tan", "POST", "/v1/sessions/"+sid+"/fork", map[string]any{"key": "f1"}, &fk), 200, "fork")
	var fk2 spawned
	call(t, a, "tan", "POST", "/v1/sessions/"+sid+"/fork", map[string]any{"key": "f1"}, &fk2)
	if !fk2.Dup || fk2.Session.Sid != fk.Session.Sid {
		t.Fatal("fork retry made a second fork")
	}
	if fk.Session.ForkedFrom != sid {
		t.Fatalf("fork lineage: %+v", fk.Session)
	}
	call(t, a, "tan", "POST", "/v1/sessions/"+fk.Session.Sid+"/inputs", map[string]any{"key": "i7", "text": "forked"}, nil)
	waitMeta(t, a, fk.Session.Sid, func(m Meta) bool { return idle(m) && m.Last == "turn 6: forked" })

	// The server restarts: its in-flight turn shows as interrupted with the
	// unknown input listed; a new input starts a new run on the same history.
	b2 := &tnode{data: b.data, srv: httptest.NewUnstartedServer(nil)}
	start(t, b2, "server", []string{a.srv.URL})
	mb := waitMeta(t, b2, sid, func(m Meta) bool { return m.State == "interrupted" })
	if len(mb.Unknown) != 1 || mb.Unknown[0] != "input i5" {
		t.Fatalf("unknown outcomes: %v", mb.Unknown)
	}
	call(t, b2, "tan", "POST", "/v1/sessions/"+sid+"/inputs", map[string]any{"key": "i8", "text": "back"}, nil)
	mb = waitMeta(t, b2, sid, func(m Meta) bool { return idle(m) && strings.HasSuffix(m.Last, "back") })
	if mb.Last != "turn 6: back" || mb.Run != 3 {
		t.Fatalf("after restart: run %d %q", mb.Run, mb.Last)
	}

}

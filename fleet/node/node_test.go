package node

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/core"
	"github.com/TanGentleman/tan-toolchains/fleet/fake"
)

type testNode struct {
	*Node
	srv  *httptest.Server
	cfg  Config
	data string
}

func startNode(t *testing.T, name, data string) *testNode {
	t.Helper()
	tn := &testNode{data: data}
	var h http.Handler = http.NotFoundHandler()
	tn.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { h.ServeHTTP(w, r) }))
	tn.cfg = Config{
		Name: name, URL: tn.srv.URL, Data: data,
		Policy: core.Policy{Owners: []string{"tan"}},
		Harnesses: map[string]Harness{"fake": Func(func(ctx context.Context, t Turn, w io.Writer) (int, error) {
			return fake.Run(ctx, t.State, t.Prompt, w)
		})},
		Client: &http.Client{Timeout: 5 * time.Second},
	}
	n, err := New(tn.cfg)
	if err != nil {
		t.Fatal(err)
	}
	tn.Node, h = n, n.Handler()
	t.Cleanup(func() { tn.srv.Close(); n.Close() })
	return tn
}

// replies returns the fake harness's turn numbers seen in sid's output.
func replies(t *testing.T, n *Node, sid string) []int {
	t.Helper()
	lines, _, err := n.Events("tan", sid, 0)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var turns []int
	for _, l := range lines {
		var e core.Event
		json.Unmarshal(l, &e)
		if e.Kind != core.Out {
			continue
		}
		var s string
		json.Unmarshal(e.Data, &s)
		var m struct {
			Type string
			Turn int
		}
		if json.Unmarshal([]byte(s), &m); m.Type == "reply" {
			turns = append(turns, m.Turn)
		}
	}
	return turns
}

func waitTurns(t *testing.T, n *Node, sid string, want ...int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		got := replies(t, n, sid)
		st, _ := n.State("tan", sid)
		if len(got) >= len(want) && !st.Running {
			for i := range want {
				if got[i] != want[i] {
					t.Fatalf("turns %v, want %v", got, want)
				}
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out: turns %v, want %v", got, want)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func get(t *testing.T, url, login string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	if login != "" {
		req.Header.Set(LoginHeader, login)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var b bytes.Buffer
	b.ReadFrom(resp.Body)
	return resp.StatusCode, b.String()
}

func post(t *testing.T, url, login, body string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	req.Header.Set(LoginHeader, login)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var b bytes.Buffer
	b.ReadFrom(resp.Body)
	return resp.StatusCode, b.String()
}

func waitIdle(t *testing.T, n *Node, sid string) core.State {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if st, _ := n.State("tan", sid); !st.Running {
			return st
		}
	}
	t.Fatal("turn never ended")
	return core.State{}
}

// TestHandoff walks one session across two nodes: spawn on a, retry safely,
// share read-only, refuse a bogus seal, resume on b (a seals), lose b and
// fork on a from b's last finished turn, restart a.
func TestHandoff(t *testing.T) {
	a := startNode(t, "a", t.TempDir())
	b := startNode(t, "b", t.TempDir())

	sid, err := a.Spawn("tan", "fake", "", "demo", "k1", "hello")
	if err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a.Node, sid, 1)

	// Retried requests change nothing.
	if again, _ := a.Spawn("tan", "fake", "", "demo", "k1", "hello"); again != sid {
		t.Fatalf("retried spawn made %s", again)
	}
	s1, _ := a.Input("tan", sid, "i1", "two")
	s2, _ := a.Input("tan", sid, "i1", "two")
	if s1 == 0 || s1 != s2 {
		t.Fatalf("retried input: %d then %d", s1, s2)
	}
	waitTurns(t, a.Node, sid, 1, 2)

	// Default deny, then read-only share. An unknown level is refused, not
	// read as a revoke.
	if code, _ := get(t, a.srv.URL+"/v1/sessions/"+sid, ""); code != http.StatusUnauthorized {
		t.Fatalf("no identity: %d", code)
	}
	if code, _ := get(t, a.srv.URL+"/v1/sessions/"+sid, "bob"); code != http.StatusNotFound {
		t.Fatalf("stranger: %d", code)
	}
	if err := a.Share("tan", sid, "bob", core.View); err != nil {
		t.Fatal(err)
	}
	if code, _ := post(t, a.srv.URL+"/v1/sessions/"+sid+"/share", "tan", `{"user":"bob","level":"Admin"}`); code != http.StatusBadRequest {
		t.Fatalf("unknown level: %d", code)
	}
	if code, _ := get(t, a.srv.URL+"/v1/sessions/"+sid+"/events", "bob"); code != http.StatusOK {
		t.Fatalf("viewer read: %d", code)
	}
	if code, _ := post(t, a.srv.URL+"/v1/sessions/"+sid+"/inputs", "bob", `{"key":"x","text":"hi"}`); code != http.StatusForbidden {
		t.Fatalf("viewer write: %d", code)
	}

	// A seal to a node that is not at that URL is refused; a keeps writing.
	if code, body := post(t, a.srv.URL+"/v1/sessions/"+sid+"/seal", "tan", `{"to":"nope","url":"`+b.srv.URL+`"}`); code == http.StatusOK {
		t.Fatalf("sealed to a node that does not exist: %s", body)
	}
	if _, err := a.Input("tan", sid, "i2", "three"); err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a.Node, sid, 1, 2, 3)

	// Resume on b: a seals; b copies the log and checkpoint, and its next
	// turn continues the harness state (turn 4, not turn 1).
	if code, body := post(t, b.srv.URL+"/v1/sessions/"+sid+"/resume", "tan", `{"from":"`+a.srv.URL+`"}`); code != http.StatusOK {
		t.Fatalf("resume on b: %d %s", code, body)
	}
	if _, err := b.Input("tan", sid, "i3", "four"); err != nil {
		t.Fatal(err)
	}
	waitTurns(t, b.Node, sid, 1, 2, 3, 4)
	if _, err := a.Input("tan", sid, "i4", "nope"); !errors.Is(err, core.ErrNotWriter) {
		t.Fatalf("old writer accepted input: %v", err)
	}
	if _, err := b.Input("tan", sid, "i5", "five"); err != nil {
		t.Fatal(err)
	}
	waitTurns(t, b.Node, sid, 1, 2, 3, 4, 5)
	if err := a.Pull(context.Background(), b.srv.URL, sid, "tan"); err != nil {
		t.Fatal(err)
	}
	aLines, _, _ := a.Events("tan", sid, 0)
	bLines, _, _ := b.Events("tan", sid, 0)
	if len(aLines) != len(bLines) {
		t.Fatalf("copy has %d lines, writer %d", len(aLines), len(bLines))
	}
	for i := range aLines {
		if !bytes.Equal(aLines[i], bLines[i]) {
			t.Fatalf("copies differ at seq %d", i+1)
		}
	}

	// b vanishes. a cannot take the session back, but can fork it, and the
	// fork continues from b's last finished turn (6, not a stale 1).
	b.srv.Close()
	if err := a.Resume(context.Background(), "tan", sid, ""); !errors.Is(err, ErrUnreachable) {
		t.Fatalf("resume from dead writer: %v", err)
	}
	fid, err := a.Fork("tan", sid, "f1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Input("tan", fid, "i6", "fork"); err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a.Node, fid, 6)

	// a restarts: the fork carries on from its checkpoint.
	a.Close()
	a2, err := New(a.cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer a2.Close()
	if _, err := a2.Input("tan", fid, "i7", "again"); err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a2, fid, 6, 7)
}

// TestBusyAndAbort: one turn at a time; an input during a turn is refused,
// abort kills the turn and records it, and the next turn starts from the
// last checkpoint.
func TestBusyAndAbort(t *testing.T) {
	a := startNode(t, "a", t.TempDir())
	sid, err := a.Spawn("tan", "fake", "", "demo", "k1", "hello")
	if err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a.Node, sid, 1)
	if _, err := a.Input("tan", sid, "i1", "sleep"); err != nil {
		t.Fatal(err)
	}
	if code, _ := post(t, a.srv.URL+"/v1/sessions/"+sid+"/inputs", "tan", `{"key":"i2","text":"two"}`); code != http.StatusConflict {
		t.Fatalf("input during a turn: %d", code)
	}
	if code, body := post(t, a.srv.URL+"/v1/sessions/"+sid+"/abort", "tan", ``); code != http.StatusOK {
		t.Fatalf("abort: %d %s", code, body)
	}
	st := waitIdle(t, a.Node, sid)
	lines, _, _ := a.Events("tan", sid, st.Head-1)
	if !strings.Contains(string(lines[0]), `"reason":"aborted"`) {
		t.Fatalf("last event %s", lines[0])
	}
	if _, err := a.Input("tan", sid, "i2", "two"); err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a.Node, sid, 1, 2)
	if _, err := a.Input("tan", sid, "i3", "exit 7"); err != nil {
		t.Fatal(err)
	}
	st = waitIdle(t, a.Node, sid)
	lines, _, _ = a.Events("tan", sid, st.Head-1)
	if !strings.Contains(string(lines[0]), `"code":7`) {
		t.Fatalf("exit code not recorded: %s", lines[0])
	}
}

// TestExecAbortKillsGroup: aborting an Exec turn kills the harness and
// anything it started (an adapter's CLI), not just the direct child.
func TestExecAbortKillsGroup(t *testing.T) {
	data := t.TempDir()
	n, err := New(Config{Name: "a", Data: data, Policy: core.Policy{Owners: []string{"tan"}},
		Harnesses: map[string]Harness{"sh": Exec{Argv: []string{"sh", "-c", `sleep 30 & echo $! > child; echo started; wait`}}}})
	if err != nil {
		t.Fatal(err)
	}
	defer n.Close()
	sid, err := n.Spawn("tan", "sh", "", "", "k1", "go")
	if err != nil {
		t.Fatal(err)
	}
	pidFile := filepath.Join(data, "sessions", sid, "work", "child")
	var pid int
	for deadline := time.Now().Add(5 * time.Second); pid == 0; time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("harness never started")
		}
		b, _ := os.ReadFile(pidFile)
		pid, _ = strconv.Atoi(strings.TrimSpace(string(b)))
	}
	start := time.Now()
	if err := n.Abort("tan", sid); err != nil {
		t.Fatal(err)
	}
	if d := time.Since(start); d > 3*time.Second {
		t.Fatalf("abort took %v", d)
	}
	time.Sleep(50 * time.Millisecond)
	if err := syscall.Kill(pid, 0); err == nil {
		syscall.Kill(pid, syscall.SIGKILL)
		t.Fatal("grandchild survived abort")
	}
}

// TestBackgroundPull: a node listed as a peer copies sessions it can see
// without anyone asking, so they stay viewable when the writer goes away.
func TestBackgroundPull(t *testing.T) {
	a := startNode(t, "a", t.TempDir())
	sid, err := a.Spawn("tan", "fake", "", "demo", "k1", "hello")
	if err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a.Node, sid, 1)
	cfg := Config{Name: "c", Data: t.TempDir(), Policy: core.Policy{Owners: []string{"tan"}},
		Peers: []string{a.srv.URL}, PeerLogin: "tan", PullEvery: 20 * time.Millisecond}
	c, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	waitTurns(t, c, sid, 1)
	a.srv.Close()
	if st, err := c.State("tan", sid); err != nil || st.Writer != "a" {
		t.Fatalf("copy on c: %+v %v", st, err)
	}
}

func TestModelFollowsSessionAndForks(t *testing.T) {
	a := startNode(t, "a", t.TempDir())
	sid, err := a.Spawn("tan", "fake", "openai/gpt-5-nano", "demo", "k1", "hello")
	if err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a.Node, sid, 1)
	fid, err := a.Fork("tan", sid, "f1")
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{sid, fid} {
		if st, _ := a.State("tan", id); st.Model != "openai/gpt-5-nano" {
			t.Fatalf("%s model = %q", id, st.Model)
		}
	}
	for _, bad := range []string{"has space", "new\nline", strings.Repeat("x", 201)} {
		if _, err := a.Spawn("tan", "fake", bad, "demo", "k-"+bad, ""); err == nil {
			t.Errorf("accepted model %q", bad)
		}
	}
}

// TestRebindingAndFormPosts: a page that rebinds its own name to loopback
// sends that name in Host, and a cross-site form can only send text/plain or
// form types. Both are refused before the identity header is trusted.
func TestRebindingAndFormPosts(t *testing.T) {
	a := startNode(t, "a", t.TempDir())
	send := func(method, host, ctype, body string) int {
		req, _ := http.NewRequest(method, a.srv.URL+"/v1/sessions", strings.NewReader(body))
		req.Host = host
		req.Header.Set(LoginHeader, "tan")
		if ctype != "" {
			req.Header.Set("Content-Type", ctype)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	own := strings.TrimPrefix(a.srv.URL, "http://")
	spawn := `{"harness":"fake","key":"k1","prompt":"hello"}`
	for _, c := range []struct {
		method, host, ctype string
		want                int
	}{
		{"GET", "attacker.example:" + own[strings.LastIndex(own, ":")+1:], "", http.StatusMisdirectedRequest},
		{"POST", "attacker.example", "application/json", http.StatusMisdirectedRequest},
		{"POST", own, "text/plain", http.StatusUnsupportedMediaType},
		{"POST", own, "application/x-www-form-urlencoded", http.StatusUnsupportedMediaType},
		{"POST", own, "", http.StatusUnsupportedMediaType},
		{"GET", strings.ToUpper(own), "", http.StatusOK},
		{"POST", own, "application/json; charset=utf-8", http.StatusOK},
	} {
		if got := send(c.method, c.host, c.ctype, spawn); got != c.want {
			t.Errorf("%s Host=%s Content-Type=%q: %d, want %d", c.method, c.host, c.ctype, got, c.want)
		}
	}
	if list := a.List("tan"); len(list) != 1 {
		t.Fatalf("sessions after refused requests: %d, want 1", len(list))
	}
}

func TestHostOK(t *testing.T) {
	for _, c := range []struct {
		url, host string
		want      bool
	}{
		{"https://mac1.tail.ts.net", "mac1.tail.ts.net", true},
		{"https://mac1.tail.ts.net", "MAC1.tail.ts.net:443", true},
		{"https://mac1.tail.ts.net:443", "mac1.tail.ts.net", true},
		{"https://mac1.tail.ts.net", "mac1.tail.ts.net:7433", false},
		{"https://mac1.tail.ts.net", "evil.ts.net", false},
		{"https://mac1.tail.ts.net", "127.0.0.1:7433", true},
		{"https://mac1.tail.ts.net", "localhost:7433", true},
		{"https://mac1.tail.ts.net", "localhost:7434", false},
		{"", "", false},
	} {
		n := &Node{cfg: Config{URL: c.url, Hosts: []string{"127.0.0.1:7433", "localhost:7433"}}}
		if got := n.hostOK(c.host); got != c.want {
			t.Errorf("url %q host %q: %v, want %v", c.url, c.host, got, c.want)
		}
	}
}

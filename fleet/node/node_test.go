package node

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
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
		Policy:    core.Policy{Owners: []string{"tan"}},
		Harnesses: map[string]Harness{"fake": Func(fake.Run)},
		Client:    &http.Client{Timeout: 5 * time.Second},
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
		if len(got) >= len(want) {
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
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var b bytes.Buffer
	b.ReadFrom(resp.Body)
	return resp.StatusCode, b.String()
}

// TestHandoff walks one session across two nodes: spawn on a, retry safely,
// share read-only, resume on b (a seals), lose b and fork on a, restart a.
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
	s1, _ := a.Input("tan", sid, "i1", "prompt", "two")
	s2, _ := a.Input("tan", sid, "i1", "prompt", "two")
	if s1 == 0 || s1 != s2 {
		t.Fatalf("retried input: %d then %d", s1, s2)
	}
	waitTurns(t, a.Node, sid, 1, 2)

	// Default deny, then read-only share.
	if code, _ := get(t, a.srv.URL+"/v1/sessions/"+sid, ""); code != http.StatusUnauthorized {
		t.Fatalf("no identity: %d", code)
	}
	if code, _ := get(t, a.srv.URL+"/v1/sessions/"+sid, "bob"); code != http.StatusNotFound {
		t.Fatalf("stranger: %d", code)
	}
	if err := a.Share("tan", sid, "bob", core.View); err != nil {
		t.Fatal(err)
	}
	if code, _ := get(t, a.srv.URL+"/v1/sessions/"+sid+"/events", "bob"); code != http.StatusOK {
		t.Fatalf("viewer read: %d", code)
	}
	if code, _ := post(t, a.srv.URL+"/v1/sessions/"+sid+"/inputs", "bob", `{"key":"x","text":"hi"}`); code != http.StatusForbidden {
		t.Fatalf("viewer write: %d", code)
	}

	// Resume on b: a stops, checkpoints, seals; b copies and continues the
	// harness state (turn 3, not turn 1).
	if code, body := post(t, b.srv.URL+"/v1/sessions/"+sid+"/resume", "tan", `{"from":"`+a.srv.URL+`"}`); code != http.StatusOK {
		t.Fatalf("resume on b: %d %s", code, body)
	}
	if _, err := b.Input("tan", sid, "i2", "prompt", "three"); err != nil {
		t.Fatal(err)
	}
	waitTurns(t, b.Node, sid, 1, 2, 3)
	if _, err := a.Input("tan", sid, "i3", "prompt", "nope"); !errors.Is(err, core.ErrNotWriter) {
		t.Fatalf("old writer accepted input: %v", err)
	}
	aLines, _, _ := a.Events("tan", sid, 0)
	bLines, _, _ := b.Events("tan", sid, 0)
	for i := range aLines {
		if !bytes.Equal(aLines[i], bLines[i]) {
			t.Fatalf("copies differ at seq %d", i+1)
		}
	}

	// b vanishes mid-run. a cannot take the session back, but can fork it
	// from the last checkpoint it holds (after turn 2).
	b.srv.Close()
	b.Close()
	if err := a.Resume(context.Background(), "tan", sid, ""); !errors.Is(err, ErrUnreachable) {
		t.Fatalf("resume from dead writer: %v", err)
	}
	fid, err := a.Fork("tan", sid, "f1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Input("tan", fid, "i4", "prompt", "fork"); err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a.Node, fid, 3)

	// a restarts: the fork's run is recorded as interrupted, not re-run.
	a.Close()
	a2, err := New(a.cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer a2.Close()
	st, _ := a2.State("tan", fid)
	if st.Running {
		t.Fatal("run still marked running after restart")
	}
	if _, err := a2.Input("tan", fid, "i5", "prompt", "x"); !errors.Is(err, core.ErrNotRunning) {
		t.Fatalf("input after restart: %v", err)
	}
	if err := a2.Resume(context.Background(), "tan", fid, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := a2.Input("tan", fid, "i5", "prompt", "again"); err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a2, fid, 3, 4)
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

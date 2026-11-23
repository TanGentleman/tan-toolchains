package node

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
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

// TestLifecycle: spawn, retry safely, default deny and a read-only share,
// fork from the last finished turn, and continue after a restart.
func TestLifecycle(t *testing.T) {
	a := startNode(t, "a", t.TempDir())

	sid, err := a.Spawn("tan", "k1", "hello", core.CreatedData{Harness: "fake", Title: "demo"})
	if err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a.Node, sid, 1)

	// Retried requests change nothing.
	if again, _ := a.Spawn("tan", "k1", "hello", core.CreatedData{Harness: "fake", Title: "demo"}); again != sid {
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

	// A fork continues from the parent's last finished turn (3, not 1).
	fid, err := a.Fork("tan", sid, "f1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Input("tan", fid, "i2", "fork"); err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a.Node, fid, 3)

	// a restarts: the fork carries on from its checkpoint.
	a.Close()
	a2, err := New(a.cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer a2.Close()
	if _, err := a2.Input("tan", fid, "i3", "again"); err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a2, fid, 3, 4)
}

// TestBusyAndAbort: one turn at a time; an input during a turn is refused,
// abort kills the turn and records it, and the next turn starts from the
// last checkpoint.
func TestBusyAndAbort(t *testing.T) {
	a := startNode(t, "a", t.TempDir())
	sid, err := a.Spawn("tan", "k1", "hello", core.CreatedData{Harness: "fake", Model: "", Title: "demo"})
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
	sid, err := n.Spawn("tan", "k1", "go", core.CreatedData{Harness: "sh", Model: "", Title: ""})
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
	if alive(pid) {
		syscall.Kill(pid, syscall.SIGKILL)
		t.Fatal("grandchild survived abort")
	}
}

// alive reports whether pid is running. A zombie (killed, but its new parent
// has not reaped it, as in containers whose PID 1 never does) counts as dead.
func alive(pid int) bool {
	if syscall.Kill(pid, 0) != nil {
		return false
	}
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return true // no /proc (macOS): launchd reaps, so kill(0) is enough
	}
	_, rest, _ := strings.Cut(string(b), ") ")
	return !strings.HasPrefix(rest, "Z")
}

func TestModelFollowsSessionAndForks(t *testing.T) {
	a := startNode(t, "a", t.TempDir())
	sid, err := a.Spawn("tan", "k1", "hello", core.CreatedData{Harness: "fake", Model: "openai/gpt-6-luna", Title: "demo"})
	if err != nil {
		t.Fatal(err)
	}
	waitTurns(t, a.Node, sid, 1)
	fid, err := a.Fork("tan", sid, "f1")
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{sid, fid} {
		if st, _ := a.State("tan", id); st.Model != "openai/gpt-6-luna" {
			t.Fatalf("%s model = %q", id, st.Model)
		}
	}
	for _, bad := range []string{"has space", "new\nline", strings.Repeat("x", 201)} {
		if _, err := a.Spawn("tan", "k-"+bad, "", core.CreatedData{Harness: "fake", Model: bad, Title: "demo"}); err == nil {
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
		{"https://mac1.tail.ts.net.", "mac1.tail.ts.net", true},
		{"https://mac1.tail.ts.net", "mac1.tail.ts.net.", true},
		{"https://mac1.tail.ts.net", "mac1.tail.ts.net.evil.example", false},
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

// TestExecDropAndModes: a harness doesn't get the variables it should not see,
// still gets fleet's, and nothing a turn leaves in the data dir is readable
// by other users, including a data dir an older fleetd made 0755.
func TestExecDropAndModes(t *testing.T) {
	data := t.TempDir()
	if err := os.Chmod(data, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("OPENROUTER_API_KEY", "sk-or-v1-real")
	t.Setenv("FLEET_TEST_KEEP", "kept")
	n, err := New(Config{Name: "a", Data: data, Policy: core.Policy{Owners: []string{"tan"}},
		Harnesses: map[string]Harness{"sh": Exec{Argv: []string{"sh", "-c", `env > "$FLEET_STATE/env"; echo hi >&2`},
			Env: []string{"FLEET_TEST_ADDED=added"}, Drop: []string{"OPENROUTER_API_KEY"}}}})
	if err != nil {
		t.Fatal(err)
	}
	defer n.Close()
	sid, err := n.Spawn("tan", "k1", "go", core.CreatedData{Harness: "sh", Model: "", Title: ""})
	if err != nil {
		t.Fatal(err)
	}
	waitIdle(t, n, sid)
	b, err := os.ReadFile(filepath.Join(data, "sessions", sid, "state", "env"))
	if err != nil {
		t.Fatal(err)
	}
	env := string(b)
	if strings.Contains(env, "sk-or-v1-real") {
		t.Fatal("harness saw OPENROUTER_API_KEY")
	}
	for _, want := range []string{"FLEET_TEST_KEEP=kept", "FLEET_TEST_ADDED=added", "FLEET_SID=" + sid, "FLEET_WORK=", "FLEET_STATE="} {
		if !strings.Contains(env, want) {
			t.Errorf("harness env lacks %s", want)
		}
	}
	files := 0
	filepath.WalkDir(data, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			t.Fatal(err)
		}
		fi, _ := d.Info()
		if perm := fi.Mode().Perm(); perm&0o077 != 0 {
			t.Errorf("%s: %v, open to others", p, perm)
		}
		files++
		if d.IsDir() && (d.Name() == "state" || d.Name() == "work") {
			return filepath.SkipDir // the harness's own files; the 0700 dirs above cover them
		}
		return nil
	})
	if files < 4 {
		t.Fatalf("walked %d paths; expected the log, stderr and checkpoint blobs", files)
	}
}

// TestAbortKeepsCheckpoint: an aborted turn gets SIGTERM first, so a harness
// can stop cleanly, and whatever it half wrote to $FLEET_STATE is not
// checkpointed: the next turn sees the state of the last finished one.
// A harness that ignores SIGTERM is killed after the grace period.
func TestAbortKeepsCheckpoint(t *testing.T) {
	data := t.TempDir()
	script := `read p
case "$p" in
first) echo one > "$FLEET_STATE/f" ;;
partial) echo half > "$FLEET_STATE/f"; trap 'echo term > "$FLEET_WORK/term"; exit 143' TERM
  touch "$FLEET_WORK/started"; sleep 30 & wait ;;
stubborn) trap '' TERM; touch "$FLEET_WORK/started"; sleep 30 & wait; sleep 30 ;;
*) echo "state=$(cat "$FLEET_STATE/f")" ;;
esac`
	n, err := New(Config{Name: "a", Data: data, Policy: core.Policy{Owners: []string{"tan"}},
		Harnesses: map[string]Harness{"sh": Exec{Argv: []string{"sh", "-c", script}, Grace: 300 * time.Millisecond}}})
	if err != nil {
		t.Fatal(err)
	}
	defer n.Close()
	sid, err := n.Spawn("tan", "k1", "first", core.CreatedData{Harness: "sh", Model: "", Title: ""})
	if err != nil {
		t.Fatal(err)
	}
	before := waitIdle(t, n, sid).Files
	work := filepath.Join(data, "sessions", sid, "work")
	abortWhenStarted := func(key, prompt string) time.Duration {
		os.Remove(filepath.Join(work, "started"))
		if _, err := n.Input("tan", sid, key, prompt); err != nil {
			t.Fatal(err)
		}
		for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
			if _, err := os.Stat(filepath.Join(work, "started")); err == nil {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("%s never started", prompt)
			}
		}
		start := time.Now()
		if err := n.Abort("tan", sid); err != nil {
			t.Fatal(err)
		}
		return time.Since(start)
	}
	abortWhenStarted("i1", "partial")
	if b, _ := os.ReadFile(filepath.Join(work, "term")); string(b) != "term\n" {
		t.Fatal("harness never got SIGTERM")
	}
	st := waitIdle(t, n, sid)
	if !slices.Equal(st.Files, before) {
		t.Fatalf("aborted turn was checkpointed: %v, want %v", st.Files, before)
	}
	if d := abortWhenStarted("i2", "stubborn"); d < 300*time.Millisecond || d > 3*time.Second {
		t.Fatalf("stubborn harness stopped after %v, want the 300ms grace", d)
	}
	if _, err := n.Input("tan", sid, "i3", "show"); err != nil {
		t.Fatal(err)
	}
	st = waitIdle(t, n, sid)
	lines, _, _ := n.Events("tan", sid, 0)
	if all := string(bytes.Join(lines, nil)); !strings.Contains(all, "state=one") || strings.Contains(all, "state=half") {
		t.Fatalf("next turn did not start from the last checkpoint:\n%s", all)
	}
}

// TestCloseAbortsInParallel: shutdown stops every running turn at once, so
// turns that ignore SIGTERM cost one grace period in total, not one each.
func TestCloseAbortsInParallel(t *testing.T) {
	data := t.TempDir()
	n, err := New(Config{Name: "a", Data: data, Policy: core.Policy{Owners: []string{"tan"}},
		Harnesses: map[string]Harness{"sh": Exec{Argv: []string{"sh", "-c", `trap '' TERM; touch "$FLEET_WORK/started"; sleep 30`}, Grace: time.Second}}})
	if err != nil {
		t.Fatal(err)
	}
	var sids []string
	for i := range 3 {
		sid, err := n.Spawn("tan", fmt.Sprint("k", i), "go", core.CreatedData{Harness: "sh"})
		if err != nil {
			t.Fatal(err)
		}
		sids = append(sids, sid)
	}
	for _, sid := range sids {
		for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
			if _, err := os.Stat(filepath.Join(data, "sessions", sid, "work", "started")); err == nil {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("turn never started")
			}
		}
	}
	start := time.Now()
	n.Close()
	if d := time.Since(start); d > 2500*time.Millisecond {
		t.Fatalf("Close took %v for 3 turns with a 1s grace", d)
	}
}

func TestRepoTurnResult(t *testing.T) {
	sha1, sha2 := strings.Repeat("a1", 20), strings.Repeat("b2", 20)
	data := t.TempDir()
	// The prompt is the result file's content; "-" writes nothing.
	sh := `env | grep '^FLEET_' > "$FLEET_WORK/env-$FLEET_SID"; p=$(cat); [ "$p" = - ] || printf '%s' "$p" > "$FLEET_RESULT"; [ "$p" != fail ] || exit 3`
	n, err := New(Config{Name: "a", Data: data, Policy: core.Policy{Owners: []string{"tan"}},
		Harnesses: map[string]Harness{"sh": Exec{Argv: []string{"sh", "-c", sh}}},
		Sandboxes: map[string]string{"sh": "test-box"}})
	if err != nil {
		t.Fatal(err)
	}
	defer n.Close()
	for _, bad := range []core.CreatedData{{Harness: "sh", Repo: "nope"}, {Harness: "sh", Branch: "main"}, {Harness: "sh", Repo: "o/r", Branch: "-x"}} {
		if _, err := n.Spawn("tan", "bad-"+bad.Repo+bad.Branch, "", bad); err == nil {
			t.Errorf("spawned %+v", bad)
		}
	}
	sid, err := n.Spawn("tan", "k1", fmt.Sprintf(`{"commit":%q,"base":%q}`, sha2, sha1), core.CreatedData{Harness: "sh", Repo: "o/r", Branch: "dev"})
	if err != nil {
		t.Fatal(err)
	}
	st := waitIdle(t, n, sid)
	if st.Sandbox != "test-box" || st.Base != sha1 || st.Commit != sha2 {
		t.Fatalf("after turn 1: %+v", st)
	}
	b, _ := os.ReadFile(filepath.Join(data, "sessions", sid, "work", "env-"+sid))
	for _, want := range []string{"FLEET_REPO=o/r", "FLEET_BRANCH=dev", "FLEET_PUSH=fleet/" + sid, "FLEET_RESULT=" + filepath.Join(data, "sessions", sid, "result-1.json")} {
		if !strings.Contains(string(b), want) {
			t.Errorf("turn 1 env lacks %s:\n%s", want, b)
		}
	}
	if strings.Contains(string(b), "FLEET_BASE=") {
		t.Error("turn 1 got a base before one was recorded")
	}

	turn := func(prompt string) core.State {
		t.Helper()
		if _, err := n.Input("tan", sid, prompt, prompt); err != nil {
			t.Fatal(err)
		}
		return waitIdle(t, n, sid)
	}
	for _, bad := range []string{`not json`, `{"commit":"abc"}`, `{"commit":"` + strings.ToUpper(sha2) + `"}`, `{"commit":"` + sha2 + `","base":"` + sha2 + `"}`} {
		if st := turn(bad); st.Commit != sha2 || st.Base != sha1 {
			t.Fatalf("result %s was not ignored: %+v", bad, st)
		}
		if r := lastExit(t, n, sid); !strings.Contains(r.Reason, "result ignored") || r.Commit != "" {
			t.Fatalf("result %s: exit %+v", bad, r)
		}
	}
	if st := turn(`{"error":"push refused: big.bin is too big"}`); st.Commit != sha2 {
		t.Fatalf("error-only result changed the commit: %+v", st)
	}
	if r := lastExit(t, n, sid); r.Reason != "push refused: big.bin is too big" {
		t.Fatalf("reported error not in exit reason: %+v", r)
	}
	if turn(`{"error":"two\nlines"}`); !strings.Contains(lastExit(t, n, sid).Reason, "result ignored") {
		t.Fatal("multi-line error accepted")
	}
	if st := turn("-"); st.Commit != sha2 {
		t.Fatalf("no result file changed the commit: %+v", st)
	}
	b, _ = os.ReadFile(filepath.Join(data, "sessions", sid, "work", "env-"+sid))
	if !strings.Contains(string(b), "FLEET_BASE="+sha1) {
		t.Errorf("later turns lack the recorded base:\n%s", b)
	}

	fid, err := n.Fork("tan", sid, "f1")
	if err != nil {
		t.Fatal(err)
	}
	fs, _ := n.State("tan", fid)
	if fs.Repo != "o/r" || fs.Branch != "dev" || fs.Base != sha2 || fs.Commit != "" || fs.Sandbox != "test-box" {
		t.Fatalf("fork must start from the parent's last pushed commit: %+v", fs)
	}
}

func lastExit(t *testing.T, n *Node, sid string) core.ExitedData {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(n.cfg.Data, "sessions", sid, "events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	var x core.ExitedData
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		var e core.Event
		if json.Unmarshal([]byte(line), &e) == nil && e.Kind == core.Exited {
			x = core.ExitedData{}
			json.Unmarshal(e.Data, &x)
		}
	}
	return x
}

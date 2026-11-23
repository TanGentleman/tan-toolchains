package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/core"
	"github.com/TanGentleman/tan-toolchains/fleet/node"
)

// buildFleetd builds the real daemon binary, whose `agent` mode is the
// harness fleetd registers for pi, claude and codex.
func buildFleetd(t *testing.T) string {
	t.Helper()
	exe := filepath.Join(t.TempDir(), "fleetd")
	if out, err := exec.Command("go", "build", "-o", exe, "../cmd/fleetd").CombinedOutput(); err != nil {
		t.Fatalf("build fleetd: %v\n%s", err, out)
	}
	return exe
}

func fleetNode(t *testing.T, name string, h node.Harness, kind string) (*node.Node, string) {
	t.Helper()
	var hh http.Handler = http.NotFoundHandler()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hh.ServeHTTP(w, r) }))
	n, err := node.New(node.Config{
		Name: name, URL: srv.URL, Data: t.TempDir(),
		Policy:    core.Policy{Owners: []string{"tan"}},
		Harnesses: map[string]node.Harness{kind: h},
		Client:    &http.Client{Timeout: 10 * time.Second},
	})
	if err != nil {
		t.Fatal(err)
	}
	hh = n.Handler()
	urls[n] = srv.URL
	t.Cleanup(func() { srv.Close(); n.Close() })
	return n, srv.URL
}

// output is the concatenated harness stdout recorded in sid's log.
func output(t *testing.T, n *node.Node, sid string) string {
	lines, _, err := n.Events("tan", sid, 0)
	if err != nil {
		return ""
	}
	var b strings.Builder
	for _, l := range lines {
		var e core.Event
		json.Unmarshal(l, &e)
		if e.Kind == core.Out {
			var s string
			json.Unmarshal(e.Data, &s)
			b.WriteString(s + "\n")
		}
	}
	return b.String()
}

func waitFor(t *testing.T, n *node.Node, sid, want string, d time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(d)
	for {
		out := output(t, n, sid)
		if strings.Contains(out, want) {
			return out
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s: never saw %q in:\n%s", n.Name(), want, out)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// waitTurn waits for the n-th fleet.turn_end and returns the output after
// the previous one.
func waitTurn(t *testing.T, n *node.Node, sid string, turn int, d time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(d)
	for {
		out := output(t, n, sid)
		parts := strings.Split(out, `"type":"fleet.turn_end"`)
		if len(parts) > turn {
			return parts[turn-1]
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s: turn %d never ended:\n%s", n.Name(), turn, out)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// TestFleetHandoff runs each real CLI under two fleet nodes: spawn on A,
// resume on B (seal, log pull, checkpoint restore), prompt on B, and check
// the CLI saw A's turn. It is the same path a phone or Slack client drives.
func TestFleetHandoff(t *testing.T) {
	exe := buildFleetd(t)
	for _, kind := range kinds {
		t.Run(kind, func(t *testing.T) {
			b := bin(t, kind)
			w := newWorld(t, "127.0.0.1,localhost")
			h := node.Exec{Argv: []string{exe, "agent", kind}, Env: []string{
				"FLEET_MODEL=fake/node-default", "FLEET_" + strings.ToUpper(kind) + "_BIN=" + b,
				"OPENROUTER_API_KEY=" + fakeKey, "FLEET_OPENROUTER_BASE=" + w.base,
			}}
			a, _ := fleetNode(t, "a", h, kind)
			bn, _ := fleetNode(t, "b", h, kind)
			sid, err := a.Spawn("tan", "k1", "hello TOKALPHA", core.CreatedData{Harness: kind, Model: "fake/session-model", Title: "demo"})
			if err != nil {
				t.Fatal(err)
			}
			waitFor(t, a, sid, "seen TOKALPHA", 60*time.Second)
			waitTurn(t, a, sid, 1, 60*time.Second)
			if err := bn.Resume(context.Background(), "tan", sid, nodeURL(t, a)); err != nil {
				t.Fatal(err)
			}
			if _, err := bn.Input("tan", sid, "i2", "again TOKBRAVO"); err != nil {
				t.Fatal(err)
			}
			waitFor(t, bn, sid, "seen TOKALPHA TOKBRAVO", 60*time.Second)
			if hs := w.trap.Hosts(); len(hs) > 0 {
				t.Fatalf("non-model traffic: %v", hs)
			}
			// The model chosen at spawn wins over each node's default, on
			// both nodes.
			for _, r := range w.srv.Requests() {
				if r.Model != "fake/session-model" {
					t.Fatalf("%s sent model %q, want fake/session-model", r.Path, r.Model)
				}
			}
			waitTurn(t, bn, sid, 2, 60*time.Second)
			for _, s := range bn.List("tan") {
				if s.Sid == sid && (s.Usage != node.Usage{Input: 20, Output: 10}) {
					t.Fatalf("usage on b after handoff = %+v, want 20/10", s.Usage)
				}
			}
			if st, _ := bn.State("tan", sid); st.Model != "fake/session-model" {
				t.Fatalf("state model = %q", st.Model)
			}
			if _, err := bn.Spawn("tan", "k9", "", core.CreatedData{Harness: kind, Model: "bad model", Title: "x"}); err == nil {
				t.Fatal("accepted a model id with a space")
			}
			if strings.Contains(output(t, bn, sid), fakeKey) {
				t.Fatal("API key in the session log")
			}
		})
	}
}

var urls = map[*node.Node]string{}

func nodeURL(t *testing.T, n *node.Node) string { return urls[n] }

// TestLive talks to the real OpenRouter. It needs FLEET_LIVE=1 and
// OPENROUTER_API_KEY, costs a few cents, and is never run by CI. Models
// default to cheap ones; override with FLEET_LIVE_<KIND>_MODEL.
func TestLive(t *testing.T) {
	key := os.Getenv("OPENROUTER_API_KEY")
	if os.Getenv("FLEET_LIVE") != "1" || key == "" {
		t.Skip("set FLEET_LIVE=1 and OPENROUTER_API_KEY")
	}
	for _, kind := range kinds {
		t.Run(kind, func(t *testing.T) {
			b := bin(t, kind)
			model := liveModels[kind]
			w := newWorld(t, "openrouter.ai,.openrouter.ai,127.0.0.1,localhost")
			root := t.TempDir()
			cfg := func(n string) Config {
				os.MkdirAll(filepath.Join(root, n, "work"), 0o755)
				return Config{Kind: kind, Model: model, Bin: b, Key: key,
					State: filepath.Join(root, n, "state"), Work: filepath.Join(root, n, "work")}
			}
			a := start(t, cfg("a"))
			out, end := a.turn("t1", "Remember the codeword TOKZEBRA. Reply with only the word OK.")
			if end == nil || end["code"].(float64) != 0 {
				t.Fatalf("turn 1: %v\n%s\nstderr:\n%s", end, strings.Join(out, "\n"), a.errb)
			}
			a.close()
			os.MkdirAll(filepath.Join(root, "b"), 0o755)
			copyDir(t, filepath.Join(root, "a", "state"), filepath.Join(root, "b", "state"))
			bs := start(t, cfg("b"))
			out, end = bs.turn("t2", "What was the codeword? Reply with only the codeword.")
			if end == nil || end["code"].(float64) != 0 || !contains(out, "TOKZEBRA") {
				t.Fatalf("turn 2 forgot the codeword: %v\n%s\nstderr:\n%s", end, strings.Join(out, "\n"), bs.errb)
			}
			bs.close()
			if hs := w.trap.Hosts(); len(hs) > 0 {
				t.Fatalf("traffic besides openrouter.ai: %v", hs)
			}
			noSecret(t, key, root, strings.Join(a.all, "\n"), strings.Join(bs.all, "\n"), a.errb.String(), bs.errb.String())
		})
	}
}

// Cheap defaults for live runs; override with FLEET_LIVE_<KIND>_MODEL.
var liveModels = func() map[string]string {
	m := map[string]string{"pi": "deepseek/deepseek-v4.1-flash", "claude": "anthropic/claude-haiku-4.5", "codex": "openai/gpt-5.1-codex-mini"}
	for k := range m {
		if v := os.Getenv("FLEET_LIVE_" + strings.ToUpper(k) + "_MODEL"); v != "" {
			m[k] = v
		}
	}
	return m
}()

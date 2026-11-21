package agent

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/fakeor"
)

const fakeKey = "sk-or-v1-fake-0123456789"

var kinds = []string{"pi", "claude", "codex"}

// bin finds a real CLI: FLEET_<KIND>_BIN, else PATH. Tests skip without it.
func bin(t *testing.T, kind string) string {
	t.Helper()
	if b := os.Getenv("FLEET_" + strings.ToUpper(kind) + "_BIN"); b != "" {
		return b
	}
	b, err := exec.LookPath(kind)
	if err != nil {
		t.Skipf("%s not installed (set FLEET_%s_BIN)", kind, strings.ToUpper(kind))
	}
	return b
}

type world struct {
	srv  *fakeor.Server
	trap *fakeor.Trap
	base string
}

// newWorld starts a fake OpenRouter and routes every other host to a trap.
func newWorld(t *testing.T, noProxy string) *world {
	w := &world{srv: &fakeor.Server{Key: fakeKey}, trap: &fakeor.Trap{}}
	s := httptest.NewServer(w.srv)
	tr := httptest.NewServer(w.trap)
	t.Cleanup(s.Close)
	t.Cleanup(tr.Close)
	w.base = s.URL
	for _, k := range []string{"HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"} {
		t.Setenv(k, tr.URL)
	}
	t.Setenv("NO_PROXY", noProxy)
	t.Setenv("no_proxy", noProxy)
	t.Setenv("NODE_USE_ENV_PROXY", "1")
	return w
}

// session drives one adapter process, one turn at a time.
type session struct {
	t     *testing.T
	in    *io.PipeWriter
	lines chan string
	done  chan error
	all   []string
	errb  *bytes.Buffer
}

func start(t *testing.T, c Config) *session {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := &session{t: t, in: inW, lines: make(chan string, 4096), done: make(chan error, 1), errb: &bytes.Buffer{}}
	go func() {
		err := Run(c, inR, outW, s.errb)
		outW.Close()
		inR.Close()
		s.done <- err
	}()
	go func() {
		sc := bufio.NewScanner(outR)
		sc.Buffer(make([]byte, 1<<20), 16<<20)
		for sc.Scan() {
			s.lines <- sc.Text()
		}
		close(s.lines)
	}()
	return s
}

// turn sends a prompt and returns its output lines through fleet.turn_end.
func (s *session) turn(id, text string) (out []string, end map[string]any) {
	b, _ := json.Marshal(map[string]string{"type": "prompt", "id": id, "message": text})
	go s.in.Write(append(b, '\n'))
	timeout := time.After(120 * time.Second)
	for {
		select {
		case l, ok := <-s.lines:
			if !ok {
				return out, nil
			}
			s.all = append(s.all, l)
			out = append(out, l)
			var m map[string]any
			if json.Unmarshal([]byte(l), &m) == nil && m["type"] == "fleet.turn_end" {
				return out, m
			}
		case <-timeout:
			s.t.Fatalf("turn %s timed out; stderr:\n%s", id, s.errb)
		}
	}
}

func (s *session) close() error {
	s.in.Close()
	for l := range s.lines {
		s.all = append(s.all, l)
	}
	return <-s.done
}

func copyDir(t *testing.T, src, dst string) {
	t.Helper()
	if out, err := exec.Command("cp", "-a", src, dst).CombinedOutput(); err != nil {
		t.Fatalf("cp: %v %s", err, out)
	}
}

func contains(lines []string, s string) bool {
	for _, l := range lines {
		if strings.Contains(l, s) {
			return true
		}
	}
	return false
}

func noSecret(t *testing.T, key, dir string, outputs ...string) {
	t.Helper()
	for _, o := range outputs {
		if strings.Contains(o, key) {
			t.Fatal("API key leaked into adapter output")
		}
	}
	filepath.Walk(dir, func(p string, fi os.FileInfo, err error) error {
		if err == nil && fi.Mode().IsRegular() {
			if b, _ := os.ReadFile(p); bytes.Contains(b, []byte(key)) {
				t.Fatalf("API key written to checkpointed state: %s", p)
			}
		}
		return nil
	})
}

// TestResumeOnAnotherNode runs a turn, copies the state directory to a new
// location with a new working directory (what a fleet checkpoint and handoff
// does), and checks the next turn still sees the first turn's token, that no
// traffic besides model calls left the process, and that the key stayed out
// of output and state. Then it deletes the native session and checks the
// adapter refuses to continue.
func TestResumeOnAnotherNode(t *testing.T) {
	for _, kind := range kinds {
		t.Run(kind, func(t *testing.T) {
			b := bin(t, kind)
			w := newWorld(t, "127.0.0.1,localhost")
			root := t.TempDir()
			cfg := func(n string) Config {
				os.MkdirAll(filepath.Join(root, n, "work"), 0o755)
				return Config{Kind: kind, Model: "fake/model", Bin: b, Key: fakeKey, Base: w.base,
					State: filepath.Join(root, n, "state"), Work: filepath.Join(root, n, "work")}
			}

			a := start(t, cfg("a"))
			out, end := a.turn("t1", "hello TOKALPHA")
			if !contains(out, "seen TOKALPHA") || end == nil || end["code"].(float64) != 0 {
				t.Fatalf("first turn: end=%v\n%s\nstderr:\n%s", end, strings.Join(out, "\n"), a.errb)
			}
			if err := a.close(); err != nil {
				t.Fatal(err)
			}
			os.MkdirAll(filepath.Join(root, "b"), 0o755)
			copyDir(t, filepath.Join(root, "a", "state"), filepath.Join(root, "b", "state"))

			bs := start(t, cfg("b"))
			out, end = bs.turn("t2", "again TOKBRAVO")
			if !contains(out, "seen TOKALPHA TOKBRAVO") {
				t.Fatalf("resumed turn lost history: end=%v\n%s\nstderr:\n%s", end, strings.Join(out, "\n"), bs.errb)
			}
			out, _ = bs.turn("t3", "third TOKCHARLIE")
			if !contains(out, "seen TOKALPHA TOKBRAVO TOKCHARLIE") {
				t.Fatalf("third turn lost history:\n%s", strings.Join(out, "\n"))
			}
			if err := bs.close(); err != nil {
				t.Fatal(err)
			}

			if h := w.trap.Hosts(); len(h) > 0 {
				t.Fatalf("non-model traffic: %v", h)
			}
			for _, r := range w.srv.Requests() {
				if r.Auth != "bearer" {
					t.Fatalf("request %s %s used auth %q", r.Method, r.Path, r.Auth)
				}
			}
			noSecret(t, fakeKey, root, strings.Join(a.all, "\n"), strings.Join(bs.all, "\n"), a.errb.String(), bs.errb.String())

			// Drop the native session: the adapter must refuse, not start over.
			os.MkdirAll(filepath.Join(root, "c"), 0o755)
			copyDir(t, filepath.Join(root, "b", "state"), filepath.Join(root, "c", "state"))
			native := map[string]string{"pi": "pi/sessions", "claude": "claude/projects", "codex": "codex/sessions"}[kind]
			os.RemoveAll(filepath.Join(root, "c", "state", native))
			if kind == "codex" {
				for _, f := range must(filepath.Glob(filepath.Join(root, "c", "state", "codex", "*.sqlite*"))) {
					os.Remove(f)
				}
			}
			cs := start(t, cfg("c"))
			out, _ = cs.turn("t4", "lost TOKDELTA")
			err := cs.close()
			if !errors.Is(err, ErrSession) {
				t.Fatalf("missing native session: err=%v\n%s\nstderr:\n%s", err, strings.Join(out, "\n"), cs.errb)
			}
			if contains(out, "seen TOKDELTA") {
				t.Fatal("adapter silently started a fresh conversation")
			}
		})
	}
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

// fakeCLI writes a shell script standing in for a CLI.
func fakeCLI(t *testing.T, script string) string {
	p := filepath.Join(t.TempDir(), "cli")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func baseCfg(t *testing.T, kind, b string) Config {
	d := t.TempDir()
	os.MkdirAll(filepath.Join(d, "work"), 0o755)
	return Config{Kind: kind, Model: "m", Bin: b, Key: fakeKey, Base: "http://127.0.0.1:1",
		State: filepath.Join(d, "state"), Work: filepath.Join(d, "work")}
}

func TestRefusals(t *testing.T) {
	c := baseCfg(t, "claude", "true")
	for name, mut := range map[string]func(*Config){
		"unknown kind": func(c *Config) { c.Kind = "aider" },
		"no key":       func(c *Config) { c.Key = "" },
		"no model":     func(c *Config) { c.Model = "" },
	} {
		cc := c
		mut(&cc)
		if err := Run(cc, strings.NewReader(""), io.Discard, io.Discard); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	os.MkdirAll(c.State, 0o700)
	os.WriteFile(filepath.Join(c.State, "agent.json"), []byte(`{"kind":"pi","session":"x"}`), 0o600)
	if err := Run(c, strings.NewReader(""), io.Discard, io.Discard); err == nil || !strings.Contains(err.Error(), "belongs to") {
		t.Errorf("state from another kind: %v", err)
	}
}

// A CLI that reports a different session than the one resumed is a fresh
// conversation in disguise; the adapter must stop.
func TestSessionMismatch(t *testing.T) {
	cli := fakeCLI(t, `cat >/dev/null; echo '{"type":"system","subtype":"init","session_id":"someone-else"}'`)
	c := baseCfg(t, "claude", cli)
	os.MkdirAll(c.State, 0o700)
	os.WriteFile(filepath.Join(c.State, "agent.json"), []byte(`{"kind":"claude","session":"mine","turns":1}`), 0o600)
	s := start(t, c)
	s.turn("t", "hi")
	if err := s.close(); !errors.Is(err, ErrSession) {
		t.Fatalf("err = %v", err)
	}
}

// The child sees only allowlisted variables plus the opt-outs; the key is
// scrubbed from anything it prints.
func TestChildEnvironment(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "ghp_should_not_leak")
	t.Setenv("ANTHROPIC_API_KEY", "sk-ant-should-not-leak")
	for _, kind := range kinds {
		cli := fakeCLI(t, `cat >/dev/null; env | sort; echo '{"type":"session","id":"s1"}'; echo '{"type":"system","subtype":"init","session_id":"s1"}'; echo '{"type":"thread.started","thread_id":"s1"}'`)
		c := baseCfg(t, kind, cli)
		s := start(t, c)
		out, end := s.turn("t", "hi")
		s.close()
		all := strings.Join(out, "\n")
		if end == nil || end["code"].(float64) != 0 {
			t.Fatalf("%s: %v\n%s", kind, end, all)
		}
		if strings.Contains(all, "ghp_should_not_leak") || strings.Contains(all, "sk-ant-should-not-leak") {
			t.Errorf("%s: host credential reached the child", kind)
		}
		if strings.Contains(all, fakeKey) || !strings.Contains(all, "[redacted]") {
			t.Errorf("%s: key not passed or not scrubbed", kind)
		}
		want := append([]string{"DO_NOT_TRACK=1", "HOME=" + filepath.Join(c.State, "home")}, kindEnv[kind]...)
		if kind == "claude" {
			want = append(want, "ANTHROPIC_API_KEY=", "ANTHROPIC_BASE_URL=http://127.0.0.1:1", "ANTHROPIC_AUTH_TOKEN=[redacted]")
		}
		for _, w := range want {
			if !contains(out, w) {
				t.Errorf("%s: child env missing %s", kind, w)
			}
		}
	}
}

func TestCodexConfigDisablesTelemetry(t *testing.T) {
	c := codexConfig("m", "https://x/v1")
	for _, want := range []string{"check_for_update_on_startup = false", "[analytics]\nenabled = false", "[feedback]\nenabled = false",
		`exporter = "none"`, `metrics_exporter = "none"`, "plugins = false", "apps = false", `env_key = "OPENROUTER_API_KEY"`} {
		if !strings.Contains(c, want) {
			t.Errorf("codex config missing %q", want)
		}
	}
}

func TestRedactAcrossWrites(t *testing.T) {
	var b bytes.Buffer
	l := &lineWriter{w: &b, secret: "SECRET"}
	l.Write([]byte("a SECRET b\n"))
	if strings.Contains(b.String(), "SECRET") {
		t.Fatal(b.String())
	}
}

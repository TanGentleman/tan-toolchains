package agent

import (
	"bytes"
	"errors"
	"net"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/fakeor"
)

// These tests run the real Pi the way pi-container does: the placeholder
// key, every request through pi-container/proxy.py, which MITMs
// openrouter.ai with its own CA and refuses every other host. The fake
// upstream is a model_url server, so proxy.py sends it the placeholder and
// the real key in its env file must reach no one. In place of the VM, a wrapper gives Pi a fresh HOME and agent dir
// with pi-container's settings and update-check switches. They skip without
// pi (FLEET_PI_BIN or PATH), python3 or openssl.

const (
	placeholder = "sk-or-v1-placeholder"
	fakeKey     = "sk-or-v1-fake-0123456789"
)

type proxy struct {
	url, ca string
	mu      sync.Mutex
	log     bytes.Buffer
}

func (p *proxy) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.log.Write(b)
}

func (p *proxy) Log() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.log.String()
}

// startProxy runs pi-container/proxy.py unchanged on loopback with key in
// its env file, egress standard, and its openrouter.ai upstream at upstream
// (plain HTTP, as model_url); "" means the real openrouter.ai.
func startProxy(t *testing.T, upstream, key string) *proxy {
	t.Helper()
	script, _ := filepath.Abs("../../pi-container/proxy.py")
	for _, b := range []string{"python3", "openssl"} {
		if _, err := exec.LookPath(b); err != nil {
			t.Skipf("%s not installed", b)
		}
	}
	d := t.TempDir()
	env := filepath.Join(d, "proxy.env")
	if err := os.WriteFile(env, []byte("OPENROUTER_API_KEY="+key+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	p := &proxy{ca: filepath.Join(d, "certs", "ca.pem")}
	cmd := exec.Command("python3", script)
	cmd.Env = append(os.Environ(),
		"PI_ENV_FILE="+env, "PI_PROXY_PORT="+strconv.Itoa(port),
		"PI_PROXY_BIND=127.0.0.1", "PI_PROXY_LOCKED_CIDR=127.0.0.0/8",
		"PI_PROXY_EGRESS=standard", "PI_PROXY_MODEL_RULE=any",
		"PI_PROXY_CERT="+filepath.Join(d, "private", "openrouter.pem"),
		"PI_PROXY_KEY="+filepath.Join(d, "private", "openrouter.key"),
		"PI_PROXY_CA="+p.ca, "PI_PROXY_ADDR_FILE="+filepath.Join(d, "private", "proxy.addr"))
	if upstream != "" {
		host, uport, _ := net.SplitHostPort(strings.TrimPrefix(upstream, "http://"))
		cmd.Env = append(cmd.Env, "PI_PROXY_MODEL_HOST="+host, "PI_PROXY_MODEL_PORT="+uport)
	}
	cmd.Stderr = p
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	for deadline := time.Now().Add(30 * time.Second); !strings.Contains(p.Log(), "listening"); time.Sleep(50 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("proxy.py did not start:\n%s", p.Log())
		}
	}
	p.url = "http://127.0.0.1:" + strconv.Itoa(port)
	return p
}

// containerPi writes a stand-in for pi-ctr that runs the real pi with what
// pi-container's VM gives it: its own HOME and agent dir, settings with
// OpenRouter and model as defaults, the placeholder key, the proxy and its
// CA, and the update-check switches run.sh and the image set.
func containerPi(t *testing.T, pi string, p *proxy, model string) string {
	t.Helper()
	d := t.TempDir()
	agentDir := filepath.Join(d, "agent")
	os.MkdirAll(agentDir, 0o700)
	settings := `{"defaultProvider":"openrouter","defaultModel":"` + model + `"}`
	if err := os.WriteFile(filepath.Join(agentDir, "settings.json"), []byte(settings), 0o600); err != nil {
		t.Fatal(err)
	}
	work := filepath.Join(d, "work")
	os.MkdirAll(work, 0o700)
	w := filepath.Join(d, "pi-ctr")
	script := "#!/bin/sh\ncd " + strconv.Quote(work) + "\nexec env -i PATH=\"$PATH\" HOME=" + strconv.Quote(d) +
		" PI_CODING_AGENT_DIR=" + strconv.Quote(agentDir) + " OPENROUTER_API_KEY=" + placeholder +
		" HTTPS_PROXY=" + p.url + " HTTP_PROXY=" + p.url + " NO_PROXY=localhost,127.0.0.1,::1 NODE_USE_ENV_PROXY=1" +
		" NODE_EXTRA_CA_CERTS=" + strconv.Quote(p.ca) + " SSL_CERT_FILE=" + strconv.Quote(p.ca) +
		" PI_SKIP_VERSION_CHECK=1 DO_NOT_TRACK=1 " + strconv.Quote(pi) + " \"$@\"\n"
	if err := os.WriteFile(w, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return w
}

func piBin(t *testing.T) string {
	t.Helper()
	if b := os.Getenv("FLEET_PI_BIN"); b != "" {
		return b
	}
	b, err := exec.LookPath("pi")
	if err != nil {
		t.Skip("pi not installed (set FLEET_PI_BIN)")
	}
	return b
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

// TestRealPi: turn 1, then turns 2 and 3 from a copy of turn 1's state in
// a new place (what a checkpoint restore does). The fake upstream accepts
// only the placeholder and names every TOK word it was sent, so a reply
// proves the turn went through the proxy and carried its history. The proxy
// log must show model calls only, and the real key must stay out of output
// and state. Then the session file is deleted: the adapter must refuse.
func TestRealPi(t *testing.T) {
	pi := piBin(t)
	srv := &fakeor.Server{Key: placeholder}
	up := httptest.NewServer(srv)
	t.Cleanup(up.Close)
	p := startProxy(t, up.URL, fakeKey)
	bin := containerPi(t, pi, p, "fake/model")
	root := t.TempDir()
	at := func(n string) Config { return Config{Bin: bin, State: filepath.Join(root, n)} }

	a := start(t, at("a"))
	out, end := a.turn("hello TOKALPHA")
	if a.err != nil || !contains(out, "seen TOKALPHA") || end["code"] != 0.0 {
		t.Fatalf("turn 1: %v %v\n%s\nstderr:\n%s\nproxy:\n%s", a.err, end, strings.Join(out, "\n"), a.errb, p.Log())
	}
	if u, _ := end["usage"].(map[string]any); u["input"] != 10.0 || u["output"] != 5.0 {
		t.Fatalf("turn usage = %v (fakeor bills 10 in, 5 out)", end["usage"])
	}
	copyDir(t, filepath.Join(root, "a"), filepath.Join(root, "b"))
	b := start(t, at("b"))
	out, _ = b.turn("again TOKBRAVO")
	if !contains(out, "seen TOKALPHA TOKBRAVO") {
		t.Fatalf("resumed turn lost history:\n%s\nstderr:\n%s", strings.Join(out, "\n"), b.errb)
	}
	out, _ = b.turn("third TOKCHARLIE")
	if b.err != nil || !contains(out, "seen TOKALPHA TOKBRAVO TOKCHARLIE") {
		t.Fatalf("third turn lost history: %v\n%s", b.err, strings.Join(out, "\n"))
	}

	if !strings.Contains(p.Log(), "openrouter POST") {
		t.Fatalf("model calls did not go through the proxy:\n%s", p.Log())
	}
	for _, l := range strings.Split(p.Log(), "\n") {
		if strings.Contains(l, " deny ") || strings.Contains(l, " allow ") || strings.Contains(l, " error ") {
			t.Errorf("proxy saw non-model traffic: %s", l)
		}
	}
	for _, r := range srv.Requests() {
		if !r.Authed {
			t.Errorf("upstream got a request without the placeholder: %s", r.Path)
		}
	}
	noSecret(t, fakeKey, root, strings.Join(a.all, "\n"), strings.Join(b.all, "\n"), a.errb.String(), b.errb.String())

	copyDir(t, filepath.Join(root, "b"), filepath.Join(root, "c"))
	os.RemoveAll(filepath.Join(root, "c", "pi", "sessions"))
	c := start(t, at("c"))
	out, _ = c.turn("lost TOKDELTA")
	if !errors.Is(c.err, ErrSession) || contains(out, "seen TOKDELTA") {
		t.Fatalf("missing session file: err=%v\n%s", c.err, strings.Join(out, "\n"))
	}
}

// TestRealPiWrongKey: the provider rejects the key with 401, Pi still exits
// 0, and the turn must fail.
func TestRealPiWrongKey(t *testing.T) {
	pi := piBin(t)
	up := httptest.NewServer(&fakeor.Server{Key: "sk-or-v1-other-0123456789"})
	t.Cleanup(up.Close)
	p := startProxy(t, up.URL, fakeKey)
	s := start(t, Config{Bin: containerPi(t, pi, p, "fake/model"), State: filepath.Join(t.TempDir(), "s")})
	_, end := s.turn("hello")
	if s.err == nil || end == nil || end["code"] != 0.0 || end["error"] == nil {
		t.Fatalf("wrong key accepted: err = %v, turn_end = %v\nstderr:\n%s", s.err, end, s.errb)
	}
}

// TestLive is TestRealPi's first two turns against the real OpenRouter. It
// needs FLEET_LIVE=1 and OPENROUTER_API_KEY, costs a fraction of a cent, and
// never runs in CI. FLEET_LIVE_MODEL overrides the model.
func TestLive(t *testing.T) {
	key := os.Getenv("OPENROUTER_API_KEY")
	if os.Getenv("FLEET_LIVE") != "1" || key == "" {
		t.Skip("set FLEET_LIVE=1 and OPENROUTER_API_KEY")
	}
	model := os.Getenv("FLEET_LIVE_MODEL")
	if model == "" {
		model = "thinkingmachines/inkling-2-small"
	}
	pi := piBin(t)
	p := startProxy(t, "", key)
	bin := containerPi(t, pi, p, model)
	root := t.TempDir()
	a := start(t, Config{Bin: bin, State: filepath.Join(root, "a")})
	out, end := a.turn("Remember the codeword TOKZEBRA. Reply with only the word OK.")
	if a.err != nil || end["code"] != 0.0 {
		t.Fatalf("turn 1: %v %v\n%s\nstderr:\n%s", a.err, end, strings.Join(out, "\n"), a.errb)
	}
	copyDir(t, filepath.Join(root, "a"), filepath.Join(root, "b"))
	b := start(t, Config{Bin: bin, State: filepath.Join(root, "b")})
	out, _ = b.turn("What was the codeword? Reply with only the codeword.")
	if b.err != nil || !contains(out, "TOKZEBRA") {
		t.Fatalf("turn 2 forgot the codeword: %v\n%s\nstderr:\n%s", b.err, strings.Join(out, "\n"), b.errb)
	}
	for _, l := range strings.Split(p.Log(), "\n") {
		if strings.Contains(l, " deny ") || strings.Contains(l, " allow ") {
			t.Errorf("traffic besides openrouter.ai: %s", l)
		}
	}
	noSecret(t, key, root, strings.Join(a.all, "\n"), strings.Join(b.all, "\n"), a.errb.String(), b.errb.String())
}

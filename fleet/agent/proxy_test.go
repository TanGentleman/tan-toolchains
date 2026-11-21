package agent

import (
	"bytes"
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

const placeholder = "sk-or-v1-placeholder"

type v5proxy struct {
	url, ca string
	mu      sync.Mutex
	log     bytes.Buffer
}

func (p *v5proxy) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.log.Write(b)
}

func (p *v5proxy) Log() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.log.String()
}

// startV5Proxy runs pi-container/proxy.py unchanged, bound to loopback, with
// its openrouter.ai upstream pointed at upstream (plain HTTP). The real key
// lives only in the proxy's env file.
func startV5Proxy(t *testing.T, upstream, key string) *v5proxy {
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
	p := &v5proxy{ca: filepath.Join(d, "certs", "ca.pem")}
	cmd := exec.Command("python3", script)
	cmd.Env = append(os.Environ(),
		"PI_ENV_FILE="+env, "PI_PROXY_PORT="+strconv.Itoa(port),
		"PI_PROXY_BIND=127.0.0.1", "PI_PROXY_LOCKED_CIDR=127.0.0.0/8",
		"PI_PROXY_CERT="+filepath.Join(d, "private", "openrouter.pem"),
		"PI_PROXY_KEY="+filepath.Join(d, "private", "openrouter.key"),
		"PI_PROXY_CA="+p.ca, "PI_PROXY_ADDR_FILE="+filepath.Join(d, "private", "proxy.addr"))
	if upstream != "" { // "" means the real openrouter.ai
		host, uport, _ := net.SplitHostPort(strings.TrimPrefix(upstream, "http://"))
		cmd.Env = append(cmd.Env, "PI_PROXY_OPENROUTER_HOST="+host, "PI_PROXY_OPENROUTER_PORT="+uport, "PI_PROXY_OPENROUTER_TLS=0")
	}
	cmd.Stderr = p
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	deadline := time.Now().Add(30 * time.Second)
	for !strings.Contains(p.Log(), "listening") {
		if time.Now().After(deadline) {
			t.Fatalf("proxy.py did not start:\n%s", p.Log())
		}
		time.Sleep(50 * time.Millisecond)
	}
	p.url = "http://127.0.0.1:" + strconv.Itoa(port)
	return p
}

// TestBehindV5Proxy runs each CLI the way pi-container runs Pi: the node
// holds only the placeholder key, all traffic goes through the v5 proxy,
// which MITMs openrouter.ai with its own CA, swaps in the real key and
// refuses every other host except GitHub. The fake upstream accepts only the
// real key, so a reply proves the proxy did the auth. The proxy log must show
// model calls only: no GitHub tunnels, no denials.
func TestBehindV5Proxy(t *testing.T) { behindProxy(t, false) }

// TestLiveBehindV5Proxy is the same against the real openrouter.ai; the
// adapters never see the real key. Needs FLEET_LIVE=1 and OPENROUTER_API_KEY.
func TestLiveBehindV5Proxy(t *testing.T) {
	if os.Getenv("FLEET_LIVE") != "1" || os.Getenv("OPENROUTER_API_KEY") == "" {
		t.Skip("set FLEET_LIVE=1 and OPENROUTER_API_KEY")
	}
	behindProxy(t, true)
}

func behindProxy(t *testing.T, live bool) {
	for _, kind := range kinds {
		t.Run(kind, func(t *testing.T) {
			b := bin(t, kind)
			srv := &fakeor.Server{Key: fakeKey}
			model, key, upURL := "fake/model", fakeKey, ""
			p1, want1, p2, want2 := "hello TOKALPHA", "seen TOKALPHA", "again TOKBRAVO", "seen TOKALPHA TOKBRAVO"
			if live {
				model, key = liveModels[kind], os.Getenv("OPENROUTER_API_KEY")
				p1, want1 = "Remember the codeword TOKZEBRA. Reply with only the word OK.", ""
				p2, want2 = "What was the codeword? Reply with only the codeword.", "TOKZEBRA"
			} else {
				up := httptest.NewServer(srv)
				t.Cleanup(up.Close)
				upURL = up.URL
			}
			t.Setenv("OPENROUTER_API_KEY", "")
			px := startV5Proxy(t, upURL, key)
			for _, k := range []string{"HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"} {
				t.Setenv(k, px.url)
			}
			t.Setenv("NO_PROXY", "localhost,127.0.0.1,::1")
			t.Setenv("no_proxy", "localhost,127.0.0.1,::1")
			t.Setenv("NODE_USE_ENV_PROXY", "")
			for _, k := range []string{"NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE"} {
				t.Setenv(k, px.ca)
			}
			root := t.TempDir()
			cfg := func(n string) Config {
				os.MkdirAll(filepath.Join(root, n, "work"), 0o755)
				return Config{Kind: kind, Model: model, Bin: b, Key: placeholder,
					State: filepath.Join(root, n, "state"), Work: filepath.Join(root, n, "work")}
			}
			a := start(t, cfg("a"))
			out, end := a.turn("t1", p1)
			a.close()
			if !contains(out, want1) || end == nil || end["code"].(float64) != 0 {
				t.Fatalf("turn 1 via proxy: %v\n%s\nstderr:\n%s\nproxy:\n%s", end, strings.Join(out, "\n"), a.errb, px.Log())
			}
			os.MkdirAll(filepath.Join(root, "b"), 0o755)
			copyDir(t, filepath.Join(root, "a", "state"), filepath.Join(root, "b", "state"))
			bs := start(t, cfg("b"))
			out, _ = bs.turn("t2", p2)
			bs.close()
			if !contains(out, want2) {
				t.Fatalf("resume via proxy:\n%s\nstderr:\n%s", strings.Join(out, "\n"), bs.errb)
			}
			if !strings.Contains(px.Log(), "openrouter POST") {
				t.Fatalf("model calls did not go through the proxy:\n%s", px.Log())
			}
			for _, l := range strings.Split(px.Log(), "\n") {
				if strings.Contains(l, " deny ") || strings.Contains(l, " allow ") || strings.Contains(l, " error ") {
					t.Errorf("proxy saw non-model traffic: %s", l)
				}
			}
			for _, r := range srv.Requests() {
				if r.Auth != "bearer" {
					t.Errorf("upstream got auth %q on %s", r.Auth, r.Path)
				}
			}
			noSecret(t, key, root, strings.Join(a.all, "\n"), strings.Join(bs.all, "\n"), a.errb.String(), bs.errb.String())
		})
	}
}

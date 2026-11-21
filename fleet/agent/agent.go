// Package agent adapts real coding-agent CLIs (Pi, Claude Code, Codex) to
// fleet's harness contract. It reads {"type":"prompt"|"steer"|"abort","id",
// "message"} lines on stdin and runs the CLI once per turn in its headless
// JSON mode, forwarding every stdout line unchanged.
//
// Everything the CLI needs to continue lives under Config.State, so the
// directory fleet checkpoints is the conversation. Each turn after the first
// resumes the CLI's native session, and the adapter refuses to continue when
// that session is missing or the CLI reports a different one: none of the
// three CLIs is allowed to silently start a fresh conversation.
//
// Telemetry, update checks, feedback and other non-model traffic are turned
// off through each CLI's documented environment variables and config files.
// The child gets an allowlisted environment and a HOME inside State, so host
// config and credentials do not leak in.
package agent

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
)

const DefaultBase = "https://openrouter.ai/api"

type Config struct {
	Kind  string // "pi", "claude" or "codex"
	Model string // OpenRouter model id
	State string // checkpointed directory owned by the adapter
	Work  string // working directory for the CLI
	Key   string // OpenRouter API key; passed only to the child
	Base  string // OpenRouter API root; default DefaultBase
	Bin   string // executable; default Kind
	Args  []string
	Env   []string // extra NAME=VALUE for the child
}

// Common opt-outs for any tool that honours them.
var commonEnv = []string{"DO_NOT_TRACK=1"}

// Per-CLI opt-outs. Sources: code.claude.com/docs/en/data-usage and env-vars;
// pi docs/environment-variables.md and settings.md; codex config-reference.
var kindEnv = map[string][]string{
	"pi": {"PI_TELEMETRY=0", "PI_OFFLINE=1", "PI_SKIP_VERSION_CHECK=1"},
	"claude": {
		"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1", "DISABLE_TELEMETRY=1", "DISABLE_ERROR_REPORTING=1",
		"DISABLE_AUTOUPDATER=1", "DISABLE_UPDATES=1", "DISABLE_FEEDBACK_COMMAND=1", "DISABLE_BUG_COMMAND=1",
		"CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1", "CLAUDE_CODE_DISABLE_FEATURE_FLAGS=1", "DISABLE_GROWTHBOOK=1",
		"CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1", "CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1",
		"CLAUDE_CODE_ENABLE_TELEMETRY=0",
	},
	"codex": {},
}

// Variables copied from the adapter's environment. Everything else,
// including other credentials, stays out of the child.
var passEnv = []string{
	"PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TZ", "USER", "SHELL", "TMPDIR",
	"SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "CODEX_CA_CERTIFICATE", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE",
	"HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy", "NODE_USE_ENV_PROXY",
}

type native struct {
	Kind    string `json:"kind"`
	Session string `json:"session"`
	Turns   int    `json:"turns"`
}

type adapter struct {
	c   Config
	nat native
	out *lineWriter

	mu   sync.Mutex
	cur  *exec.Cmd
	quit bool
}

// ErrSession means the CLI's native session is gone or changed. The adapter
// exits rather than let the conversation restart from nothing.
var ErrSession = errors.New("agent: native session missing or changed")

func Run(c Config, in io.Reader, out, errw io.Writer) error {
	if _, ok := kindEnv[c.Kind]; !ok {
		return fmt.Errorf("agent: unknown kind %q (want pi, claude or codex)", c.Kind)
	}
	if c.Model == "" || c.State == "" || c.Work == "" {
		return errors.New("agent: model, state and work are required")
	}
	if c.Key == "" {
		return errors.New("agent: OPENROUTER_API_KEY is not set")
	}
	if c.Base == "" {
		c.Base = DefaultBase
	}
	c.Base = strings.TrimRight(c.Base, "/")
	if c.Bin == "" {
		c.Bin = c.Kind
	}
	a := &adapter{c: c, out: &lineWriter{w: out, secret: c.Key}}
	if err := a.load(); err != nil {
		return err
	}
	if err := a.configure(); err != nil {
		return err
	}
	a.emit(map[string]any{"type": "fleet.ready", "kind": c.Kind, "model": c.Model, "session": a.nat.Session, "turns": a.nat.Turns})

	type msg struct{ Type, ID, Message string }
	msgs := make(chan msg, 64)
	go func() {
		sc := bufio.NewScanner(in)
		sc.Buffer(make([]byte, 1<<20), 16<<20)
		for sc.Scan() {
			var m msg
			if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
				a.emit(map[string]any{"type": "fleet.error", "error": "bad input: " + err.Error()})
				continue
			}
			if m.Type == "abort" {
				a.kill()
				a.emit(map[string]any{"type": "fleet.aborted", "id": m.ID})
				continue
			}
			msgs <- m
		}
		a.mu.Lock()
		a.quit = true
		a.mu.Unlock()
		a.kill()
		close(msgs)
	}()
	stderr := &lineWriter{w: errw, secret: c.Key}
	for m := range msgs {
		switch m.Type {
		case "prompt", "steer":
			if err := a.turn(m.ID, m.Message, stderr); err != nil {
				a.emit(map[string]any{"type": "fleet.error", "id": m.ID, "error": err.Error()})
				if errors.Is(err, ErrSession) {
					return err
				}
			}
		default:
			a.emit(map[string]any{"type": "fleet.error", "id": m.ID, "error": "unknown type " + m.Type})
		}
	}
	return nil
}

func (a *adapter) emit(v any) {
	b, _ := json.Marshal(v)
	a.out.Write(append(b, '\n'))
}

func (a *adapter) kill() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.cur != nil && a.cur.Process != nil {
		syscall.Kill(-a.cur.Process.Pid, syscall.SIGKILL)
	}
}

func (a *adapter) statePath(p ...string) string {
	return filepath.Join(append([]string{a.c.State}, p...)...)
}

func (a *adapter) load() error {
	b, err := os.ReadFile(a.statePath("agent.json"))
	if errors.Is(err, os.ErrNotExist) {
		a.nat = native{Kind: a.c.Kind}
		return nil
	}
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, &a.nat); err != nil {
		return fmt.Errorf("agent: agent.json: %w", err)
	}
	if a.nat.Kind != a.c.Kind {
		return fmt.Errorf("agent: state belongs to %q, not %q", a.nat.Kind, a.c.Kind)
	}
	return nil
}

func (a *adapter) save() error {
	b, _ := json.Marshal(a.nat)
	return writeFile(a.statePath("agent.json"), b)
}

func writeFile(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// configure writes each CLI's config. It runs on every start so a moved
// session picks up this node's base URL and the current opt-outs.
func (a *adapter) configure() error {
	if err := os.MkdirAll(a.statePath("home"), 0o700); err != nil {
		return err
	}
	switch a.c.Kind {
	case "pi":
		set, _ := json.Marshal(map[string]any{
			"enableInstallTelemetry": false, "defaultProvider": "openrouter", "defaultModel": a.c.Model,
		})
		if err := writeFile(a.statePath("pi", "agent", "settings.json"), set); err != nil {
			return err
		}
		models := []byte(`{"providers":{}}`)
		if a.c.Base != DefaultBase {
			models, _ = json.Marshal(map[string]any{"providers": map[string]any{"openrouter": map[string]any{"baseUrl": a.c.Base + "/v1"}}})
		}
		return writeFile(a.statePath("pi", "agent", "models.json"), models)
	case "claude":
		return writeFile(a.statePath("claude", "settings.json"), []byte(`{"skipWebFetchPreflight":true}`))
	case "codex":
		return writeFile(a.statePath("codex", "config.toml"), []byte(codexConfig(a.c.Model, a.c.Base+"/v1")))
	}
	return nil
}

func codexConfig(model, base string) string {
	q := func(s string) string { b, _ := json.Marshal(s); return string(b) }
	return `# Written by fleet's agent adapter on every start; edits are overwritten.
model = ` + q(model) + `
model_provider = "openrouter"
check_for_update_on_startup = false

[model_providers.openrouter]
name = "OpenRouter"
base_url = ` + q(base) + `
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"

[analytics]
enabled = false

[feedback]
enabled = false

[history]
persistence = "none"

[otel]
exporter = "none"
trace_exporter = "none"
metrics_exporter = "none"

# Each of these contacts github.com, api.github.com or chatgpt.com at startup.
[features]
plugins = false
remote_plugin = false
plugin_sharing = false
apps = false
memories = false
in_app_updates = false
daemon_auto_start = false
api_key_model_discovery = false

[skills.bundled]
enabled = false
`
}

func (a *adapter) env() []string {
	var env []string
	for _, k := range passEnv {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
		}
	}
	env = append(env, "HOME="+a.statePath("home"))
	// Node's fetch ignores HTTPS_PROXY unless asked; without this Pi would
	// try to reach openrouter.ai directly and fail on a locked network.
	if (os.Getenv("HTTPS_PROXY") != "" || os.Getenv("https_proxy") != "") && os.Getenv("NODE_USE_ENV_PROXY") == "" {
		env = append(env, "NODE_USE_ENV_PROXY=1")
	}
	env = append(env, commonEnv...)
	env = append(env, kindEnv[a.c.Kind]...)
	switch a.c.Kind {
	case "pi":
		env = append(env, "PI_CODING_AGENT_DIR="+a.statePath("pi", "agent"), "OPENROUTER_API_KEY="+a.c.Key)
	case "claude":
		// OpenRouter's documented Claude Code setup: bearer token, empty API key.
		env = append(env, "CLAUDE_CONFIG_DIR="+a.statePath("claude"),
			"ANTHROPIC_BASE_URL="+a.c.Base, "ANTHROPIC_AUTH_TOKEN="+a.c.Key, "ANTHROPIC_API_KEY=",
			"ANTHROPIC_MODEL="+a.c.Model, "ANTHROPIC_SMALL_FAST_MODEL="+a.c.Model,
			"ANTHROPIC_DEFAULT_OPUS_MODEL="+a.c.Model, "ANTHROPIC_DEFAULT_SONNET_MODEL="+a.c.Model,
			"ANTHROPIC_DEFAULT_HAIKU_MODEL="+a.c.Model, "CLAUDE_CODE_SUBAGENT_MODEL="+a.c.Model)
	case "codex":
		env = append(env, "CODEX_HOME="+a.statePath("codex"), "OPENROUTER_API_KEY="+a.c.Key, "RUST_LOG=error")
	}
	return append(env, a.c.Env...)
}

func randomID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b)
	return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

// nativeFiles finds the transcript claude or codex resumes from.
func (a *adapter) nativeFiles(id string) []string {
	var pat string
	switch a.c.Kind {
	case "claude":
		pat = a.statePath("claude", "projects", "*", id+".jsonl")
	case "codex":
		pat = a.statePath("codex", "sessions", "*", "*", "*", "rollout-*-"+id+".jsonl")
	}
	fs, _ := filepath.Glob(pat)
	return fs
}

func (a *adapter) piFiles() []string {
	fs, _ := filepath.Glob(a.statePath("pi", "sessions", "*.jsonl"))
	return fs
}

// argv builds the command for one turn. The prompt always goes on stdin so
// that text starting with "-" or "@" is never parsed as a flag or file.
func (a *adapter) argv() ([]string, string, error) {
	first := a.nat.Session == ""
	id := a.nat.Session
	if first {
		id = randomID()
	}
	if !first && a.c.Kind != "pi" && len(a.nativeFiles(id)) == 0 {
		return nil, "", fmt.Errorf("%w: no %s session file for %s under %s", ErrSession, a.c.Kind, id, a.c.State)
	}
	var args []string
	switch a.c.Kind {
	case "pi":
		args = []string{"--mode", "json", "-p", "--provider", "openrouter", "--model", a.c.Model}
		if first {
			args = append(args, "--session-dir", a.statePath("pi", "sessions"), "--session-id", id)
		} else {
			// --session-id only finds sessions recorded for the same cwd and
			// otherwise starts fresh, so resume by file path.
			fs := a.piFiles()
			if len(fs) != 1 {
				return nil, "", fmt.Errorf("%w: want 1 pi session file, found %d", ErrSession, len(fs))
			}
			args = append(args, "--session", fs[0])
		}
	case "claude":
		args = []string{"-p", "--output-format", "stream-json", "--verbose", "--model", a.c.Model}
		if first {
			args = append(args, "--session-id", id)
		} else {
			args = append(args, "--resume", id)
		}
	case "codex":
		args = []string{"exec"}
		if !first {
			args = append(args, "resume", id)
		}
		args = append(args, "--json", "--skip-git-repo-check")
		if first {
			id = "" // codex picks the thread id; read it from thread.started
		}
	}
	args = append(args, a.c.Args...)
	if a.c.Kind == "codex" {
		args = append(args, "-")
	}
	return args, id, nil
}

// reported extracts the session id a CLI announces on stdout.
func reported(kind string, line []byte) string {
	var m struct {
		Type     string `json:"type"`
		Subtype  string `json:"subtype"`
		ID       string `json:"id"`
		Session  string `json:"session_id"`
		ThreadID string `json:"thread_id"`
	}
	if json.Unmarshal(line, &m) != nil {
		return ""
	}
	switch {
	case kind == "pi" && m.Type == "session":
		return m.ID
	case kind == "claude" && m.Type == "system" && m.Subtype == "init":
		return m.Session
	case kind == "codex" && m.Type == "thread.started":
		return m.ThreadID
	}
	return ""
}

func (a *adapter) turn(id, text string, stderr io.Writer) error {
	args, want, err := a.argv()
	if err != nil {
		return err
	}
	before := len(a.piFiles())
	cmd := exec.Command(a.c.Bin, args...)
	cmd.Dir = a.c.Work
	cmd.Env = a.env()
	cmd.Stdin = strings.NewReader(text)
	cmd.Stderr = stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	a.mu.Lock()
	if a.quit {
		a.mu.Unlock()
		return errors.New("agent: shutting down")
	}
	if err := cmd.Start(); err != nil {
		a.mu.Unlock()
		return err
	}
	a.cur = cmd
	a.mu.Unlock()
	a.emit(map[string]any{"type": "fleet.turn_start", "id": id, "turn": a.nat.Turns + 1, "session": a.nat.Session})

	var got string
	br := bufio.NewReaderSize(stdout, 1<<16)
	for {
		line, rerr := br.ReadBytes('\n')
		if s := bytes.TrimRight(line, "\r\n"); len(s) > 0 {
			if got == "" {
				got = reported(a.c.Kind, s)
			}
			a.out.Write(append(s, '\n'))
		}
		if rerr != nil {
			break
		}
	}
	werr := cmd.Wait()
	a.mu.Lock()
	a.cur = nil
	a.mu.Unlock()
	code := cmd.ProcessState.ExitCode()

	switch {
	case got == "" && code == 0:
		err = fmt.Errorf("%w: %s reported no session id", ErrSession, a.c.Kind)
	case got != "" && want != "" && got != want:
		err = fmt.Errorf("%w: expected %s, %s reported %s", ErrSession, want, a.c.Kind, got)
	case a.c.Kind == "pi" && a.nat.Session != "" && len(a.piFiles()) != before:
		err = fmt.Errorf("%w: pi wrote a new session file instead of resuming", ErrSession)
	}
	if err == nil && got != "" && a.nat.Session == "" {
		a.nat.Session = got
	}
	if err == nil && code == 0 {
		a.nat.Turns++
	}
	if serr := a.save(); err == nil {
		err = serr
	}
	end := map[string]any{"type": "fleet.turn_end", "id": id, "turn": a.nat.Turns, "code": code, "session": a.nat.Session}
	if werr != nil {
		end["error"] = werr.Error()
	}
	a.emit(end)
	return err
}

// lineWriter serializes whole lines and scrubs the API key from them.
type lineWriter struct {
	mu     sync.Mutex
	w      io.Writer
	secret string
}

func (l *lineWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	q := p
	if l.secret != "" && bytes.Contains(p, []byte(l.secret)) {
		q = bytes.ReplaceAll(p, []byte(l.secret), []byte("[redacted]"))
	}
	if _, err := l.w.Write(q); err != nil {
		return 0, err
	}
	return len(p), nil
}

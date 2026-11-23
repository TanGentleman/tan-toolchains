package agent

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// session runs turns of one adapter config and keeps every output line.
type session struct {
	t    *testing.T
	c    Config
	all  []string
	errb *bytes.Buffer
	err  error
}

func start(t *testing.T, c Config) *session {
	return &session{t: t, c: c, errb: &bytes.Buffer{}}
}

// turn runs one prompt and returns its output lines and fleet.turn_end.
func (s *session) turn(text string) (out []string, end map[string]any) {
	var b bytes.Buffer
	if s.err = Run(s.c, text, &b, s.errb); s.err != nil {
		s.t.Logf("turn %q: %v", text, s.err)
	}
	for _, l := range strings.Split(strings.TrimSpace(b.String()), "\n") {
		s.all = append(s.all, l)
		out = append(out, l)
		var m map[string]any
		if json.Unmarshal([]byte(l), &m) == nil && m["type"] == "fleet.turn_end" {
			end = m
		}
	}
	return out, end
}

func contains(lines []string, s string) bool {
	for _, l := range lines {
		if strings.Contains(l, s) {
			return true
		}
	}
	return false
}

func copyDir(t *testing.T, src, dst string) {
	t.Helper()
	if out, err := exec.Command("cp", "-a", src, dst).CombinedOutput(); err != nil {
		t.Fatalf("cp: %v %s", err, out)
	}
}

// fakePi writes a shell script standing in for pi-ctr. It records its
// arguments and environment in $DUMP, keeps a session file the way Pi does,
// and announces the session id; $MODE changes what it does.
func fakePi(t *testing.T) string {
	p := filepath.Join(t.TempDir(), "pi-ctr")
	script := `#!/bin/sh
{ env; printf 'ARG %s\n' "$@"; } > "$DUMP"
dir="" id="" file=""
while [ $# -gt 0 ]; do
  case $1 in
    --session-dir) dir=$2; shift 2 ;;
    --session-id) id=$2; shift 2 ;;
    --session) file=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
if [ -n "$file" ]; then id=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$file" | head -n 1); else file="$dir/$id.jsonl"; echo '{"type":"session","id":"'"$id"'"}' > "$file"; fi
case ${MODE:-} in
  other) id=someone-else ;;
  newfile) echo '{}' > "$(dirname "$file")/second.jsonl" ;;
esac
echo '{"type":"session","id":"'"$id"'"}'
case ${MODE:-} in
  error) echo '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"401 no auth"}}' ;;
  recovered) echo '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"overloaded"}}'
    echo '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","usage":{"input":3,"output":2}}}' ;;
  *) echo '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","usage":{"input":3,"output":2}}}' ;;
esac
`
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

// cfg is one session's adapter config with fakePi; mode picks its behaviour.
func cfg(t *testing.T, bin, mode string) (Config, string) {
	dump := filepath.Join(t.TempDir(), "dump")
	return Config{State: filepath.Join(t.TempDir(), "state"), Bin: bin, Env: []string{"DUMP=" + dump, "MODE=" + mode}}, dump
}

func dumped(t *testing.T, dump string) string {
	b, err := os.ReadFile(dump)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// TestArgsAndResume: the first turn names the session dir and a new id, a
// later turn resumes by file, --model is passed only when set, and usage
// adds up across turns.
func TestArgsAndResume(t *testing.T) {
	bin := fakePi(t)
	c, dump := cfg(t, bin, "")
	s := start(t, c)
	_, end := s.turn("one")
	got := dumped(t, dump)
	if s.err != nil || !strings.Contains(got, "ARG --session-dir\nARG "+filepath.Join(c.State, "pi", "sessions")) ||
		!strings.Contains(got, "ARG --session-id") || strings.Contains(got, "ARG --model") {
		t.Fatalf("first turn: %v\n%s", s.err, got)
	}
	if end["turn"] != 1.0 || end["usage"].(map[string]any)["input"] != 3.0 {
		t.Fatalf("turn_end = %v", end)
	}
	c.Model = "thinkingmachines/inkling-2-small"
	s.c = c
	_, end = s.turn("two")
	got = dumped(t, dump)
	if s.err != nil || !strings.Contains(got, "ARG --session\nARG ") || strings.Contains(got, "ARG --session-id") ||
		!strings.Contains(got, "ARG --model\nARG thinkingmachines/inkling-2-small") {
		t.Fatalf("second turn: %v\n%s", s.err, got)
	}
	var nat native
	b, _ := os.ReadFile(filepath.Join(c.State, "agent.json"))
	json.Unmarshal(b, &nat)
	if end["turn"] != 2.0 || nat.Turns != 2 || nat.Total.Input != 6 || nat.Kind != "pi" {
		t.Fatalf("turn_end = %v, agent.json = %+v", end, nat)
	}
}

// TestRefusals: the adapter never lets a conversation restart from
// nothing, and refuses state it did not write.
func TestRefusals(t *testing.T) {
	bin := fakePi(t)
	if err := Run(Config{Bin: bin}, "", io.Discard, io.Discard); err == nil {
		t.Error("ran without state")
	}

	for name, setup := range map[string]func(c Config){
		"session file gone": func(c Config) { os.RemoveAll(filepath.Join(c.State, "pi", "sessions")) },
		"two session files": func(c Config) {
			os.WriteFile(filepath.Join(c.State, "pi", "sessions", "extra.jsonl"), []byte("{}\n"), 0o600)
		},
	} {
		c, _ := cfg(t, bin, "")
		s := start(t, c)
		s.turn("one")
		setup(c)
		s.turn("two")
		if !errors.Is(s.err, ErrSession) {
			t.Errorf("%s: err = %v", name, s.err)
		}
	}
	for _, mode := range []string{"other", "newfile"} {
		c, _ := cfg(t, bin, "")
		s := start(t, c)
		s.turn("one")
		c.Env = append(c.Env, "MODE="+mode)
		s.c = c
		s.turn("two")
		if !errors.Is(s.err, ErrSession) {
			t.Errorf("%s: err = %v", mode, s.err)
		}
	}

	c, _ := cfg(t, bin, "")
	os.MkdirAll(c.State, 0o700)
	os.WriteFile(filepath.Join(c.State, "agent.json"), []byte(`{"kind":"claude","session":"x"}`), 0o600)
	if err := Run(c, "", io.Discard, io.Discard); err == nil || !strings.Contains(err.Error(), "belongs to") {
		t.Errorf("state from another CLI: %v", err)
	}
}

// Pi exits 0 when the model call fails; the turn must still fail, keep the
// session for a retry, and not count as a completed turn. A later message
// that ends normally (a retry within the turn) decides the outcome.
func TestModelErrors(t *testing.T) {
	bin := fakePi(t)
	c, _ := cfg(t, bin, "error")
	s := start(t, c)
	_, end := s.turn("hi")
	if s.err == nil || errors.Is(s.err, ErrSession) || end["error"] != "pi: 401 no auth" || end["turn"] != 0.0 {
		t.Fatalf("model error: err = %v, turn_end = %v", s.err, end)
	}
	c, _ = cfg(t, bin, "recovered")
	s = start(t, c)
	_, end = s.turn("hi")
	if s.err != nil || end["turn"] != 1.0 || end["error"] != nil {
		t.Fatalf("recovered: err = %v, turn_end = %v", s.err, end)
	}
}

// TestChildEnvironment: pi-ctr sees only the allowlist and Config.Env; no
// credential or proxy setting from fleetd's environment reaches it.
func TestChildEnvironment(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "ghp_should_not_leak")
	t.Setenv("OPENROUTER_API_KEY", "sk-or-v1-should-not-leak")
	t.Setenv("HTTPS_PROXY", "http://should-not-leak")
	c, dump := cfg(t, fakePi(t), "")
	s := start(t, c)
	s.turn("hi")
	got := dumped(t, dump)
	for _, bad := range []string{"should_not_leak", "should-not-leak", "HOME=", "PI_CODING_AGENT_DIR="} {
		if strings.Contains(got, bad) {
			t.Errorf("pi-ctr got %q", bad)
		}
	}
	if !strings.Contains(got, "PATH=") || !strings.Contains(got, "MODE=") {
		t.Errorf("pi-ctr lacks PATH or Config.Env:\n%s", got)
	}
}

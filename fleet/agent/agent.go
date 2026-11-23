// Package agent runs one turn of Pi through pi-container's pi-ctr and keeps
// the conversation going across turns. Run passes the prompt to Pi's
// headless JSON mode on stdin, forwards every stdout line unchanged, and
// ends with a {"type":"fleet.turn_end"} line.
//
// Everything Pi needs to continue lives under Config.State: Pi's session
// file in pi/sessions and agent.json. That is the directory fleetd
// checkpoints. Each turn after the first resumes Pi's session by file, and
// Run refuses to continue when that file is missing, when Pi reports a
// different session, or when Pi starts a new file: a conversation never
// silently restarts from nothing.
//
// Bin is pi-container/pi-ctr, which runs Pi inside the locked VM with the
// placeholder key; pi-container's proxy holds the real one and is the only
// way out, so this package sets no key, proxy or telemetry options. The
// child gets an allowlisted environment.
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
	"time"
)

type Config struct {
	Model string // OpenRouter model id; "" uses the profile's settings.json default
	State string // checkpointed directory owned by the adapter
	Bin   string // pi-ctr, or a stand-in in tests
	Args  []string
	Env   []string // extra NAME=VALUE for the child
}

// Variables copied from the adapter's environment. Everything else,
// including credentials, stays out of the child.
var passEnv = []string{"PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TZ", "USER", "SHELL", "TMPDIR"}

// native is agent.json: Pi's session id and running totals.
type native struct {
	Kind    string `json:"kind"` // always "pi"; older fleets also wrote claude or codex
	Session string `json:"session"`
	Turns   int    `json:"turns"`
	Total   Usage  `json:"total"` // tokens over all turns
}

type adapter struct {
	c   Config
	nat native
	out io.Writer
}

// ErrSession means Pi's session is gone or changed. The adapter exits
// rather than let the conversation restart from nothing.
var ErrSession = errors.New("agent: pi session missing or changed")

// Run runs one turn. It returns ErrSession when Pi's session is gone or
// changed, and Pi's failure as an error.
func Run(c Config, prompt string, out, errw io.Writer) error {
	if c.State == "" || c.Bin == "" {
		return errors.New("agent: state and bin are required")
	}
	a := &adapter{c: c, out: out}
	if err := a.load(); err != nil {
		return err
	}
	if err := os.MkdirAll(a.statePath("pi", "sessions"), 0o700); err != nil {
		return err
	}
	return a.turn(prompt, errw)
}

func (a *adapter) emit(v any) {
	b, _ := json.Marshal(v)
	a.out.Write(append(b, '\n'))
}

func (a *adapter) statePath(p ...string) string {
	return filepath.Join(append([]string{a.c.State}, p...)...)
}

func (a *adapter) load() error {
	b, err := os.ReadFile(a.statePath("agent.json"))
	if errors.Is(err, os.ErrNotExist) {
		a.nat = native{Kind: "pi"}
		return nil
	}
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, &a.nat); err != nil {
		return fmt.Errorf("agent: agent.json: %w", err)
	}
	if a.nat.Kind != "pi" {
		return fmt.Errorf("agent: state belongs to %q, not pi", a.nat.Kind)
	}
	return nil
}

func (a *adapter) save() error {
	b, _ := json.Marshal(a.nat)
	tmp := a.statePath("agent.json.tmp")
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, a.statePath("agent.json"))
}

func (a *adapter) env() []string {
	var env []string
	for _, k := range passEnv {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
		}
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

func (a *adapter) piFiles() []string {
	fs, _ := filepath.Glob(a.statePath("pi", "sessions", "*.jsonl"))
	return fs
}

// argv builds Pi's arguments for one turn. The prompt always goes on stdin
// so that text starting with "-" or "@" is never parsed as a flag or file.
func (a *adapter) argv() ([]string, string, error) {
	first := a.nat.Session == ""
	id := a.nat.Session
	if first {
		id = randomID()
	}
	// --no-approve keeps a repo's .pi/extensions from loading.
	args := []string{"--mode", "json", "-p", "--no-approve", "--no-skills"}
	if a.c.Model != "" {
		args = append(args, "--provider", "openrouter", "--model", a.c.Model)
	}
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
	return append(args, a.c.Args...), id, nil
}

// reported extracts the session id Pi announces on stdout.
func reported(line []byte) string {
	var m struct {
		Type string `json:"type"`
		ID   string `json:"id"`
	}
	if json.Unmarshal(line, &m) != nil || m.Type != "session" {
		return ""
	}
	return m.ID
}

func (a *adapter) turn(text string, stderr io.Writer) error {
	args, want, err := a.argv()
	if err != nil {
		return err
	}
	before := len(a.piFiles())
	cmd := exec.Command(a.c.Bin, args...)
	cmd.Dir = a.c.State
	cmd.Env = a.env()
	cmd.Stdin = strings.NewReader(text)
	cmd.Stderr = stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	start := time.Now()
	if err := cmd.Start(); err != nil {
		return err
	}

	var got, failed string
	var firstOut time.Duration
	var use Usage
	br := bufio.NewReaderSize(stdout, 1<<16)
	for {
		line, rerr := br.ReadBytes('\n')
		if s := bytes.TrimRight(line, "\r\n"); len(s) > 0 {
			if firstOut == 0 {
				firstOut = time.Since(start)
			}
			if got == "" {
				got = reported(s)
			}
			use.add(usageOf(s))
			if f, ok := piStop(s); ok {
				failed = f
			}
			a.out.Write(append(s, '\n'))
		}
		if rerr != nil {
			break
		}
	}
	werr := cmd.Wait()
	code := cmd.ProcessState.ExitCode()
	a.nat.Total.add(use)

	switch {
	case got == "" && code == 0:
		err = fmt.Errorf("%w: pi reported no session id", ErrSession)
	case got != "" && got != want:
		err = fmt.Errorf("%w: expected %s, pi reported %s", ErrSession, want, got)
	case a.nat.Session != "" && len(a.piFiles()) != before:
		err = fmt.Errorf("%w: pi wrote a new session file instead of resuming", ErrSession)
	}
	if err == nil && got != "" && a.nat.Session == "" {
		a.nat.Session = got
	}
	if err == nil && code == 0 && failed == "" {
		a.nat.Turns++
	}
	if serr := a.save(); err == nil {
		err = serr
	}
	end := map[string]any{"type": "fleet.turn_end", "turn": a.nat.Turns, "code": code, "session": a.nat.Session, "usage": use,
		"first_output_ms": firstOut.Milliseconds(), "ms": time.Since(start).Milliseconds()}
	if werr != nil {
		end["error"] = werr.Error()
	} else if failed != "" {
		end["error"] = failed
	}
	a.emit(end)
	if err == nil && code != 0 {
		err = fmt.Errorf("agent: pi exited %d", code)
	}
	if err == nil && failed != "" {
		err = fmt.Errorf("agent: pi turn failed (see fleet.turn_end)")
	}
	return err
}

// piStop reads an assistant message_end and reports whether it decides the
// turn's outcome and, if so, why it failed. Pi exits 0 even when the model
// call fails, so the last assistant message is the source of truth.
func piStop(line []byte) (failed string, ok bool) {
	var m struct {
		Type    string `json:"type"`
		Message struct {
			Role       string `json:"role"`
			StopReason string `json:"stopReason"`
			Error      string `json:"errorMessage"`
		} `json:"message"`
	}
	if json.Unmarshal(line, &m) != nil || m.Type != "message_end" || m.Message.Role != "assistant" {
		return "", false
	}
	switch m.Message.StopReason {
	case "error", "aborted":
		if m.Message.Error != "" {
			return "pi: " + m.Message.Error, true
		}
		return "pi: stopReason " + m.Message.StopReason, true
	}
	return "", true
}

// Usage is model tokens as Pi reports them; input includes cached tokens.
// fleet.turn_end carries one turn's total.
type Usage struct {
	Input  int64 `json:"input"`
	Output int64 `json:"output"`
}

func (u *Usage) add(v Usage) { u.Input += v.Input; u.Output += v.Output }

// usageOf reads one stdout line: Pi reports each model call in message_end.
func usageOf(line []byte) Usage {
	var m struct {
		Type    string `json:"type"`
		Message struct {
			Role  string `json:"role"`
			Usage struct{ Input, Output int64 }
		}
	}
	if !bytes.Contains(line, []byte(`usage`)) || json.Unmarshal(line, &m) != nil ||
		m.Type != "message_end" || m.Message.Role != "assistant" {
		return Usage{}
	}
	return Usage{m.Message.Usage.Input, m.Message.Usage.Output}
}

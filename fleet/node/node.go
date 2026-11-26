// Package node is fleetd: it keeps each session's event log, runs its turns
// one at a time, and serves the API and UI. All session rules live in core;
// this package only does the I/O around core.Decide and core.Apply.
package node

import (
	"bytes"
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/TanGentleman/tan-toolchains/fleet/core"
	"github.com/TanGentleman/tan-toolchains/fleet/store"
)

type Config struct {
	Name      string   // node name, recorded in every event
	URL       string   // this node's tailnet URL; its host is an accepted Host header
	Hosts     []string // Host header values accepted besides URL's (the loopback listen address)
	Data      string
	Owners    []string // tailnet logins allowed to use this node; nobody else gets in
	Harnesses map[string]Harness
	Now       func() time.Time
	// Defaults reports what every turn runs with (pi-container's image,
	// egress and model_url) for GET /v1/node; nil leaves it out.
	Defaults func() (any, error)
}

type Node struct {
	cfg   Config
	blobs store.Blobs

	mu         sync.Mutex
	sessions   map[string]*session
	unreadable map[string]string // sid -> why its log was refused at start
	once       sync.Once
}

type session struct {
	usage  Usage // derived from fleet.turn_end lines; never logged
	mu     sync.Mutex
	dir    string
	log    *store.Log
	st     core.State
	broken error
	cancel context.CancelFunc // set while a turn runs
	done   chan struct{}      // closed when that turn's exit is recorded
}

var (
	ErrForbidden = errors.New("forbidden")
	ErrNotFound  = errors.New("no such session")
)

func New(cfg Config) (*Node, error) {
	if cfg.Name == "" || strings.ContainsAny(cfg.Name, "/\x00") {
		return nil, fmt.Errorf("bad node name %q", cfg.Name)
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	n := &Node{cfg: cfg, blobs: store.Blobs{Dir: filepath.Join(cfg.Data, "blobs")}, sessions: map[string]*session{}, unreadable: map[string]string{}}
	if err := os.MkdirAll(filepath.Join(cfg.Data, "sessions"), 0o700); err != nil {
		return nil, err
	}
	// Older versions made it 0755; closing the top closes everything below.
	if err := os.Chmod(cfg.Data, 0o700); err != nil {
		return nil, err
	}
	ents, err := os.ReadDir(filepath.Join(cfg.Data, "sessions"))
	if err != nil {
		return nil, err
	}
	for _, e := range ents {
		s, err := n.open(e.Name())
		if err != nil {
			// Left as it is on disk and out of the node, so one bad log
			// doesn't take the others down. Nothing may write to it.
			msg := fmt.Sprintf("%v (written by another fleetd version? move %s out of %s)", err, e.Name(), filepath.Join(cfg.Data, "sessions"))
			fmt.Fprintf(os.Stderr, "fleetd: skipping unreadable session %s: %s\n", e.Name(), msg)
			n.unreadable[e.Name()] = msg
			continue
		}
		s.mu.Lock()
		// A turn this node was running died with the old process. Stop
		// whatever it left running, then record that; its input is never
		// re-sent, and the next turn starts from the last checkpoint, not
		// from whatever the dead turn left behind.
		if s.st.Running {
			if h, ok := n.cfg.Harnesses[s.st.Harness].(Stopper); ok {
				if err = h.Stop(s.st.Sid, filepath.Join(s.dir, "state")); err != nil {
					err = fmt.Errorf("session %s: stopping the turn the last fleetd left running: %w", e.Name(), err)
				}
			}
		}
		if s.st.Running && err == nil {
			_, err = n.commit(s, n.cmd("", core.Exited, "", core.ExitedData{Code: -1, Reason: "node restarted"}))
		}
		s.mu.Unlock()
		if err != nil {
			return nil, err
		}
	}
	return n, nil
}

func (n *Node) Name() string { return n.cfg.Name }

// Close aborts running turns, recording their exit.
func (n *Node) Close() {
	n.once.Do(func() {
		// In parallel: each turn may take its whole grace period.
		var wg sync.WaitGroup
		for _, s := range n.list() {
			wg.Add(1)
			go func() {
				defer wg.Done()
				n.abort(s)
				s.log.Close()
			}()
		}
		wg.Wait()
	})
}

func (n *Node) cmd(by, kind, key string, data any) core.Cmd {
	return core.Cmd{Node: n.cfg.Name, By: by, T: n.cfg.Now().UTC().Format(time.RFC3339Nano), Kind: kind, Key: key, Data: data}
}

func sessionID(parts ...string) string {
	h := sha256.New()
	for _, p := range parts {
		h.Write([]byte(p))
		h.Write([]byte{0})
	}
	return "s" + hex.EncodeToString(h.Sum(nil))[:16]
}

func validSid(sid string) bool {
	if len(sid) < 2 || len(sid) > 64 {
		return false
	}
	for _, c := range sid {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

// open loads or creates sid's log.
func (n *Node) open(sid string) (*session, error) {
	if !validSid(sid) {
		return nil, ErrNotFound
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	if s, ok := n.sessions[sid]; ok {
		return s, nil
	}
	if why, ok := n.unreadable[sid]; ok {
		return nil, fmt.Errorf("session %s is unreadable: %s", sid, why)
	}
	s := &session{dir: filepath.Join(n.cfg.Data, "sessions", sid)}
	log, err := store.Open(filepath.Join(s.dir, "events.jsonl"), func(line []byte) error {
		var e core.Event
		if err := json.Unmarshal(line, &e); err != nil {
			return err
		}
		return s.apply(e)
	})
	if err != nil {
		return nil, err
	}
	s.log = log
	n.sessions[sid] = s
	return s, nil
}

func (n *Node) get(sid string) *session {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.sessions[sid]
}

func (n *Node) list() []*session {
	n.mu.Lock()
	defer n.mu.Unlock()
	out := make([]*session, 0, len(n.sessions))
	for _, s := range n.sessions {
		out = append(out, s)
	}
	return out
}

// commit decides, applies and durably appends cmds as one fsync. s.mu must
// be held. It returns each command's seq (the original seq for a duplicate).
func (n *Node) commit(s *session, cmds ...core.Cmd) ([]uint64, error) {
	if s.broken != nil {
		return nil, s.broken
	}
	seqs := make([]uint64, len(cmds))
	var lines [][]byte
	for i, c := range cmds {
		e, dup, err := core.Decide(&s.st, c)
		if err != nil {
			if lines == nil {
				return nil, err
			}
			cmds = cmds[:i] // append what was decided so far
			seqs = seqs[:i]
			break
		}
		if dup != 0 {
			seqs[i] = dup
			continue
		}
		b, err := json.Marshal(e)
		if err == nil {
			err = s.apply(e)
		}
		if err != nil {
			s.broken = err
			return nil, err
		}
		lines = append(lines, b)
		seqs[i] = e.Seq
	}
	if len(lines) == 0 {
		return seqs, nil
	}
	if err := s.log.Append(lines...); err != nil {
		// Memory is now ahead of disk; refuse everything until a restart
		// refolds the session from the log.
		s.broken = err
		return nil, err
	}
	return seqs, nil
}

// session returns sid, or ErrNotFound. Access is checked once, by the HTTP
// handler: every route is for owners only.
func (n *Node) session(sid string) (*session, error) {
	if s := n.get(sid); s != nil {
		return s, nil
	}
	return nil, ErrNotFound
}

// Spawn creates a session owned by login and starts it. The same login and
// key always name the same session, so a retried spawn changes nothing.
func (n *Node) Spawn(login, key, prompt string, d core.CreatedData) (string, error) {
	if key == "" {
		return "", errors.New("key required")
	}
	if d.Harness == "" && len(n.cfg.Harnesses) == 1 {
		for h := range n.cfg.Harnesses {
			d.Harness = h // the only one: pi-ctr in fleetd
		}
	}
	if _, ok := n.cfg.Harnesses[d.Harness]; !ok {
		return "", fmt.Errorf("unknown harness %q", d.Harness)
	}
	if !validModel(d.Model) {
		return "", fmt.Errorf("bad model %q", d.Model)
	}
	if d.Repo != "" && !core.IsRepo(d.Repo) || d.Branch != "" && !core.IsBranch(d.Branch) || d.Repo == "" && d.Branch != "" {
		return "", fmt.Errorf("bad repo %q or branch %q", d.Repo, d.Branch)
	}
	sid := sessionID("spawn", n.cfg.Name, login, key)
	d = core.CreatedData{Owner: login, Harness: d.Harness, Model: d.Model, Title: d.Title, Repo: d.Repo, Branch: d.Branch}
	return sid, n.create(sid, login, key, d, prompt)
}

// readResult reads what a harness reports in $FLEET_RESULT: the commit it
// pushed, the base it started from, and an error explaining a failed turn.
// A missing file means nothing was pushed; anything malformed is ignored,
// and bad says why.
func readResult(path, base string) (r core.ExitedData, bad string) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return r, ""
	}
	var v struct{ Commit, Base, Error string }
	switch {
	case err != nil:
		return r, err.Error()
	case len(b) > 4096:
		return r, "over 4 KiB"
	case json.Unmarshal(b, &v) != nil:
		return r, "not JSON"
	case v.Commit != "" && !core.IsCommit(v.Commit) || v.Base != "" && !core.IsCommit(v.Base):
		return r, "commit and base must be full lowercase hex ids"
	case v.Base != "" && base != "" && v.Base != base:
		return r, "base differs from the session's"
	case len(v.Error) > 500 || strings.ContainsFunc(v.Error, unicode.IsControl):
		return r, "error must be one line of at most 500 bytes"
	}
	if base != "" {
		v.Base = ""
	}
	return core.ExitedData{Commit: v.Commit, Base: v.Base, Reason: v.Error}, ""
}

// validModel accepts ids like "anthropic/claude-haiku-5.5" or "".
func validModel(m string) bool {
	if len(m) > 200 {
		return false
	}
	for _, c := range m {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("-._/:@", c)) {
			return false
		}
	}
	return true
}

func (n *Node) create(sid, login, key string, d core.CreatedData, prompt string) error {
	s, err := n.open(sid)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.st.Head > 0 {
		return nil
	}
	s.st.Sid = sid
	if _, err := n.commit(s, n.cmd(login, core.Created, key, d)); err != nil {
		return err
	}
	if prompt != "" {
		_, err = n.input(s, login, key+"/prompt", prompt)
	}
	return err
}

// turn runs one harness process for the input just committed, then records
// its checkpoint and exit in one append. It owns the state dir while it runs.
func (n *Node) turn(ctx context.Context, s *session, done chan struct{}, h Harness, run int, t Turn, files []core.File) {
	defer close(done)
	t.State = filepath.Join(s.dir, "state")
	state := t.State
	code, reason := -1, ""
	var snap []core.File
	var res core.ExitedData
	err := n.restore(state, files)
	if err == nil && t.Result != "" {
		if err = os.Remove(t.Result); errors.Is(err, os.ErrNotExist) {
			err = nil
		}
	}
	if err != nil {
		reason = "restore: " + err.Error()
	} else {
		stderr, _ := os.OpenFile(filepath.Join(s.dir, fmt.Sprintf("stderr-%d.log", run)), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if stderr != nil {
			t.Stderr = stderr
			defer stderr.Close()
		}
		out := &outWriter{n: n, s: s}
		code, err = h.Run(ctx, t, out)
		out.flush()
		switch {
		case ctx.Err() != nil:
			reason = "aborted"
		case err != nil:
			reason = err.Error()
		}
		// A failed turn's state stands: the harness finished writing it. An
		// aborted one may be half written, so the next turn restores the
		// last checkpoint instead.
		if ctx.Err() == nil {
			if snap, err = n.snapshot(state); err != nil {
				reason += "; checkpoint: " + err.Error()
			}
			if t.Result != "" {
				var bad string
				if res, bad = readResult(t.Result, t.Base); bad != "" {
					reason += "; result ignored: " + bad
				} else if res.Reason != "" {
					reason += "; " + res.Reason
				}
			}
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var cmds []core.Cmd
	if snap != nil && !slices.Equal(snap, s.st.Files) {
		cmds = append(cmds, n.cmd("", core.Checkpoint, "", core.CheckpointData{Files: snap}))
	}
	cmds = append(cmds, n.cmd("", core.Exited, "", core.ExitedData{Code: code, Reason: strings.TrimPrefix(reason, "; "), Commit: res.Commit, Base: res.Base}))
	n.commit(s, cmds...)
	s.cancel = nil
}

// outWriter records harness stdout, one event per line. Each Write commits
// the complete lines it holds with one fsync.
type outWriter struct {
	n   *Node
	s   *session
	buf []byte
}

func (w *outWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	var cmds []core.Cmd
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		if line := bytes.TrimRight(w.buf[:i], "\r"); len(line) > 0 {
			cmds = append(cmds, w.n.out(line))
		}
		w.buf = w.buf[i+1:]
	}
	if len(cmds) == 0 {
		return len(p), nil
	}
	w.s.mu.Lock()
	defer w.s.mu.Unlock()
	if _, err := w.n.commit(w.s, cmds...); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (w *outWriter) flush() {
	if len(w.buf) > 0 {
		w.Write([]byte{'\n'})
	}
}

func (n *Node) out(line []byte) core.Cmd {
	c := n.cmd("", core.Out, "", nil)
	c.Line = append([]byte(nil), line...)
	return c
}

// abort cancels the running turn, if any, and waits until its exit is
// recorded.
func (n *Node) abort(s *session) {
	s.mu.Lock()
	cancel, done := s.cancel, s.done
	s.mu.Unlock()
	if cancel != nil {
		cancel()
		<-done
	}
}

// Abort stops the running turn of sid. It is a no-op when none is running.
func (n *Node) Abort(sid string) error {
	s, err := n.session(sid)
	if err != nil {
		return err
	}
	n.abort(s)
	return nil
}

// snapshot stores the files under root as blobs and lists them by name.
func (n *Node) snapshot(root string) ([]core.File, error) {
	files := []core.File{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || !d.Type().IsRegular() {
			return err
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		sha, size, err := n.blobs.Put(f)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		files = append(files, core.File{Name: filepath.ToSlash(rel), Sha: sha, Size: size})
		return nil
	})
	sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
	return files, err
}

// restore replaces dir with exactly the checkpointed files.
func (n *Node) restore(dir string, files []core.File) error {
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	for _, f := range files {
		if !filepath.IsLocal(f.Name) {
			return fmt.Errorf("checkpoint file %q escapes the state dir", f.Name)
		}
		b, err := os.ReadFile(n.blobs.Path(f.Sha))
		if err != nil {
			return fmt.Errorf("checkpoint blob %s: %w", f.Sha, err)
		}
		p := filepath.Join(dir, filepath.FromSlash(f.Name))
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			return err
		}
		if err := os.WriteFile(p, b, 0o600); err != nil {
			return err
		}
	}
	return nil
}

// Input records a prompt and runs it as a turn. A retried key returns the
// first seq and runs nothing; an input while a turn runs is ErrRunning.
func (n *Node) Input(login, sid, key, text string) (uint64, error) {
	if key == "" {
		return 0, errors.New("key required")
	}
	s, err := n.session(sid)
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return n.input(s, login, key, text)
}

func (n *Node) input(s *session, login, key, text string) (uint64, error) {
	h, ok := n.cfg.Harnesses[s.st.Harness]
	if !ok {
		return 0, fmt.Errorf("unknown harness %q", s.st.Harness)
	}
	before := s.st.Head
	seqs, err := n.commit(s, n.cmd(login, core.Input, key, core.InputData{Text: text}))
	if err != nil {
		return 0, err
	}
	if seqs[0] <= before {
		return seqs[0], nil // duplicate
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel, s.done = cancel, make(chan struct{})
	t := Turn{Sid: s.st.Sid, Prompt: text, Model: s.st.Model, Repo: s.st.Repo, Branch: s.st.Branch, Base: s.st.Base}
	if t.Repo != "" {
		t.Push = "fleet/" + s.st.Sid
		t.Result = filepath.Join(s.dir, fmt.Sprintf("result-%d.json", s.st.Run))
	}
	go n.turn(ctx, s, s.done, h, s.st.Run, t, s.st.Files)
	return seqs[0], nil
}

// Fork starts a new session from sid's latest checkpoint and last pushed
// commit. The original is untouched.
func (n *Node) Fork(login, sid, key string) (string, error) {
	if key == "" {
		return "", errors.New("key required")
	}
	s, err := n.session(sid)
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	d := core.CreatedData{Owner: login, Harness: s.st.Harness, Model: s.st.Model, Title: s.st.Title, ForkOf: sid, ForkAt: s.st.Head, Files: s.st.Files,
		Repo: s.st.Repo, Branch: s.st.Branch, Base: cmp.Or(s.st.Commit, s.st.Base)}
	s.mu.Unlock()
	fid := sessionID("fork", n.cfg.Name, login, key, sid)
	// Files are the state after the last finished turn.
	return fid, n.create(fid, login, key, d, "")
}

// State returns a copy of sid's folded state.
func (n *Node) State(sid string) (core.State, error) {
	s, err := n.session(sid)
	if err != nil {
		return core.State{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.st, nil
}

// Events returns durable event lines after `after` and a channel closed on
// the next append.
func (n *Node) Events(sid string, after uint64) ([][]byte, <-chan struct{}, error) {
	s, err := n.session(sid)
	if err != nil {
		return nil, nil, err
	}
	lines, ch := s.log.Read(after)
	return lines, ch, nil
}

type Summary struct {
	core.State
	Usage Usage `json:"usage"`
}

// Usage totals the model tokens a session's harness reported in
// {"type":"fleet.turn_end","usage":{"input","output"}} lines. It is a view
// over the log, rebuilt whenever the log is loaded.
type Usage struct {
	Input  int64 `json:"input"`
	Output int64 `json:"output"`
}

// apply is core.Apply plus the derived views.
func (s *session) apply(e core.Event) error {
	if err := core.Apply(&s.st, e); err != nil {
		return err
	}
	if e.Kind != core.Out {
		return nil
	}
	var line string
	if json.Unmarshal(e.Data, &line) != nil || !strings.Contains(line, `"fleet.turn_end"`) {
		return nil
	}
	var m struct {
		Type  string
		Usage Usage
	}
	if json.Unmarshal([]byte(line), &m) == nil && m.Type == "fleet.turn_end" && m.Usage.Input >= 0 && m.Usage.Output >= 0 {
		s.usage.Input += m.Usage.Input
		s.usage.Output += m.Usage.Output
	}
	return nil
}

// Unreadable returns the sessions whose logs were refused at start, and why.
func (n *Node) Unreadable() map[string]string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return maps.Clone(n.unreadable)
}

func (n *Node) List() []Summary {
	var out []Summary
	for _, s := range n.list() {
		s.mu.Lock()
		if s.st.Head > 0 {
			out = append(out, Summary{State: s.st, Usage: s.usage})
		}
		s.mu.Unlock()
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Updated != out[j].Updated {
			return out[i].Updated > out[j].Updated
		}
		return out[i].Sid < out[j].Sid
	})
	return out
}

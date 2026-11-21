// Package node is fleetd: it runs the sessions it writes, keeps a local copy
// of every session it has seen, and moves a session to another node by
// sealing it there. All session rules live in core; this package only does
// the I/O around core.Decide and core.Apply.
package node

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/core"
	"github.com/TanGentleman/tan-toolchains/fleet/store"
)

type Config struct {
	Name      string // node name; the writer field in every event
	URL       string // where other nodes reach this one (its tailnet URL)
	Data      string
	Policy    core.Policy
	Harnesses map[string]Harness
	Peers     []string // base URLs to copy sessions from
	PeerLogin string   // login sent on background pulls
	PullEvery time.Duration
	Client    *http.Client
	Now       func() time.Time
}

type Node struct {
	cfg   Config
	blobs store.Blobs

	mu       sync.Mutex
	sessions map[string]*session

	stop chan struct{}
	wg   sync.WaitGroup
	once sync.Once
}

type session struct {
	usage    Usage // derived from fleet.turn_end lines; never logged
	mu       sync.Mutex
	dir      string
	log      *store.Log
	st       core.State
	broken   error
	proc     Proc
	stopping bool
	pumped   chan struct{}
}

var (
	ErrForbidden   = errors.New("forbidden")
	ErrNotFound    = errors.New("no such session")
	ErrUnreachable = errors.New("writer unreachable; fork instead")
	ErrDiverged    = errors.New("replica diverged from source")
)

func New(cfg Config) (*Node, error) {
	if cfg.Name == "" || strings.ContainsAny(cfg.Name, "/\x00") {
		return nil, fmt.Errorf("bad node name %q", cfg.Name)
	}
	if cfg.PullEvery == 0 {
		cfg.PullEvery = 2 * time.Second
	}
	if cfg.Client == nil {
		cfg.Client = &http.Client{Timeout: 30 * time.Second}
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	n := &Node{cfg: cfg, blobs: store.Blobs{Dir: filepath.Join(cfg.Data, "blobs")},
		sessions: map[string]*session{}, stop: make(chan struct{})}
	if err := os.MkdirAll(filepath.Join(cfg.Data, "sessions"), 0o755); err != nil {
		return nil, err
	}
	ents, err := os.ReadDir(filepath.Join(cfg.Data, "sessions"))
	if err != nil {
		return nil, err
	}
	for _, e := range ents {
		s, err := n.open(e.Name())
		if err != nil {
			return nil, fmt.Errorf("session %s: %w", e.Name(), err)
		}
		s.mu.Lock()
		// A run this node was writing died with the old process. Record that;
		// the inputs it had are never re-sent.
		if s.st.Running && s.st.Writer == cfg.Name {
			_, err = n.commit(s, n.cmd("", core.Exited, "", core.ExitedData{Code: -1, Reason: "node restarted"}))
		}
		s.mu.Unlock()
		if err != nil {
			return nil, err
		}
	}
	if len(cfg.Peers) > 0 {
		n.wg.Add(1)
		go n.pullLoop()
	}
	return n, nil
}

func (n *Node) Name() string { return n.cfg.Name }

// Close stops runs (recording their exit) and the pull loop.
func (n *Node) Close() {
	n.once.Do(func() {
		close(n.stop)
		n.wg.Wait()
		for _, s := range n.list() {
			n.stopRun(s)
			s.log.Close()
		}
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

// open loads or creates the local copy of sid.
func (n *Node) open(sid string) (*session, error) {
	if !validSid(sid) {
		return nil, ErrNotFound
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	if s, ok := n.sessions[sid]; ok {
		return s, nil
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

func (n *Node) level(login string, s *session) core.Level {
	return n.cfg.Policy.Level(login, &s.st)
}

// session returns sid if login has at least lvl on it.
func (n *Node) session(login, sid string, lvl core.Level) (*session, error) {
	s := n.get(sid)
	if s == nil {
		return nil, ErrNotFound
	}
	s.mu.Lock()
	l := n.level(login, s)
	s.mu.Unlock()
	if l == core.None {
		return nil, ErrNotFound
	}
	if l < lvl {
		return nil, ErrForbidden
	}
	return s, nil
}

// Spawn creates a session owned by login and starts it. The same login and
// key always name the same session, so a retried spawn changes nothing.
func (n *Node) Spawn(login, harness, model, title, key, prompt string) (string, error) {
	if !n.cfg.Policy.CanSpawn(login) {
		return "", ErrForbidden
	}
	if key == "" {
		return "", errors.New("key required")
	}
	if _, ok := n.cfg.Harnesses[harness]; !ok {
		return "", fmt.Errorf("unknown harness %q", harness)
	}
	if !validModel(model) {
		return "", fmt.Errorf("bad model %q", model)
	}
	sid := sessionID("spawn", n.cfg.Name, login, key)
	return sid, n.create(sid, login, key, core.CreatedData{Owner: login, Harness: harness, Model: model, Title: title}, prompt)
}

// validModel accepts ids like "anthropic/claude-haiku-4.5" or "".
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
	if err := n.start(s); err != nil {
		return err
	}
	if prompt != "" {
		_, err = n.input(s, login, key+"/prompt", "prompt", prompt)
	}
	return err
}

// start begins a run. s.mu must be held and this node must be the writer.
func (n *Node) start(s *session) error {
	if s.st.Running {
		return nil
	}
	h, ok := n.cfg.Harnesses[s.st.Harness]
	if !ok {
		return fmt.Errorf("unknown harness %q", s.st.Harness)
	}
	state := filepath.Join(s.dir, "state")
	if s.st.RunNode != n.cfg.Name {
		// The last run was elsewhere (or never happened): rebuild the
		// harness state from the latest checkpoint.
		if err := n.restore(state, s.st.Files); err != nil {
			return err
		}
	}
	work := filepath.Join(s.dir, "work")
	if err := os.MkdirAll(work, 0o755); err != nil {
		return err
	}
	if _, err := n.commit(s, n.cmd("", core.Started, "", core.StartedData{URL: n.cfg.URL})); err != nil {
		return err
	}
	stderr, err := os.OpenFile(filepath.Join(s.dir, fmt.Sprintf("stderr-%d.log", s.st.Run)), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	spec := Spec{Sid: s.st.Sid, Work: work, State: state, Stderr: stderr}
	if s.st.Model != "" {
		spec.Env = []string{"FLEET_SESSION_MODEL=" + s.st.Model}
	}
	p, err := h.Start(spec)
	if err != nil {
		stderr.Close()
		n.commit(s, n.cmd("", core.Exited, "", core.ExitedData{Code: -1, Reason: "start: " + err.Error()}))
		return err
	}
	s.proc, s.stopping, s.pumped = p, false, make(chan struct{})
	go n.pump(s, p, stderr)
	return nil
}

// pump records harness output in batches, one fsync per batch.
func (n *Node) pump(s *session, p Proc, stderr io.Closer) {
	defer stderr.Close()
	lines := p.Lines()
	for line := range lines {
		batch := []core.Cmd{n.out(line)}
	drain:
		for len(batch) < 512 {
			select {
			case l, ok := <-lines:
				if !ok {
					break drain
				}
				batch = append(batch, n.out(l))
			default:
				break drain
			}
		}
		s.mu.Lock()
		n.commit(s, batch...)
		s.mu.Unlock()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	reason := "harness exited"
	if s.stopping {
		reason = "stopped"
	}
	n.checkpoint(s)
	n.commit(s, n.cmd("", core.Exited, "", core.ExitedData{Code: p.Code(), Reason: reason}))
	s.proc = nil
	close(s.pumped)
}

func (n *Node) out(line []byte) core.Cmd {
	c := n.cmd("", core.Out, "", nil)
	c.Line = line
	return c
}

// stopRun ends the current run, if any, and waits until its exit is recorded.
func (n *Node) stopRun(s *session) {
	s.mu.Lock()
	p, done := s.proc, s.pumped
	if p != nil {
		s.stopping = true
	}
	s.mu.Unlock()
	if p != nil {
		p.Stop()
		<-done
	}
}

// checkpoint stores the harness state files as blobs and records them if
// they changed. s.mu must be held.
func (n *Node) checkpoint(s *session) error {
	root := filepath.Join(s.dir, "state")
	var files []core.File
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
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
	if err != nil {
		return err
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
	if slices.Equal(files, s.st.Files) {
		return nil
	}
	_, err = n.commit(s, n.cmd("", core.Checkpoint, "", core.CheckpointData{Files: files}))
	return err
}

func (n *Node) restore(dir string, files []core.File) error {
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
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
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(p, b, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// Input records an input and then sends it to the harness. A retried key
// returns the first seq and is not sent again.
func (n *Node) Input(login, sid, key, kind, text string) (uint64, error) {
	if key == "" {
		return 0, errors.New("key required")
	}
	s, err := n.session(login, sid, core.Steer)
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return n.input(s, login, key, kind, text)
}

func (n *Node) input(s *session, login, key, kind, text string) (uint64, error) {
	before := s.st.Head
	seqs, err := n.commit(s, n.cmd(login, core.Input, key, core.InputData{Kind: kind, Text: text}))
	if err != nil {
		return 0, err
	}
	if seqs[0] <= before {
		return seqs[0], nil // duplicate
	}
	line, _ := json.Marshal(map[string]string{"type": kind, "id": key, "message": text})
	if err := s.proc.Send(line); err != nil {
		return seqs[0], fmt.Errorf("recorded at seq %d, but the harness did not take it: %w", seqs[0], err)
	}
	return seqs[0], nil
}

// Seal ends the run and makes node `to` the writer. Returns the new head.
func (n *Node) Seal(login, sid, to string) (uint64, error) {
	if to == "" {
		return 0, errors.New("to required")
	}
	s, err := n.session(login, sid, core.Steer)
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	if s.st.Writer != n.cfg.Name {
		defer s.mu.Unlock()
		if s.st.Writer == to {
			return s.st.Head, nil // already sealed to `to`: a retry
		}
		return 0, fmt.Errorf("%w (writer is %s)", core.ErrNotWriter, s.st.Writer)
	}
	s.mu.Unlock()
	n.stopRun(s)
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := n.checkpoint(s); err != nil {
		return 0, err
	}
	if to == n.cfg.Name {
		return s.st.Head, nil
	}
	if _, err := n.commit(s, n.cmd(login, core.Sealed, "", core.SealedData{To: to})); err != nil {
		return 0, err
	}
	return s.st.Head, nil
}

// Resume makes this node the writer and starts a run. If another node is
// the writer it asks that node to seal to this one, then copies the log.
// from is the writer's URL when this node has no copy yet.
func (n *Node) Resume(ctx context.Context, login, sid, from string) error {
	s, err := n.session(login, sid, core.Steer)
	if errors.Is(err, ErrNotFound) && from != "" && validSid(sid) {
		if err := n.Pull(ctx, from, sid, login); err != nil {
			return err
		}
		s, err = n.session(login, sid, core.Steer)
	}
	if err != nil {
		return err
	}
	s.mu.Lock()
	writer, url := s.st.Writer, s.st.WriterURL
	s.mu.Unlock()
	if writer != n.cfg.Name {
		if url == "" {
			url = from
		}
		if url == "" {
			return fmt.Errorf("%w: no URL for writer %s", ErrUnreachable, writer)
		}
		var res struct{ Head uint64 }
		if err := n.call(ctx, http.MethodPost, url+"/v1/sessions/"+sid+"/seal", login, map[string]string{"to": n.cfg.Name}, &res); err != nil {
			return err
		}
		if err := n.Pull(ctx, url, sid, login); err != nil {
			return err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return n.start(s)
}

// Fork starts a new session from the latest checkpoint of a local copy. The
// original is untouched, which is what makes forking safe while its writer
// is unreachable.
func (n *Node) Fork(login, sid, key string) (string, error) {
	if key == "" {
		return "", errors.New("key required")
	}
	if !n.cfg.Policy.CanSpawn(login) {
		return "", ErrForbidden
	}
	s, err := n.session(login, sid, core.View)
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	d := core.CreatedData{Owner: login, Harness: s.st.Harness, Model: s.st.Model, Title: s.st.Title, ForkOf: sid, ForkAt: s.st.Head, Files: s.st.Files}
	s.mu.Unlock()
	fid := sessionID("fork", n.cfg.Name, login, key, sid)
	return fid, n.create(fid, login, key, d, "")
}

func (n *Node) Share(login, sid, user string, lvl core.Level) error {
	s, err := n.session(login, sid, core.Admin)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err = n.commit(s, n.cmd(login, core.Shared, "", core.SharedData{User: user, Level: lvl}))
	return err
}

// State returns a copy of sid's folded state.
func (n *Node) State(login, sid string) (core.State, error) {
	s, err := n.session(login, sid, core.View)
	if err != nil {
		return core.State{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.st, nil
}

// Events returns durable event lines after `after` and a channel closed on
// the next append.
func (n *Node) Events(login, sid string, after uint64) ([][]byte, <-chan struct{}, error) {
	s, err := n.session(login, sid, core.View)
	if err != nil {
		return nil, nil, err
	}
	lines, ch := s.log.Read(after)
	return lines, ch, nil
}

type Summary struct {
	core.State
	Level core.Level `json:"level"`
	Usage Usage      `json:"usage"`
}

// Usage totals the model tokens a session's harness reported in
// {"type":"fleet.turn_end","usage":{"input","output"}} lines. It is a view
// over the log, rebuilt on every fold, so every copy agrees.
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

func (n *Node) List(login string) []Summary {
	var out []Summary
	for _, s := range n.list() {
		s.mu.Lock()
		if l := n.level(login, s); l > core.None && s.st.Head > 0 {
			out = append(out, Summary{State: s.st, Level: l, Usage: s.usage})
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

// BlobPath returns a checkpoint blob if login can view a session that
// references it.
func (n *Node) BlobPath(login, sha string) (string, error) {
	for _, s := range n.list() {
		s.mu.Lock()
		ok := n.level(login, s) > core.None && slices.ContainsFunc(s.st.Files, func(f core.File) bool { return f.Sha == sha })
		s.mu.Unlock()
		if ok && n.blobs.Has(sha) {
			return n.blobs.Path(sha), nil
		}
	}
	return "", ErrNotFound
}

// Package node is fleetd: it owns the sessions it runs, records them in
// per-session journals, copies other nodes' sessions, and serves them.
package node

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/internal/authz"
	"github.com/TanGentleman/tan-toolchains/fleet/internal/harness"
	"github.com/TanGentleman/tan-toolchains/fleet/internal/journal"
)

type Config struct {
	Name       string
	Data       string
	Harnesses  harness.Registry
	Peers      []string // base URLs of other fleetd nodes
	Identify   func(*http.Request) (authz.Principal, error)
	SyncEvery  time.Duration
	PullEvery  time.Duration
	Client     *http.Client
	PeerHeader http.Header // added to requests to peers (dev identity)
}

type Node struct {
	cfg Config

	mu       sync.Mutex
	sessions map[string]*Session
	peerURL  map[string]string // node name -> base URL

	stop     chan struct{}
	stopOnce sync.Once
	wg       sync.WaitGroup
}

type Session struct {
	ID  string
	dir string
	j   *journal.Journal

	mu      sync.Mutex
	proc    harness.Proc
	pumping chan struct{} // closed when the current run's pump exits
	sealing bool
}

var (
	ErrNotOwner    = errors.New("this node does not own the session")
	ErrUnreachable = errors.New("owner unreachable; fork instead")
)

func New(cfg Config) (*Node, error) {
	if cfg.SyncEvery == 0 {
		cfg.SyncEvery = 10 * time.Millisecond
	}
	if cfg.PullEvery == 0 {
		cfg.PullEvery = 2 * time.Second
	}
	if cfg.Client == nil {
		cfg.Client = &http.Client{Timeout: 10 * time.Second}
	}
	n := &Node{cfg: cfg, sessions: map[string]*Session{}, peerURL: map[string]string{}, stop: make(chan struct{})}
	for _, d := range []string{"sessions", "blobs"} {
		if err := os.MkdirAll(filepath.Join(cfg.Data, d), 0o755); err != nil {
			return nil, err
		}
	}
	ents, err := os.ReadDir(filepath.Join(cfg.Data, "sessions"))
	if err != nil {
		return nil, err
	}
	for _, e := range ents {
		s, err := n.open(e.Name())
		if err != nil {
			return nil, fmt.Errorf("open %s: %w", e.Name(), err)
		}
		m := s.Meta()
		if m.Node == cfg.Name && (m.State == "running" || m.State == "busy") {
			n.appendEv(s, m.Run, "run.interrupted", "", "", map[string]any{"reason": "node restarted", "unknown": m.Unknown}, nil)
		}
	}
	if len(cfg.Peers) > 0 {
		n.wg.Add(1)
		go n.pullLoop()
	}
	return n, nil
}

func (n *Node) Name() string { return n.cfg.Name }

func (n *Node) open(sid string) (*Session, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if s, ok := n.sessions[sid]; ok {
		return s, nil
	}
	dir := filepath.Join(n.cfg.Data, "sessions", sid)
	j, err := journal.Open(dir, n.cfg.SyncEvery)
	if err != nil {
		return nil, err
	}
	s := &Session{ID: sid, dir: dir, j: j}
	n.sessions[sid] = s
	return s, nil
}

func (n *Node) get(sid string) *Session {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.sessions[sid]
}

func (n *Node) list() []*Session {
	n.mu.Lock()
	defer n.mu.Unlock()
	out := make([]*Session, 0, len(n.sessions))
	for _, s := range n.sessions {
		out = append(out, s)
	}
	sort.Slice(out, func(i, k int) bool { return out[i].ID < out[k].ID })
	return out
}

func (s *Session) Meta() Meta { return fold(s.ID, s.j.All()) }

// allMeta folds pending (not yet durable) events too; only the writer uses it.
func (n *Node) appendEv(s *Session, run int, kind, by, key string, data any, raw []byte) (uint64, bool, error) {
	b, err := json.Marshal(data)
	if err != nil {
		return 0, false, err
	}
	if data == nil {
		b = nil
	}
	return s.j.Append(journal.Event{Sid: s.ID, Run: run, Node: n.cfg.Name, By: by, Key: key, Kind: kind, Data: b}, raw)
}

func id(parts ...string) string {
	h := sha256.New()
	for _, p := range parts {
		h.Write([]byte(p))
		h.Write([]byte{0})
	}
	return "s" + hex.EncodeToString(h.Sum(nil))[:15]
}

// Spawn creates a session owned by p and starts its first run. The same
// (caller, key) always names the same session, so retries are harmless.
func (n *Node) Spawn(ctx context.Context, p authz.Principal, harnessName, title, key string) (*Session, bool, error) {
	if key == "" {
		return nil, false, errors.New("key required")
	}
	h, err := n.cfg.Harnesses.Get(harnessName)
	if err != nil {
		return nil, false, err
	}
	sid := id("spawn", n.cfg.Name, p.Login, key)
	if s := n.get(sid); s != nil {
		return s, true, nil
	}
	s, err := n.open(sid)
	if err != nil {
		return nil, false, err
	}
	seq, _, err := n.appendEv(s, 0, "session.created", p.Login, "", map[string]any{
		"owner": p.Login, "owner_display": p.Display, "harness": harnessName, "title": title}, nil)
	if err != nil {
		return nil, false, err
	}
	if err := s.j.WaitDurable(ctx, seq); err != nil {
		return nil, false, err
	}
	return s, false, n.startRun(ctx, s, h, false)
}

func (n *Node) startRun(ctx context.Context, s *Session, h harness.Harness, resume bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.proc != nil {
		return nil
	}
	m := s.Meta()
	run := m.Run + 1
	work := filepath.Join(s.dir, "work")
	if err := os.MkdirAll(work, 0o755); err != nil {
		return err
	}
	seq, _, err := n.appendEv(s, run, "run.started", "", "", map[string]any{"node": n.cfg.Name, "resume": resume}, nil)
	if err != nil {
		return err
	}
	if err := s.j.WaitDurable(ctx, seq); err != nil {
		return err
	}
	proc, err := h.Start(context.Background(), harness.Spec{Sid: s.ID, Work: work, Native: filepath.Join(s.dir, "native"), Resume: resume})
	if err != nil {
		n.appendEv(s, run, "run.interrupted", "", "", map[string]any{"reason": "harness start: " + err.Error()}, nil)
		return err
	}
	s.proc = proc
	s.sealing = false
	done := make(chan struct{})
	s.pumping = done
	go n.pump(s, h, proc, run, done)
	return nil
}

func (n *Node) pump(s *Session, h harness.Harness, proc harness.Proc, run int, done chan struct{}) {
	defer close(done)
	for out := range proc.Out() {
		raw := out.Raw
		if len(out.Events) == 0 {
			n.appendEv(s, run, "harness.raw", "", "", nil, raw)
			continue
		}
		for _, e := range out.Events {
			n.appendEv(s, run, e.Kind, "agent", "", e.Data, raw)
			raw = nil
			if e.Kind == "turn.end" {
				n.checkpoint(s, h, run)
			}
		}
	}
	s.mu.Lock()
	sealing := s.sealing
	if s.proc == proc {
		s.proc = nil
	}
	s.mu.Unlock()
	if !sealing {
		m := s.Meta()
		n.appendEv(s, run, "run.interrupted", "", "", map[string]any{"reason": "harness exited", "unknown": m.Unknown}, nil)
	}
}

// checkpoint stores the harness's native files as blobs and records them.
func (n *Node) checkpoint(s *Session, h harness.Harness, run int) error {
	var files []File
	for _, name := range h.NativeFiles() {
		b, err := os.ReadFile(filepath.Join(s.dir, "native", name))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		sha, err := n.putBlob(b)
		if err != nil {
			return err
		}
		files = append(files, File{Name: name, Sha: sha, Size: int64(len(b))})
	}
	_, _, err := n.appendEv(s, run, "checkpoint", "", "", map[string]any{"files": files}, nil)
	return err
}

func (n *Node) blobPath(sha string) string { return filepath.Join(n.cfg.Data, "blobs", sha) }

func (n *Node) putBlob(b []byte) (string, error) {
	sum := sha256.Sum256(b)
	sha := hex.EncodeToString(sum[:])
	p := n.blobPath(sha)
	if _, err := os.Stat(p); err == nil {
		return sha, nil
	}
	tmp := p + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return "", err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return "", err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return "", err
	}
	f.Close()
	return sha, os.Rename(tmp, p)
}

// materialize writes a checkpoint's files into a session's native dir.
func (n *Node) materialize(files []File, dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	for _, f := range files {
		b, err := os.ReadFile(n.blobPath(f.Sha))
		if err != nil {
			return fmt.Errorf("checkpoint blob %s: %w", f.Sha, err)
		}
		if err := os.WriteFile(filepath.Join(dir, f.Name), b, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// Input records an input durably, then hands it to the harness. Inputs are
// deduplicated by (caller, key) inside the log itself.
func (n *Node) Input(ctx context.Context, s *Session, p authz.Principal, in harness.Input) (uint64, bool, error) {
	if in.Key == "" {
		return 0, false, errors.New("key required")
	}
	m := s.Meta()
	if m.Node != n.cfg.Name || m.State == "sealed" {
		return 0, false, ErrNotOwner
	}
	h, err := n.cfg.Harnesses.Get(m.Harness)
	if err != nil {
		return 0, false, err
	}
	s.mu.Lock()
	running := s.proc != nil
	s.mu.Unlock()
	if !running && in.Kind != "cancel" {
		if err := n.startRun(ctx, s, h, true); err != nil {
			return 0, false, err
		}
		m = s.Meta()
	}
	seq, dup, err := n.appendEv(s, m.Run, "input", p.Login, in.Key, map[string]any{"kind": in.Kind, "text": in.Text, "by_display": p.Display}, nil)
	if err != nil {
		return 0, false, err
	}
	if err := s.j.WaitDurable(ctx, seq); err != nil {
		return 0, false, err
	}
	if dup {
		return seq, true, nil
	}
	s.mu.Lock()
	proc := s.proc
	s.mu.Unlock()
	if proc == nil {
		return seq, false, nil
	}
	return seq, false, proc.Send(in)
}

// Seal stops the run, checkpoints it and names the only node allowed to
// take over (to; "" means this node). The current owner is the referee, so
// two nodes racing to take over cannot both win.
func (n *Node) Seal(ctx context.Context, s *Session, to string) (uint64, error) {
	if to == "" {
		to = n.cfg.Name
	}
	m := s.Meta()
	if m.Node != n.cfg.Name {
		return 0, ErrNotOwner
	}
	if m.State == "sealed" {
		switch {
		case m.SealedTo == to:
			return m.Head, nil
		case m.SealedTo != n.cfg.Name:
			return 0, fmt.Errorf("already sealed to %s", m.SealedTo)
		}
		seq, _, err := n.appendEv(s, m.Run, "run.sealed", "", "", map[string]any{"node": n.cfg.Name, "to": to}, nil)
		if err != nil {
			return 0, err
		}
		return seq, s.j.WaitDurable(ctx, seq)
	}
	h, err := n.cfg.Harnesses.Get(m.Harness)
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	proc, done := s.proc, s.pumping
	s.sealing = true
	s.mu.Unlock()
	if proc != nil {
		proc.Close()
		<-done
	}
	if err := n.checkpoint(s, h, m.Run); err != nil {
		return 0, err
	}
	seq, _, err := n.appendEv(s, m.Run, "run.sealed", "", "", map[string]any{"node": n.cfg.Name, "to": to}, nil)
	if err != nil {
		return 0, err
	}
	return seq, s.j.WaitDurable(ctx, seq)
}

// Takeover starts a new run here. The session must be sealed to this node,
// or be this node's own interrupted run.
func (n *Node) Takeover(ctx context.Context, s *Session) error {
	m := s.Meta()
	ok := (m.State == "sealed" && m.SealedTo == n.cfg.Name) || (m.Node == n.cfg.Name && m.State == "interrupted")
	if !ok {
		return fmt.Errorf("session is %s on %s (sealed to %q)", m.State, m.Node, m.SealedTo)
	}
	h, err := n.cfg.Harnesses.Get(m.Harness)
	if err != nil {
		return err
	}
	if m.Node != n.cfg.Name {
		if err := n.materialize(m.Checkpoint, filepath.Join(s.dir, "native")); err != nil {
			return err
		}
	}
	return n.startRun(ctx, s, h, len(m.Checkpoint) > 0)
}

// Resume makes this node the session's writer: locally if it already is,
// otherwise by asking the owner to seal to us and pulling up to the seal.
func (n *Node) Resume(ctx context.Context, s *Session) error {
	m := s.Meta()
	if m.Node == n.cfg.Name {
		if m.State == "sealed" {
			if _, err := n.Seal(ctx, s, n.cfg.Name); err != nil {
				return err
			}
		}
		s.mu.Lock()
		running := s.proc != nil
		s.mu.Unlock()
		if running {
			return nil
		}
		return n.Takeover(ctx, s)
	}
	base, err := n.ownerURL(m.Node)
	if err != nil {
		return err
	}
	var res struct {
		Head uint64 `json:"head"`
	}
	if err := n.peerJSON(ctx, "POST", base+"/v1/sessions/"+s.ID+"/seal", map[string]string{"to": n.cfg.Name}, &res); err != nil {
		return err
	}
	if err := n.pullSession(ctx, base, s.ID); err != nil {
		return err
	}
	if s.j.Head() < res.Head {
		return fmt.Errorf("pulled to %d, owner sealed at %d", s.j.Head(), res.Head)
	}
	return n.Takeover(ctx, s)
}

// Fork starts a new session from the latest checkpoint this node holds of
// parent. It never writes to parent, so it is safe while parent's owner is
// unreachable.
func (n *Node) Fork(ctx context.Context, parent *Session, p authz.Principal, key string) (*Session, bool, error) {
	if key == "" {
		return nil, false, errors.New("key required")
	}
	pm := parent.Meta()
	h, err := n.cfg.Harnesses.Get(pm.Harness)
	if err != nil {
		return nil, false, err
	}
	sid := id("fork", parent.ID, p.Login, key)
	if s := n.get(sid); s != nil {
		return s, true, nil
	}
	s, err := n.open(sid)
	if err != nil {
		return nil, false, err
	}
	if err := n.materialize(pm.Checkpoint, filepath.Join(s.dir, "native")); err != nil {
		return nil, false, err
	}
	seq, _, err := n.appendEv(s, 0, "session.created", p.Login, "", map[string]any{
		"owner": p.Login, "owner_display": p.Display, "harness": pm.Harness, "title": "fork of " + pm.Title,
		"forked_from": parent.ID, "forked_at": pm.CheckpointAt}, nil)
	if err != nil {
		return nil, false, err
	}
	if err := s.j.WaitDurable(ctx, seq); err != nil {
		return nil, false, err
	}
	return s, false, n.startRun(ctx, s, h, len(pm.Checkpoint) > 0)
}

func (n *Node) Share(ctx context.Context, s *Session, p authz.Principal, user string, lvl authz.Level) error {
	m := s.Meta()
	if m.Node != n.cfg.Name {
		return ErrNotOwner
	}
	seq, _, err := n.appendEv(s, m.Run, "share", p.Login, "", map[string]any{"user": user, "level": lvl}, nil)
	if err != nil {
		return err
	}
	return s.j.WaitDurable(ctx, seq)
}

// Close stops every run (recorded as interrupted) and closes the journals.
func (n *Node) Close() error {
	first := false
	n.stopOnce.Do(func() { close(n.stop); first = true })
	if !first {
		return nil
	}
	n.wg.Wait()
	for _, s := range n.list() {
		s.mu.Lock()
		proc, done := s.proc, s.pumping
		s.mu.Unlock()
		if proc != nil {
			proc.Close()
			<-done
		}
		s.j.Close()
	}
	return nil
}

func readAll(r io.Reader) []byte { b, _ := io.ReadAll(io.LimitReader(r, 64<<20)); return b }

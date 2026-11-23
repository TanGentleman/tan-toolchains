// Package core is the fleet session model as pure functions: no I/O, no
// clock, no goroutines. A session is a sequence of events; Apply folds one
// event into State and Decide turns a command into the next event. Every
// node, replica and test uses these two functions, so the rules below hold
// wherever an event log is read or written.
//
// Rules:
//   - Seqs run 1..n with no gaps. One node writes each session.
//   - A keyed command (create, input, fork) with a key already in the log is
//     a no-op that returns the original event, so client retries are safe.
//   - A turn is one input, its output lines and one exit. Only one turn runs
//     at a time; an input while a turn runs is refused, never queued.
//   - Nothing is ever merged or moved; a fork is a new session.
//   - Repo, branch and sandbox are fixed at creation. Base is fixed once
//     set, at creation or by the first exit that reports it. Commits are
//     full lowercase hex ids (SHA-1 or SHA-256).
package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"
)

const (
	Created    = "created"    // CreatedData; always the first event
	Input      = "input"      // InputData; starts a turn: one harness process, prompt on stdin
	Out        = "out"        // one harness stdout line, stored as a JSON string
	OutB64     = "out.b64"    // a stdout line that is not valid UTF-8, base64
	Exited     = "exited"     // ExitedData; the turn's process ended
	Checkpoint = "checkpoint" // CheckpointData; harness state files after a turn, by hash
)

type Event struct {
	Seq  uint64          `json:"seq"`
	Sid  string          `json:"sid"`
	Node string          `json:"node"` // the node that wrote it; informational
	Run  int             `json:"run,omitempty"`
	T    string          `json:"t,omitempty"`
	By   string          `json:"by,omitempty"`
	Kind string          `json:"kind"`
	Key  string          `json:"key,omitempty"`
	Data json.RawMessage `json:"data,omitempty"`
}

type File struct {
	Name string `json:"name"`
	Sha  string `json:"sha"`
	Size int64  `json:"size"`
}

type CreatedData struct {
	Owner   string `json:"owner"`
	Harness string `json:"harness"`
	Model   string `json:"model,omitempty"` // passed to the harness every turn
	Title   string `json:"title,omitempty"`
	ForkOf  string `json:"fork_of,omitempty"`
	ForkAt  uint64 `json:"fork_at,omitempty"`
	Files   []File `json:"files,omitempty"`
	Repo    string `json:"repo,omitempty"`   // OWNER/REPO the harness clones each turn
	Branch  string `json:"branch,omitempty"` // branch chosen at spawn; turns push to fleet/<sid>
	Base    string `json:"base,omitempty"`   // commit to start from when fleet/<sid> doesn't exist
}

type InputData struct {
	Text string `json:"text"`
}

type ExitedData struct {
	Code   int    `json:"code"`
	Reason string `json:"reason,omitempty"`
	Commit string `json:"commit,omitempty"` // pushed to fleet/<sid> by this turn
	Base   string `json:"base,omitempty"`   // the commit turn 1 started from, when created had none
}

type CheckpointData struct {
	Files []File `json:"files"`
}

// State is everything a node needs to decide the next event.
type State struct {
	Sid     string `json:"sid"`
	Head    uint64 `json:"head"`
	Owner   string `json:"owner"`
	Harness string `json:"harness"`
	Model   string `json:"model,omitempty"`
	Title   string `json:"title,omitempty"`
	ForkOf  string `json:"fork_of,omitempty"`
	ForkAt  uint64 `json:"fork_at,omitempty"`
	Running bool   `json:"running"`         // a turn is in progress
	Run     int    `json:"run"`             // number of the latest turn
	Files   []File `json:"files,omitempty"` // harness state after the latest turn
	Updated string `json:"updated,omitempty"`
	Repo    string `json:"repo,omitempty"`
	Branch  string `json:"branch,omitempty"`
	Base    string `json:"base,omitempty"`
	Commit  string `json:"commit,omitempty"` // latest pushed commit

	keys map[string]uint64
}

var (
	ErrRunning    = errors.New("a turn is running")
	ErrNotRunning = errors.New("no turn is running")
	ErrBadEvent   = errors.New("event breaks the session rules")
)

func dedupeKey(kind, by, key string) string { return kind + "\x00" + by + "\x00" + key }

// Apply folds e into s. It checks the rules, so a log that breaks them fails
// to load instead of being misread.
func Apply(s *State, e Event) error {
	if e.Seq != s.Head+1 {
		return fmt.Errorf("%w: seq %d after %d", ErrBadEvent, e.Seq, s.Head)
	}
	if s.Head == 0 {
		if e.Kind != Created {
			return fmt.Errorf("%w: first event is %q", ErrBadEvent, e.Kind)
		}
	} else if e.Sid != s.Sid {
		return fmt.Errorf("%w: seq %d is for session %s", ErrBadEvent, e.Seq, e.Sid)
	}
	switch e.Kind {
	case Created:
		if s.Head != 0 {
			return fmt.Errorf("%w: second created", ErrBadEvent)
		}
		var d CreatedData
		if err := json.Unmarshal(e.Data, &d); err != nil {
			return err
		}
		if err := checkCode(d); err != nil {
			return err
		}
		s.Sid, s.Owner, s.Harness, s.Model, s.Title = e.Sid, d.Owner, d.Harness, d.Model, d.Title
		s.Repo, s.Branch, s.Base = d.Repo, d.Branch, d.Base
		s.ForkOf, s.ForkAt, s.Files = d.ForkOf, d.ForkAt, d.Files
	case Input:
		if s.Running || e.Run != s.Run+1 {
			return fmt.Errorf("%w: input %d while turn %d running=%v", ErrBadEvent, e.Run, s.Run, s.Running)
		}
		s.Running, s.Run = true, e.Run
	case Out, OutB64:
		if !s.Running || e.Run != s.Run {
			return fmt.Errorf("%w: %s outside run", ErrBadEvent, e.Kind)
		}
	case Exited:
		if !s.Running {
			return fmt.Errorf("%w: exited while stopped", ErrBadEvent)
		}
		var d ExitedData
		if len(e.Data) > 0 {
			if err := json.Unmarshal(e.Data, &d); err != nil {
				return err
			}
		}
		if (d.Commit != "" || d.Base != "") && s.Repo == "" {
			return fmt.Errorf("%w: commit on a session without a repo", ErrBadEvent)
		}
		if d.Commit != "" && !IsCommit(d.Commit) || d.Base != "" && !IsCommit(d.Base) {
			return fmt.Errorf("%w: bad commit %q base %q", ErrBadEvent, d.Commit, d.Base)
		}
		if d.Base != "" && s.Base != "" && d.Base != s.Base {
			return fmt.Errorf("%w: base changed from %s to %s", ErrBadEvent, s.Base, d.Base)
		}
		s.Running = false
		if d.Base != "" {
			s.Base = d.Base
		}
		if d.Commit != "" {
			s.Commit = d.Commit
		}
	case Checkpoint:
		var d CheckpointData
		if err := json.Unmarshal(e.Data, &d); err != nil {
			return err
		}
		s.Files = d.Files
	default:
		return fmt.Errorf("%w: unknown kind %q", ErrBadEvent, e.Kind)
	}
	if e.Key != "" {
		if s.keys == nil {
			s.keys = map[string]uint64{}
		}
		s.keys[dedupeKey(e.Kind, e.By, e.Key)] = e.Seq
	}
	s.Head = e.Seq
	s.Updated = e.T
	return nil
}

func checkCode(d CreatedData) error {
	switch {
	case d.Repo == "" && (d.Branch != "" || d.Base != ""):
		return fmt.Errorf("%w: branch or base without a repo", ErrBadEvent)
	case d.Repo != "" && !IsRepo(d.Repo):
		return fmt.Errorf("%w: repo %q is not OWNER/REPO", ErrBadEvent, d.Repo)
	case d.Branch != "" && !IsBranch(d.Branch):
		return fmt.Errorf("%w: bad branch %q", ErrBadEvent, d.Branch)
	case d.Base != "" && !IsCommit(d.Base):
		return fmt.Errorf("%w: base %q is not a full commit id", ErrBadEvent, d.Base)
	}
	return nil
}

// IsRepo reports whether s is a GitHub OWNER/REPO.
func IsRepo(s string) bool {
	owner, name, ok := strings.Cut(s, "/")
	if !ok || owner == "" || name == "" || len(owner) > 39 || len(name) > 100 || name == "." || name == ".." ||
		strings.HasPrefix(owner, "-") || strings.HasSuffix(name, ".git") {
		return false
	}
	for _, c := range owner {
		if !isAlnum(c) && c != '-' {
			return false
		}
	}
	for _, c := range name {
		if !isAlnum(c) && c != '-' && c != '_' && c != '.' {
			return false
		}
	}
	return true
}

// IsBranch accepts a conservative subset of git branch names: no option-like
// start, no "..", no lock or reflog syntax, nothing a shell or URL treats
// specially.
func IsBranch(s string) bool {
	if s == "" || len(s) > 200 || s[0] == '-' || s[0] == '/' || s[len(s)-1] == '/' || s[len(s)-1] == '.' ||
		strings.Contains(s, "..") || strings.Contains(s, "//") || strings.Contains(s, "@{") ||
		strings.HasSuffix(s, ".lock") || strings.Contains(s, "/.") || s[0] == '.' {
		return false
	}
	for _, c := range s {
		if !isAlnum(c) && !strings.ContainsRune("-_./", c) {
			return false
		}
	}
	return true
}

// IsCommit reports whether s is a full SHA-1 or SHA-256 commit id in
// lowercase hex.
func IsCommit(s string) bool {
	if len(s) != 40 && len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !('0' <= c && c <= '9' || 'a' <= c && c <= 'f') {
			return false
		}
	}
	return true
}

func isAlnum(c rune) bool {
	return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'
}

// Fold rebuilds State from a whole log.
func Fold(events []Event) (State, error) {
	var s State
	for _, e := range events {
		if err := Apply(&s, e); err != nil {
			return s, err
		}
	}
	return s, nil
}

// Cmd asks Node to append one event on behalf of By at time T.
type Cmd struct {
	Node string
	By   string
	T    string
	Kind string
	Key  string
	Data any
	Line []byte // for Out: the harness's exact stdout line
}

// Decide returns the event that Cmd appends to s. If Cmd's key is already
// in the log it returns that seq with dup=true and no event.
func Decide(s *State, c Cmd) (e Event, dup uint64, err error) {
	if c.Key != "" {
		if seq, ok := s.keys[dedupeKey(c.Kind, c.By, c.Key)]; ok {
			return Event{}, seq, nil
		}
	}
	e = Event{Seq: s.Head + 1, Sid: s.Sid, Node: c.Node, Run: s.Run, T: c.T, By: c.By, Kind: c.Kind, Key: c.Key}
	if c.Kind == Created {
		if s.Head != 0 {
			return Event{}, 0, fmt.Errorf("session %s exists", s.Sid)
		}
		e.Run = 0
	}
	switch c.Kind {
	case Input:
		if s.Running {
			return Event{}, 0, ErrRunning
		}
		e.Run = s.Run + 1
	case Out, Exited:
		if !s.Running {
			return Event{}, 0, ErrNotRunning
		}
	}
	switch {
	case c.Kind == Out && utf8.Valid(c.Line):
		e.Data, err = json.Marshal(string(c.Line))
	case c.Kind == Out:
		e.Kind = OutB64
		e.Data, err = json.Marshal(c.Line)
	case c.Data != nil:
		e.Data, err = json.Marshal(c.Data)
	}
	if err != nil {
		return Event{}, 0, err
	}
	// Check the event against the rules on a throwaway copy, so Decide never
	// returns an event that Apply would refuse.
	probe := *s
	probe.keys = nil
	if err := Apply(&probe, e); err != nil {
		return Event{}, 0, err
	}
	return e, 0, nil
}

// Package core is the fleet session model as pure functions: no I/O, no
// clock, no goroutines. A session is a sequence of events; Apply folds one
// event into State and Decide turns a command into the next event. Every
// node, replica and test uses these two functions, so the rules below hold
// wherever an event log is read or written.
//
// Rules:
//   - Seqs run 1..n with no gaps.
//   - Only State.Writer appends. It changes only by a "sealed" event that the
//     current writer appends, so two nodes can never append the same seq.
//   - A keyed command (create, input, fork) with a key already in the log is
//     a no-op that returns the original event, so client retries are safe.
//   - A turn is one input, its output lines and one exit. Only one turn runs
//     at a time; an input while a turn runs is refused, never queued.
//   - Nothing is ever merged. A session whose writer is gone is forked.
package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"unicode/utf8"
)

const (
	Created    = "created"    // CreatedData; the creating node is the first writer
	Input      = "input"      // InputData; starts a turn: one harness process, prompt on stdin
	Out        = "out"        // one harness stdout line, stored as a JSON string
	OutB64     = "out.b64"    // a stdout line that is not valid UTF-8, base64
	Exited     = "exited"     // ExitedData; the turn's process ended
	Checkpoint = "checkpoint" // CheckpointData; harness state files after a turn, by hash
	Sealed     = "sealed"     // SealedData; the writer hands the session to To
	Shared     = "shared"     // SharedData
)

type Event struct {
	Seq  uint64          `json:"seq"`
	Sid  string          `json:"sid"`
	Node string          `json:"node"`
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
	Model   string `json:"model,omitempty"` // passed to the harness on every node
	Title   string `json:"title,omitempty"`
	URL     string `json:"url,omitempty"` // where the writer can be reached
	ForkOf  string `json:"fork_of,omitempty"`
	ForkAt  uint64 `json:"fork_at,omitempty"`
	Files   []File `json:"files,omitempty"`
}

type InputData struct {
	Text string `json:"text"`
}

type ExitedData struct {
	Code   int    `json:"code"`
	Reason string `json:"reason,omitempty"`
}

type CheckpointData struct {
	Files []File `json:"files"`
}

type SealedData struct {
	To  string `json:"to"`
	URL string `json:"url"` // where To can be reached
}

type SharedData struct {
	User  string `json:"user"`
	Level Level  `json:"level"`
}

// State is everything a node needs to decide the next event.
type State struct {
	Sid       string           `json:"sid"`
	Head      uint64           `json:"head"`
	Owner     string           `json:"owner"`
	Harness   string           `json:"harness"`
	Model     string           `json:"model,omitempty"`
	Title     string           `json:"title,omitempty"`
	ForkOf    string           `json:"fork_of,omitempty"`
	ForkAt    uint64           `json:"fork_at,omitempty"`
	Writer    string           `json:"writer"`
	WriterURL string           `json:"writer_url,omitempty"`
	Running   bool             `json:"running"`         // a turn is in progress
	Run       int              `json:"run"`             // number of the latest turn
	Files     []File           `json:"files,omitempty"` // harness state after the latest turn
	Shares    map[string]Level `json:"shares,omitempty"`
	Updated   string           `json:"updated,omitempty"`

	keys map[string]uint64
}

var (
	ErrNotWriter  = errors.New("this node is not the session's writer")
	ErrRunning    = errors.New("a turn is running")
	ErrNotRunning = errors.New("no turn is running")
	ErrBadEvent   = errors.New("event breaks the session rules")
)

func dedupeKey(kind, by, key string) string { return kind + "\x00" + by + "\x00" + key }

// Apply folds e into s. It checks the rules, so a replica that copies an
// event the writer could not have written stops instead of diverging.
func Apply(s *State, e Event) error {
	if e.Seq != s.Head+1 {
		return fmt.Errorf("%w: seq %d after %d", ErrBadEvent, e.Seq, s.Head)
	}
	if s.Head == 0 {
		if e.Kind != Created {
			return fmt.Errorf("%w: first event is %q", ErrBadEvent, e.Kind)
		}
	} else if e.Sid != s.Sid || e.Node != s.Writer {
		return fmt.Errorf("%w: seq %d from %s, writer is %s", ErrBadEvent, e.Seq, e.Node, s.Writer)
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
		s.Sid, s.Owner, s.Harness, s.Model, s.Title = e.Sid, d.Owner, d.Harness, d.Model, d.Title
		s.ForkOf, s.ForkAt, s.Files = d.ForkOf, d.ForkAt, d.Files
		s.Writer, s.WriterURL = e.Node, d.URL
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
		s.Running = false
	case Checkpoint:
		var d CheckpointData
		if err := json.Unmarshal(e.Data, &d); err != nil {
			return err
		}
		s.Files = d.Files
	case Sealed:
		if s.Running {
			return fmt.Errorf("%w: sealed while running", ErrBadEvent)
		}
		var d SealedData
		if err := json.Unmarshal(e.Data, &d); err != nil {
			return err
		}
		s.Writer, s.WriterURL = d.To, d.URL
	case Shared:
		var d SharedData
		if err := json.Unmarshal(e.Data, &d); err != nil {
			return err
		}
		if s.Shares == nil {
			s.Shares = map[string]Level{}
		}
		if d.Level == None {
			delete(s.Shares, d.User)
		} else {
			s.Shares[d.User] = d.Level
		}
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
	} else if s.Writer != c.Node {
		return Event{}, 0, fmt.Errorf("%w (writer is %s)", ErrNotWriter, s.Writer)
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
	case Sealed:
		if s.Running {
			return Event{}, 0, ErrRunning
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
	probe.keys, probe.Shares = nil, nil
	if err := Apply(&probe, e); err != nil {
		return Event{}, 0, err
	}
	return e, 0, nil
}

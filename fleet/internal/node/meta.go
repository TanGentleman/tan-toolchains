package node

import (
	"encoding/json"

	"github.com/TanGentleman/tan-toolchains/fleet/internal/authz"
	"github.com/TanGentleman/tan-toolchains/fleet/internal/journal"
)

// File is one checkpointed native file, stored by content hash.
type File struct {
	Name string `json:"name"`
	Sha  string `json:"sha256"`
	Size int64  `json:"size"`
}

// Meta is everything known about a session, folded from its log alone.
type Meta struct {
	Sid          string                 `json:"sid"`
	Owner        string                 `json:"owner"`
	OwnerDisplay string                 `json:"owner_display"`
	Harness      string                 `json:"harness"`
	Title        string                 `json:"title"`
	ForkedFrom   string                 `json:"forked_from,omitempty"`
	ForkedAt     uint64                 `json:"forked_at,omitempty"`
	Node         string                 `json:"node"` // writer of the current run
	Run          int                    `json:"run"`
	State        string                 `json:"state"` // running | busy | interrupted | sealed
	SealedTo     string                 `json:"sealed_to,omitempty"`
	Head         uint64                 `json:"head"`
	Updated      string                 `json:"updated"`
	Last         string                 `json:"last,omitempty"`
	Checkpoint   []File                 `json:"checkpoint,omitempty"`
	CheckpointAt uint64                 `json:"checkpoint_at,omitempty"`
	Shares       map[string]authz.Level `json:"shares,omitempty"`
	Unknown      []string               `json:"unknown,omitempty"` // outcome-unknown inputs/tool calls of the last interrupted run
	MaxRaw       map[int]int64          `json:"-"`
}

func fold(sid string, evs []journal.Event) Meta {
	m := Meta{Sid: sid, MaxRaw: map[int]int64{}}
	var open []string // inputs/tool calls whose outcome is not yet recorded
	for _, e := range evs {
		m.Head, m.Updated = e.Seq, e.T
		if e.Raw != nil {
			if end := e.Raw.Off + int64(e.Raw.Len); end > m.MaxRaw[e.Raw.Run] {
				m.MaxRaw[e.Raw.Run] = end
			}
		}
		var d map[string]any
		json.Unmarshal(e.Data, &d)
		str := func(k string) string { s, _ := d[k].(string); return s }
		switch e.Kind {
		case "session.created":
			m.Owner, m.OwnerDisplay, m.Harness, m.Title = str("owner"), str("owner_display"), str("harness"), str("title")
			m.ForkedFrom = str("forked_from")
			if f, ok := d["forked_at"].(float64); ok {
				m.ForkedAt = uint64(f)
			}
			m.Node = e.Node
		case "run.started":
			m.Node, m.Run, m.State, open, m.Unknown, m.SealedTo = e.Node, e.Run, "running", nil, nil, ""
		case "input":
			if k := str("kind"); k == "prompt" || k == "steer" {
				open = append(open, "input "+e.Key)
				m.Last = str("text")
				if k == "prompt" {
					m.State = "busy" // queued or running until turn.end
				}
			}
		case "turn.start":
			m.State = "busy"
		case "turn.end":
			m.State, open = "running", nil
		case "tool.call":
			open = append(open, "tool "+str("id"))
		case "tool.result":
			open = remove(open, "tool "+str("id"))
		case "message":
			m.Last = str("text")
		case "checkpoint":
			var c struct {
				Files []File `json:"files"`
			}
			json.Unmarshal(e.Data, &c)
			m.Checkpoint, m.CheckpointAt = c.Files, e.Seq
		case "run.interrupted":
			m.State, m.Unknown = "interrupted", open
		case "run.sealed":
			m.State, m.SealedTo = "sealed", str("to")
		case "share":
			if m.Shares == nil {
				m.Shares = map[string]authz.Level{}
			}
			if lvl := authz.Level(str("level")); lvl == "" {
				delete(m.Shares, str("user"))
			} else {
				m.Shares[str("user")] = lvl
			}
		}
	}
	return m
}

func remove(xs []string, x string) []string {
	out := xs[:0]
	for _, v := range xs {
		if v != x {
			out = append(out, v)
		}
	}
	return out
}

func (m Meta) authz() *authz.Session {
	return &authz.Session{ID: m.Sid, Owner: m.Owner, Shares: m.Shares}
}

// Writer is the node that may append next: the current run's node, or the
// node it was sealed to.
func (m Meta) Writer() string {
	if m.State == "sealed" && m.SealedTo != "" {
		return m.SealedTo
	}
	return m.Node
}

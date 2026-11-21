// Package authz decides owner/friend/viewer actions for fleetd.
//
// Split model: the tailnet policy file grants each principal a ceiling
// (role, spawn, slots, runners, archive) as an app capability; the app
// database holds per-session ownership and shares. A request is allowed
// only if both say yes. Default deny everywhere.
package authz

import (
	"errors"
	"fmt"
	"slices"
)

// CapName is the grant app-capability key fleetd reads.
const CapName = "github.com/TanGentleman/cap/fleet"

type Role string

const (
	RoleNone   Role = ""
	RoleViewer Role = "viewer"
	RoleFriend Role = "friend"
	RoleOwner  Role = "owner"
)

func (r Role) rank() int {
	switch r {
	case RoleViewer:
		return 1
	case RoleFriend:
		return 2
	case RoleOwner:
		return 3
	}
	return 0
}

// Cap is one value of the fleet app capability, as written in the ACL grant.
type Cap struct {
	Role    Role     `json:"role"`
	Read    string   `json:"read,omitempty"` // "own" | "shared" | "all"
	Spawn   bool     `json:"spawn,omitempty"`
	Slots   int      `json:"slots,omitempty"`
	Runners []string `json:"runners,omitempty"`
	Archive bool     `json:"archive,omitempty"` // may pull segments (archive node)
}

// Principal is the caller as seen by fleetd. Login is the stable key used in
// session ownership and shares: "<control>/<user id>" for users and
// "node:<tags>" for tagged nodes. Display is for humans only.
type Principal struct {
	Login   string
	Display string
	Node    string
	Tagged  bool
	Tags    []string
	Funnel  bool
	Cap     Cap // merged ceiling; zero value means no access
}

var ErrNoIdentity = errors.New("authz: no tailnet identity")

// Merge unions multiple grant values: highest role, widest read, OR of
// booleans, max slots, union of runners.
func Merge(caps []Cap) Cap {
	var m Cap
	readRank := map[string]int{"": 0, "own": 1, "shared": 2, "all": 3}
	for _, c := range caps {
		if c.Role.rank() > m.Role.rank() {
			m.Role = c.Role
		}
		if readRank[c.Read] > readRank[m.Read] {
			m.Read = c.Read
		}
		m.Spawn = m.Spawn || c.Spawn
		m.Archive = m.Archive || c.Archive
		m.Slots = max(m.Slots, c.Slots)
		for _, r := range c.Runners {
			if !slices.Contains(m.Runners, r) {
				m.Runners = append(m.Runners, r)
			}
		}
	}
	return m
}

// Share levels stored per session in the app database.
type Level string

const (
	LevelView  Level = "view"  // read events
	LevelSteer Level = "steer" // read + prompt/steer/cancel
	LevelAdmin Level = "admin" // + approve, seal/resume/fork, reshare
)

func (l Level) rank() int {
	switch l {
	case LevelView:
		return 1
	case LevelSteer:
		return 2
	case LevelAdmin:
		return 3
	}
	return 0
}

// Session is the app-database view of one session's access list.
type Session struct {
	ID     string
	Owner  string           // login of the creator
	Shares map[string]Level // login -> level
}

type Action string

const (
	ActList    Action = "list"
	ActRead    Action = "read"
	ActSpawn   Action = "spawn"
	ActPrompt  Action = "prompt" // prompt, steer, cancel
	ActApprove Action = "approve"
	ActHandoff Action = "handoff" // seal, resume, fork
	ActShare   Action = "share"
	ActArchive Action = "archive" // pull segments
)

// Request carries optional per-action context.
type Request struct {
	Action  Action
	Session *Session // nil for list/spawn
	Runner  string   // for spawn
	Running int      // caller's live sessions on this node, for spawn
}

type Decision struct {
	Allow  bool
	Reason string
}

func deny(f string, a ...any) Decision  { return Decision{false, fmt.Sprintf(f, a...)} }
func allow(f string, a ...any) Decision { return Decision{true, fmt.Sprintf(f, a...)} }

// needLevel is the minimum session share level each per-session action needs.
var needLevel = map[Action]Level{
	ActRead:    LevelView,
	ActPrompt:  LevelSteer,
	ActApprove: LevelAdmin,
	ActHandoff: LevelAdmin,
	ActShare:   LevelAdmin,
}

// roleCeiling is the highest session level a tailnet role may ever exercise,
// whatever the session's share list says.
var roleCeiling = map[Role]Level{
	RoleViewer: LevelView,
	RoleFriend: LevelAdmin, // on sessions they own or that are shared to them
	RoleOwner:  LevelAdmin,
}

// Decide applies tailnet ceiling AND session share. Default deny.
func Decide(p Principal, r Request) Decision {
	if p.Funnel {
		return deny("funnel requests carry no tailnet identity")
	}
	c := p.Cap
	if r.Action == ActArchive {
		if c.Archive {
			return allow("archive capability")
		}
		return deny("no archive capability")
	}
	if c.Role == RoleNone {
		return deny("no %s grant", CapName)
	}
	switch r.Action {
	case ActList:
		return allow("role %s may list (filtered by read=%q)", c.Role, c.Read)
	case ActSpawn:
		if !c.Spawn {
			return deny("role %s has no spawn", c.Role)
		}
		if len(c.Runners) > 0 && !slices.Contains(c.Runners, r.Runner) {
			return deny("runner %q not in %v", r.Runner, c.Runners)
		}
		if c.Slots > 0 && r.Running >= c.Slots {
			return deny("slots exhausted (%d/%d)", r.Running, c.Slots)
		}
		return allow("spawn ok")
	}
	need, ok := needLevel[r.Action]
	if !ok {
		return deny("unknown action %q", r.Action)
	}
	if r.Session == nil {
		return deny("action %s needs a session", r.Action)
	}
	have := sessionLevel(p, c, r.Session)
	ceil := roleCeiling[c.Role]
	if ceil.rank() < have.rank() {
		have = ceil
	}
	if have.rank() >= need.rank() {
		return allow("level %s >= %s", have, need)
	}
	return deny("level %q < %s", have, need)
}

func sessionLevel(p Principal, c Cap, s *Session) Level {
	if s.Owner != "" && s.Owner == p.Login {
		return LevelAdmin
	}
	l := s.Shares[p.Login]
	switch c.Read {
	case "all":
		if c.Role == RoleOwner {
			return LevelAdmin
		}
		if l.rank() < LevelView.rank() {
			l = LevelView
		}
	case "own":
		if l == "" {
			return ""
		}
	}
	return l
}

// CanSee is the list filter matching Decide(ActRead).
func CanSee(p Principal, s *Session) bool {
	return Decide(p, Request{Action: ActRead, Session: s}).Allow
}

package core

import (
	"fmt"
	"slices"
)

type Level int

const (
	None Level = iota
	View
	Steer
	Admin
)

func (l Level) String() string {
	return [...]string{"none", "view", "steer", "admin"}[l]
}

func (l Level) MarshalText() ([]byte, error) { return []byte(l.String()), nil }

func (l *Level) UnmarshalText(b []byte) error {
	for i, n := range [...]string{"none", "view", "steer", "admin"} {
		if string(b) == n {
			*l = Level(i)
			return nil
		}
	}
	return fmt.Errorf("level %q: want none, view, steer or admin", b)
}

// Policy is one node's access rules. Owners can do anything on this node;
// Spawners may create sessions. Everyone else only gets what a session's
// owner shares with them, and shares travel with the session's log.
type Policy struct {
	Owners   []string
	Spawners []string
}

func (p Policy) CanSpawn(login string) bool {
	return login != "" && (slices.Contains(p.Owners, login) || slices.Contains(p.Spawners, login))
}

// Level is what login may do with session s on this node.
func (p Policy) Level(login string, s *State) Level {
	switch {
	case login == "":
		return None
	case slices.Contains(p.Owners, login), login == s.Owner:
		return Admin
	}
	return s.Shares[login]
}

package authz

import "testing"

var (
	ownerCap  = Cap{Role: RoleOwner, Read: "all", Spawn: true}
	friendCap = Cap{Role: RoleFriend, Read: "own", Spawn: true, Slots: 2, Runners: []string{"fake", "pi"}}
	viewerCap = Cap{Role: RoleViewer, Read: "shared"}
)

func TestDecide(t *testing.T) {
	tan := Principal{Login: "ts:1", Cap: ownerCap}
	bob := Principal{Login: "ts:2", Cap: friendCap}
	carol := Principal{Login: "ts:3", Cap: viewerCap}
	mallory := Principal{Login: "ts:4"}
	carolBoth := Principal{Login: "ts:3", Cap: Merge([]Cap{viewerCap, friendCap})}
	archive := Principal{Login: "node:tag:fleet-archive", Tagged: true, Cap: Cap{Archive: true}}

	tanS := &Session{ID: "s-tan", Owner: "ts:1"}
	bobS := &Session{ID: "s-bob", Owner: "ts:2"}
	shared := &Session{ID: "s-shared", Owner: "ts:1", Shares: map[string]Level{"ts:2": LevelSteer, "ts:3": LevelAdmin}}

	cases := []struct {
		name string
		p    Principal
		r    Request
		want bool
	}{
		{"owner reads any", tan, Request{Action: ActRead, Session: bobS}, true},
		{"owner approves friend session", tan, Request{Action: ActApprove, Session: bobS}, true},
		{"friend reads own", bob, Request{Action: ActRead, Session: bobS}, true},
		{"friend hands off own", bob, Request{Action: ActHandoff, Session: bobS}, true},
		{"friend cannot read owner's", bob, Request{Action: ActRead, Session: tanS}, false},
		{"friend steers shared", bob, Request{Action: ActPrompt, Session: shared}, true},
		{"friend cannot approve steer share", bob, Request{Action: ActApprove, Session: shared}, false},
		{"friend spawn allowed runner", bob, Request{Action: ActSpawn, Runner: "pi", Running: 1}, true},
		{"friend spawn other runner", bob, Request{Action: ActSpawn, Runner: "host"}, false},
		{"friend slots exhausted", bob, Request{Action: ActSpawn, Runner: "pi", Running: 2}, false},
		{"viewer reads shared", carol, Request{Action: ActRead, Session: shared}, true},
		{"viewer ceiling beats admin share", carol, Request{Action: ActApprove, Session: shared}, false},
		{"viewer cannot prompt", carol, Request{Action: ActPrompt, Session: shared}, false},
		{"viewer cannot read unshared", carol, Request{Action: ActRead, Session: tanS}, false},
		{"viewer cannot spawn", carol, Request{Action: ActSpawn, Runner: "fake"}, false},
		{"merged caps lift ceiling", carolBoth, Request{Action: ActApprove, Session: shared}, true},
		{"no grant cannot list", mallory, Request{Action: ActList}, false},
		{"no grant cannot read", mallory, Request{Action: ActRead, Session: shared}, false},
		{"archive pulls", archive, Request{Action: ActArchive}, true},
		{"archive cannot read sessions", archive, Request{Action: ActRead, Session: tanS}, false},
		{"owner cannot pull without cap", tan, Request{Action: ActArchive}, false},
		{"funnel denied", Principal{Funnel: true, Cap: ownerCap}, Request{Action: ActList}, false},
	}
	for _, c := range cases {
		if got := Decide(c.p, c.r); got.Allow != c.want {
			t.Errorf("%s: got %v (%s), want %v", c.name, got.Allow, got.Reason, c.want)
		}
	}
}

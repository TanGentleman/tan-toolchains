package core

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"strings"
	"testing"
)

type replica struct {
	lines [][]byte
	st    State
}

func (r *replica) append(t testing.TB, e Event) {
	t.Helper()
	b, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	if err := Apply(&r.st, e); err != nil {
		t.Fatalf("Apply refused a decided event: %v", err)
	}
	r.lines = append(r.lines, b)
}

func do(t testing.TB, r *replica, c Cmd) (uint64, error) {
	t.Helper()
	e, dup, err := Decide(&r.st, c)
	if err != nil || dup != 0 {
		return dup, err
	}
	r.append(t, e)
	return e.Seq, nil
}

func TestRules(t *testing.T) {
	a := &replica{st: State{Sid: "s1"}}
	must := func(seq uint64, err error) uint64 {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return seq
	}
	must(do(t, a, Cmd{Node: "a", By: "tan", Kind: Created, Key: "k", Data: CreatedData{Owner: "tan", Harness: "fake"}}))
	if _, err := do(t, a, Cmd{Node: "a", Kind: Out, Line: []byte("x")}); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("output outside a turn: %v", err)
	}
	if _, err := do(t, a, Cmd{Node: "b", Kind: Input, Data: InputData{}}); !errors.Is(err, ErrNotWriter) {
		t.Fatalf("input from non-writer: %v", err)
	}
	first := must(do(t, a, Cmd{Node: "a", By: "tan", Kind: Input, Key: "i1", Data: InputData{Text: "hi"}}))
	if again := must(do(t, a, Cmd{Node: "a", By: "tan", Kind: Input, Key: "i1", Data: InputData{Text: "hi"}})); again != first || a.st.Head != first {
		t.Fatalf("retried key appended: first %d again %d head %d", first, again, a.st.Head)
	}
	if _, err := do(t, a, Cmd{Node: "a", By: "tan", Kind: Input, Key: "i2", Data: InputData{}}); !errors.Is(err, ErrRunning) {
		t.Fatalf("second input during a turn: %v", err)
	}
	must(do(t, a, Cmd{Node: "a", Kind: Out, Line: []byte{0xff, 'x'}}))
	if k := json.RawMessage(a.lines[len(a.lines)-1]); !bytes.Contains(k, []byte(`"kind":"out.b64"`)) {
		t.Fatalf("invalid UTF-8 must be kept as base64: %s", k)
	}
	if _, err := do(t, a, Cmd{Node: "a", Kind: Sealed, Data: SealedData{To: "b"}}); !errors.Is(err, ErrRunning) {
		t.Fatalf("seal during a turn: %v", err)
	}
	must(do(t, a, Cmd{Node: "a", Kind: Exited, Data: ExitedData{}}))
	if seq := must(do(t, a, Cmd{Node: "a", By: "bob", Kind: Input, Key: "i1", Data: InputData{}})); seq == first {
		t.Fatal("keys must be scoped per caller")
	}
	if a.st.Run != 2 {
		t.Fatalf("run = %d, want 2", a.st.Run)
	}
	must(do(t, a, Cmd{Node: "a", Kind: Exited, Data: ExitedData{}}))
	must(do(t, a, Cmd{Node: "a", Kind: Sealed, Data: SealedData{To: "b", URL: "http://b"}}))
	if a.st.WriterURL != "http://b" {
		t.Fatalf("writer url = %q", a.st.WriterURL)
	}
	if _, err := do(t, a, Cmd{Node: "a", Kind: Input, Data: InputData{}}); !errors.Is(err, ErrNotWriter) {
		t.Fatalf("old writer kept writing after seal: %v", err)
	}
	must(do(t, a, Cmd{Node: "b", Kind: Input, Data: InputData{}}))

	// A forged line from a node that is not the writer is refused on copy.
	forged := Event{Seq: a.st.Head + 1, Sid: "s1", Node: "a", Run: a.st.Run, Kind: Out, Data: json.RawMessage(`"x"`)}
	if err := Apply(&a.st, forged); !errors.Is(err, ErrBadEvent) {
		t.Fatalf("forged event applied: %v", err)
	}
}

func TestPolicy(t *testing.T) {
	p := Policy{Owners: []string{"tan"}, Spawners: []string{"amy"}}
	s := &State{Owner: "amy", Shares: map[string]Level{"bob": View}}
	for _, c := range []struct {
		who  string
		want Level
	}{{"tan", Admin}, {"amy", Admin}, {"bob", View}, {"eve", None}, {"", None}} {
		if got := p.Level(c.who, s); got != c.want {
			t.Errorf("Level(%q) = %v, want %v", c.who, got, c.want)
		}
	}
	if !p.CanSpawn("amy") || p.CanSpawn("bob") || p.CanSpawn("") {
		t.Error("CanSpawn")
	}
	// An unknown level is an error, not a silent revoke.
	var l Level
	if err := l.UnmarshalText([]byte("Admin")); err == nil {
		t.Error("accepted level Admin")
	}
	if err := l.UnmarshalText([]byte("steer")); err != nil || l != Steer {
		t.Errorf("steer: %v %v", l, err)
	}
}

// TestSimulation runs random commands on three nodes that copy each other's
// logs at random, and checks after every step that copies of a session
// never disagree: the only property that makes view-anywhere safe.
func TestSimulation(t *testing.T) {
	nodes := []string{"a", "b", "c"}
	var moved int
	for seed := uint64(1); seed <= 200; seed++ {
		h1, n := simulate(t, seed, nodes, 600)
		h2, _ := simulate(t, seed, nodes, 600)
		if h1 != h2 {
			t.Fatalf("seed %d: same seed gave different logs", seed)
		}
		moved += n
	}
	// Safety alone is easy (never hand off); require handoffs to work.
	if moved < 200 {
		t.Fatalf("sessions rarely continued on another node (%d events)", moved)
	}
	t.Logf("%d events written after a handoff", moved)
}

func simulate(t *testing.T, seed uint64, nodes []string, steps int) (string, int) {
	rng := rand.New(rand.NewPCG(seed, 0))
	reps := map[string]map[string]*replica{} // node -> sid -> copy
	for _, n := range nodes {
		reps[n] = map[string]*replica{}
	}
	var sids []string
	creator := map[string]string{}
	moved := 0 // events appended by a node other than the session's creator
	pick := func(xs []string) string { return xs[rng.IntN(len(xs))] }
	for step := 0; step < steps; step++ {
		node := pick(nodes)
		switch op := rng.IntN(10); {
		case op == 0 || len(sids) == 0:
			sid := fmt.Sprintf("s%d", len(sids))
			r := &replica{st: State{Sid: sid}}
			if _, err := do(t, r, Cmd{Node: node, By: "tan", Kind: Created, Data: CreatedData{Owner: "tan", Harness: "fake"}}); err != nil {
				t.Fatal(err)
			}
			reps[node][sid] = r
			sids = append(sids, sid)
			creator[sid] = node
		case op <= 3: // copy a session from one node to another
			sid, src, dst := pick(sids), reps[pick(nodes)], reps[node]
			s := src[sid]
			if s == nil {
				continue
			}
			d := dst[sid]
			if d == nil {
				d = &replica{}
				dst[sid] = d
			}
			for _, line := range s.lines[min(len(d.lines), len(s.lines)):] {
				var e Event
				json.Unmarshal(line, &e)
				if err := Apply(&d.st, e); err != nil {
					t.Fatalf("seed %d step %d: copy refused: %v", seed, step, err)
				}
				d.lines = append(d.lines, line)
			}
		default: // any command on any node; Decide must refuse the illegal ones
			sid := pick(sids)
			r := reps[node][sid]
			if r == nil {
				continue
			}
			var c Cmd
			switch rng.IntN(6) {
			case 0:
				c = Cmd{Kind: Checkpoint, Data: CheckpointData{Files: []File{{Name: "f", Sha: fmt.Sprint(rng.IntN(3))}}}}
			case 1:
				c = Cmd{Kind: Input, Key: fmt.Sprint(rng.IntN(8)), Data: InputData{Text: "x"}}
			case 2:
				c = Cmd{Kind: Out, Line: []byte("x")}
			case 3:
				c = Cmd{Kind: Exited, Data: ExitedData{}}
			case 4:
				c = Cmd{Kind: Sealed, Data: SealedData{To: pick(nodes), URL: "http://x"}}
			case 5:
				c = Cmd{Kind: Shared, Data: SharedData{User: "bob", Level: View}}
			}
			c.Node, c.By = node, "tan"
			if _, err := do(t, r, c); err == nil && node != creator[sid] {
				moved++
			}
		}
		checkAgree(t, seed, step, reps)
	}
	h := sha256.New()
	for _, n := range nodes {
		for _, sid := range sids {
			if r := reps[n][sid]; r != nil {
				for _, l := range r.lines {
					h.Write(l)
				}
				// The live state always equals a fold of the log.
				var evs []Event
				for _, l := range r.lines {
					var e Event
					json.Unmarshal(l, &e)
					evs = append(evs, e)
				}
				if st, err := Fold(evs); err != nil || st.Head != r.st.Head || st.Writer != r.st.Writer || st.Running != r.st.Running {
					t.Fatalf("seed %d: fold differs from live state: %v", seed, err)
				}
			}
		}
	}
	return fmt.Sprintf("%x", h.Sum(nil)), moved
}

func checkAgree(t *testing.T, seed uint64, step int, reps map[string]map[string]*replica) {
	t.Helper()
	longest := map[string][][]byte{}
	for _, bySid := range reps {
		for sid, r := range bySid {
			l := longest[sid]
			for i := 0; i < min(len(l), len(r.lines)); i++ {
				if !bytes.Equal(l[i], r.lines[i]) {
					t.Fatalf("seed %d step %d: %s diverged at seq %d", seed, step, sid, i+1)
				}
			}
			if len(r.lines) > len(l) {
				longest[sid] = r.lines
			}
		}
	}
}

func TestRepoRules(t *testing.T) {
	sha1, sha256 := strings.Repeat("a", 40), strings.Repeat("b", 64)
	create := func(d CreatedData) (*replica, error) {
		r := &replica{st: State{Sid: "s1"}}
		d.Owner, d.Harness = "tan", "pi-ctr"
		_, err := do(t, r, Cmd{Node: "a", By: "tan", Kind: Created, Data: d})
		return r, err
	}
	for _, d := range []CreatedData{
		{Repo: "nope"}, {Repo: "o/r.git"}, {Repo: "-o/r"}, {Repo: "o/r/x"}, {Repo: "o/r;rm"},
		{Branch: "main"}, {Base: sha1},
		{Repo: "o/r", Branch: "-x"}, {Repo: "o/r", Branch: "a..b"}, {Repo: "o/r", Branch: "a b"},
		{Repo: "o/r", Branch: "x.lock"}, {Repo: "o/r", Branch: "a/.b"}, {Repo: "o/r", Branch: "a@{1}"},
		{Repo: "o/r", Base: "abc"}, {Repo: "o/r", Base: strings.ToUpper(sha1)},
	} {
		if _, err := create(d); !errors.Is(err, ErrBadEvent) {
			t.Errorf("created %+v: %v", d, err)
		}
	}
	turn := func(r *replica, x ExitedData) error {
		t.Helper()
		if _, err := do(t, r, Cmd{Node: "a", By: "tan", Kind: Input, Data: InputData{Text: "go"}}); err != nil {
			t.Fatal(err)
		}
		_, err := do(t, r, Cmd{Node: "a", Kind: Exited, Data: x})
		if err != nil {
			do(t, r, Cmd{Node: "a", Kind: Exited, Data: ExitedData{}})
		}
		return err
	}

	plain, err := create(CreatedData{})
	if err != nil {
		t.Fatal(err)
	}
	if err := turn(plain, ExitedData{Commit: sha1}); !errors.Is(err, ErrBadEvent) {
		t.Fatalf("commit without a repo: %v", err)
	}

	r, err := create(CreatedData{Repo: "Tan-1/tan_tool.chains", Branch: "feat/x-1", Sandbox: "pi-container"})
	if err != nil {
		t.Fatal(err)
	}
	if err := turn(r, ExitedData{Commit: "xyz"}); !errors.Is(err, ErrBadEvent) {
		t.Fatalf("bad commit: %v", err)
	}
	if err := turn(r, ExitedData{Commit: sha256, Base: sha1}); err != nil {
		t.Fatal(err)
	}
	if err := turn(r, ExitedData{Base: sha256}); !errors.Is(err, ErrBadEvent) {
		t.Fatalf("base changed: %v", err)
	}
	if err := turn(r, ExitedData{Base: sha1}); err != nil {
		t.Fatalf("same base again: %v", err)
	}
	if err := turn(r, ExitedData{Code: 1}); err != nil {
		t.Fatal(err)
	}
	s, err := Fold(decode(t, r.lines))
	if err != nil {
		t.Fatal(err)
	}
	if s.Repo != "Tan-1/tan_tool.chains" || s.Branch != "feat/x-1" || s.Sandbox != "pi-container" || s.Base != sha1 || s.Commit != sha256 {
		t.Fatalf("folded state %+v", s)
	}
}

func decode(t *testing.T, lines [][]byte) []Event {
	t.Helper()
	var es []Event
	for _, b := range lines {
		var e Event
		if err := json.Unmarshal(b, &e); err != nil {
			t.Fatal(err)
		}
		es = append(es, e)
	}
	return es
}

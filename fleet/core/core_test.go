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
	must(do(t, a, Cmd{Node: "a", Kind: Exited, Data: ExitedData{}}))
	if seq := must(do(t, a, Cmd{Node: "a", By: "bob", Kind: Input, Key: "i1", Data: InputData{}})); seq == first {
		t.Fatal("keys must be scoped per caller")
	}
	if a.st.Run != 2 {
		t.Fatalf("run = %d, want 2", a.st.Run)
	}
	must(do(t, a, Cmd{Node: "a", Kind: Exited, Data: ExitedData{}}))

	// Lines that break the rules are refused on load: a gap, another
	// session's event, output outside a turn, an event kind fleet removed.
	for _, bad := range []Event{
		{Seq: a.st.Head + 2, Sid: "s1", Kind: Input},
		{Seq: a.st.Head + 1, Sid: "s2", Kind: Input, Run: a.st.Run + 1},
		{Seq: a.st.Head + 1, Sid: "s1", Kind: Out, Run: a.st.Run, Data: json.RawMessage(`"x"`)},
		{Seq: a.st.Head + 1, Sid: "s1", Kind: "sealed", Data: json.RawMessage(`{"to":"b"}`)},
	} {
		probe := a.st
		if err := Apply(&probe, bad); !errors.Is(err, ErrBadEvent) {
			t.Errorf("applied %+v: %v", bad, err)
		}
	}
}

// TestRandomCommands runs random commands, legal or not, against one
// session for many seeds. Decide must refuse the illegal ones and never
// return an event Apply rejects (do fails the test if it does); the live
// state must equal a fold of the log; and a seed must replay byte for byte.
func TestRandomCommands(t *testing.T) {
	var appended int
	for seed := uint64(1); seed <= 200; seed++ {
		h1, n := randomRun(t, seed, 600)
		h2, _ := randomRun(t, seed, 600)
		if h1 != h2 {
			t.Fatalf("seed %d: same seed gave different logs", seed)
		}
		appended += n
	}
	// Refusing everything is trivially safe; require real progress.
	if appended < 200*100 {
		t.Fatalf("only %d events appended", appended)
	}
}

func randomRun(t *testing.T, seed uint64, steps int) (string, int) {
	rng := rand.New(rand.NewPCG(seed, 0))
	r := &replica{st: State{Sid: "s"}}
	if _, err := do(t, r, Cmd{Node: "a", By: "tan", Kind: Created, Data: CreatedData{Owner: "tan", Harness: "fake"}}); err != nil {
		t.Fatal(err)
	}
	for step := 0; step < steps; step++ {
		var c Cmd
		switch rng.IntN(4) {
		case 0:
			c = Cmd{Kind: Checkpoint, Data: CheckpointData{Files: []File{{Name: "f", Sha: fmt.Sprint(rng.IntN(3))}}}}
		case 1:
			c = Cmd{Kind: Input, Key: fmt.Sprint(rng.IntN(8)), Data: InputData{Text: "x"}}
		case 2:
			c = Cmd{Kind: Out, Line: []byte("x")}
		case 3:
			c = Cmd{Kind: Exited, Data: ExitedData{}}
		}
		c.Node, c.By = "a", "tan"
		do(t, r, c)
	}
	st, err := Fold(decode(t, r.lines))
	if err != nil || st.Head != r.st.Head || st.Running != r.st.Running || st.Run != r.st.Run {
		t.Fatalf("seed %d: fold differs from live state: %v", seed, err)
	}
	h := sha256.New()
	for _, l := range r.lines {
		h.Write(l)
	}
	return fmt.Sprintf("%x", h.Sum(nil)), len(r.lines)
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

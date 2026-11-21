package journal

import (
	"context"
	"os"
	"testing"
	"time"
)

func open(t *testing.T, dir string) *Journal {
	t.Helper()
	j, err := Open(dir, 2*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	return j
}

func TestDurablePrefixAndDedupe(t *testing.T) {
	dir := t.TempDir()
	j := open(t, dir)
	s1, dup, err := j.Append(Event{Sid: "s", Kind: "input", By: "tan", Key: "k1"}, nil)
	if err != nil || dup || s1 != 1 {
		t.Fatalf("append: %d %v %v", s1, dup, err)
	}
	s2, dup, _ := j.Append(Event{Sid: "s", Kind: "input", By: "tan", Key: "k1"}, nil)
	if !dup || s2 != 1 {
		t.Fatalf("dedupe failed: %d %v", s2, dup)
	}
	s3, dup, _ := j.Append(Event{Sid: "s", Kind: "input", By: "bob", Key: "k1"}, nil)
	if dup || s3 != 2 {
		t.Fatalf("keys must be scoped per principal: %d %v", s3, dup)
	}
	if err := j.WaitDurable(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	ev, _, _ := j.Read(0, 0)
	if len(ev) != 2 {
		t.Fatalf("want 2 durable events, got %d", len(ev))
	}
	j.Close()

	j = open(t, dir)
	defer j.Close()
	if _, dup, _ := j.Append(Event{Sid: "s", Kind: "input", By: "tan", Key: "k1"}, nil); !dup {
		t.Fatal("dedupe set must be rebuilt from the log")
	}
}

func TestTornTailTruncated(t *testing.T) {
	dir := t.TempDir()
	j := open(t, dir)
	j.Append(Event{Sid: "s", Kind: "a"}, []byte("raw-a\n"))
	j.Append(Event{Sid: "s", Kind: "b"}, nil)
	j.Close()
	f, _ := os.OpenFile(dir+"/events.jsonl", os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"v":1,"sid":"s","seq":3,"ki`)
	f.Close()

	j = open(t, dir)
	defer j.Close()
	if h := j.Head(); h != 2 {
		t.Fatalf("head %d, want 2", h)
	}
	seq, _, _ := j.Append(Event{Sid: "s", Kind: "c"}, nil)
	if seq != 3 {
		t.Fatalf("seq %d, want 3", seq)
	}
	ev := j.All()
	b, err := j.ReadRaw(*ev[0].Raw)
	if err != nil || string(b) != "raw-a\n" {
		t.Fatalf("raw: %q %v", b, err)
	}
}

func TestReplicaMustMatch(t *testing.T) {
	src := open(t, t.TempDir())
	defer src.Close()
	src.Append(Event{Sid: "s", Kind: "a"}, nil)
	src.Append(Event{Sid: "s", Kind: "b"}, nil)
	src.WaitDurable(context.Background(), 2)
	_, lines, _ := src.Read(0, 0)

	dst := open(t, t.TempDir())
	defer dst.Close()
	for _, l := range lines {
		if err := dst.AppendReplica(l); err != nil {
			t.Fatal(err)
		}
	}
	if err := dst.AppendReplica(lines[0]); err != nil {
		t.Fatalf("re-pull of identical line must be a no-op: %v", err)
	}
	other := []byte(`{"v":1,"sid":"s","seq":2,"run":0,"node":"x","t":"","kind":"zzz"}`)
	if err := dst.AppendReplica(other); err == nil {
		t.Fatal("divergent line accepted")
	}
}

func TestReadersBlockUntilDurable(t *testing.T) {
	j, _ := Open(t.TempDir(), time.Hour) // never flushes on its own
	j.Append(Event{Sid: "s", Kind: "a"}, nil)
	if ev, _, _ := j.Read(0, 0); len(ev) != 0 {
		t.Fatal("reader saw an event before fsync")
	}
	j.flush()
	if ev, _, _ := j.Read(0, 0); len(ev) != 1 {
		t.Fatal("event not visible after fsync")
	}
	j.Close()
}

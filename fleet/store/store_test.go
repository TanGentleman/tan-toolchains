package store

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func validJSON(b []byte) error {
	if !json.Valid(b) {
		return fmt.Errorf("bad line")
	}
	return nil
}

// TestCrashAtEveryByte cuts the file at every offset, as a crash mid-write
// could, and checks that Open keeps exactly the complete lines and that the
// log accepts appends afterwards.
func TestCrashAtEveryByte(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "events.jsonl")
	l, err := Open(path, validJSON)
	if err != nil {
		t.Fatal(err)
	}
	want := [][]byte{[]byte(`{"seq":1}`), []byte(`{"seq":2,"t":"x"}`), []byte(`{"seq":3,"data":"héllo"}`)}
	if err := l.Append(want[0]); err != nil {
		t.Fatal(err)
	}
	if err := l.Append(want[1:]...); err != nil {
		t.Fatal(err)
	}
	l.Close()
	full, _ := os.ReadFile(path)
	for cut := 0; cut <= len(full); cut++ {
		p := filepath.Join(dir, fmt.Sprintf("cut-%d", cut))
		os.WriteFile(p, full[:cut], 0o644)
		l, err := Open(p, validJSON)
		if err != nil {
			t.Fatal(err)
		}
		complete := bytes.Count(full[:cut], []byte{'\n'})
		got, _ := l.Read(0)
		if len(got) != complete {
			t.Fatalf("cut %d: %d lines, want %d", cut, len(got), complete)
		}
		if err := l.Append([]byte(`{"seq":"next"}`)); err != nil {
			t.Fatal(err)
		}
		l.Close()
		after, _ := os.ReadFile(p)
		if !strings.HasSuffix(string(after), "\n"+`{"seq":"next"}`+"\n") && complete > 0 {
			t.Fatalf("cut %d: torn tail not removed: %q", cut, after)
		}
	}
}

func TestReadSeesOnlyAppended(t *testing.T) {
	l, err := Open(filepath.Join(t.TempDir(), "e.jsonl"), validJSON)
	if err != nil {
		t.Fatal(err)
	}
	lines, ch := l.Read(0)
	if len(lines) != 0 {
		t.Fatal("empty log returned lines")
	}
	l.Append([]byte(`1`))
	select {
	case <-ch:
	default:
		t.Fatal("append did not wake readers")
	}
	if err := l.Append([]byte("a\nb")); err == nil {
		t.Fatal("a line with a newline must be refused")
	}
	if l.Len() != 1 {
		t.Fatalf("len %d", l.Len())
	}
}

func TestBlobs(t *testing.T) {
	b := Blobs{Dir: t.TempDir()}
	sha, n, err := b.Put(strings.NewReader("state"))
	if got, _ := os.ReadFile(b.Path(sha)); err != nil || n != 5 || string(got) != "state" {
		t.Fatal(sha, n, err)
	}
}

// TestRejectedLineRefused: a complete line the caller rejects (a log from a
// version with other rules) makes Open fail and leaves every byte in place.
func TestRejectedLineRefused(t *testing.T) {
	p := filepath.Join(t.TempDir(), "events.jsonl")
	body := "{\"seq\":1}\nnot json\n{\"seq\":3}\n{\"torn\""
	os.WriteFile(p, []byte(body), 0o600)
	if _, err := Open(p, validJSON); err == nil || !strings.Contains(err.Error(), "line 2") {
		t.Fatalf("Open = %v, want a refusal naming line 2", err)
	}
	if after, _ := os.ReadFile(p); string(after) != body {
		t.Fatalf("refused log was changed: %q", after)
	}
}

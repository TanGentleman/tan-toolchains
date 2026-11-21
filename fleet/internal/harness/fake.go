package harness

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Fake is a deterministic, keyless harness. It keeps its own native
// transcript (fake.jsonl) so resume on another node can be checked: the
// reply counts every turn the transcript holds. "TOOL" in a prompt produces
// a tool call; "SLOW" makes the turn take Slow, so it can be cancelled.
type Fake struct{ Slow time.Duration }

func (Fake) NativeFiles() []string { return []string{"fake.jsonl"} }

type fakeProc struct {
	f      Fake
	path   string
	out    chan Out
	in     chan Input
	cancel chan struct{}
	done   chan struct{}
	once   sync.Once
	turns  int
}

func (f Fake) Start(ctx context.Context, s Spec) (Proc, error) {
	if err := os.MkdirAll(s.Native, 0o755); err != nil {
		return nil, err
	}
	p := &fakeProc{f: f, path: filepath.Join(s.Native, "fake.jsonl"), out: make(chan Out, 64),
		in: make(chan Input, 64), cancel: make(chan struct{}, 1), done: make(chan struct{})}
	if s.Resume {
		n, err := countLines(p.path)
		if err != nil {
			return nil, fmt.Errorf("fake: resume: %w", err)
		}
		p.turns = n
	}
	go p.loop()
	return p, nil
}

func countLines(path string) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	n := 0
	for sc := bufio.NewScanner(f); sc.Scan(); n++ {
	}
	return n, nil
}

func (p *fakeProc) Send(in Input) error {
	if in.Kind == "cancel" {
		select {
		case p.cancel <- struct{}{}:
		default:
		}
		return nil
	}
	select {
	case p.in <- in:
		return nil
	case <-p.done:
		return fmt.Errorf("fake: closed")
	}
}

func (p *fakeProc) Out() <-chan Out { return p.out }

func (p *fakeProc) Close() error {
	p.once.Do(func() { close(p.done) })
	for range p.out {
	}
	return nil
}

func (p *fakeProc) emit(native map[string]any, evs ...Event) {
	b, _ := json.Marshal(native)
	p.out <- Out{Raw: append(b, '\n'), Events: evs}
}

func (p *fakeProc) loop() {
	defer close(p.out)
	for {
		select {
		case <-p.done:
			return
		case in := <-p.in:
			p.turn(in)
		}
	}
}

func (p *fakeProc) turn(in Input) {
	select {
	case <-p.cancel: // drop a stale cancel
	default:
	}
	p.emit(map[string]any{"type": "turn_start"}, Event{Kind: "turn.start"})
	if strings.Contains(in.Text, "TOOL") {
		args := map[string]any{"command": "echo FAKE_TOOL_OK"}
		p.emit(map[string]any{"type": "tool", "id": "t1", "args": args},
			Event{Kind: "tool.call", Data: map[string]any{"id": "t1", "name": "bash", "args": args, "effect": "once"}})
		p.emit(map[string]any{"type": "tool_result", "id": "t1", "output": "FAKE_TOOL_OK"},
			Event{Kind: "tool.result", Data: map[string]any{"id": "t1", "text": "FAKE_TOOL_OK"}})
	}
	if strings.Contains(in.Text, "SLOW") && p.f.Slow > 0 {
		select {
		case <-time.After(p.f.Slow):
		case <-p.cancel:
			p.emit(map[string]any{"type": "aborted"}, Event{Kind: "turn.end", Data: map[string]any{"reason": "aborted"}})
			return
		case <-p.done:
			return
		}
	}
	p.turns++
	reply := fmt.Sprintf("turn %d: %s", p.turns, in.Text)
	if err := appendLine(p.path, map[string]any{"user": in.Text, "assistant": reply}); err != nil {
		p.emit(map[string]any{"type": "error", "error": err.Error()}, Event{Kind: "error", Data: map[string]any{"text": err.Error()}})
		return
	}
	p.emit(map[string]any{"type": "assistant", "text": reply},
		Event{Kind: "message", Data: map[string]any{"role": "assistant", "text": reply}})
	p.emit(map[string]any{"type": "turn_end"}, Event{Kind: "turn.end", Data: map[string]any{"reason": "done"}})
}

func appendLine(path string, v any) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	b, _ := json.Marshal(v)
	if _, err := f.Write(append(b, '\n')); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

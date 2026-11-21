package harness

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// Pi drives `pi --mode rpc` and keeps Pi's own session file in Spec.Native.
// Cmd is the command prefix, e.g. ["pi"] or a wrapper that runs Pi inside
// pi-container; Args are appended (provider, model, ...).
type Pi struct {
	Cmd  []string
	Args []string
	Env  []string
}

func (Pi) NativeFiles() []string { return []string{"pi.jsonl"} }

type piProc struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	out   chan Out

	mu    sync.Mutex
	busy  bool
	queue []Input
}

func (h Pi) Start(ctx context.Context, s Spec) (Proc, error) {
	if len(h.Cmd) == 0 {
		return nil, fmt.Errorf("pi: no command")
	}
	if err := os.MkdirAll(s.Native, 0o755); err != nil {
		return nil, err
	}
	native := filepath.Join(s.Native, "pi.jsonl")
	if s.Resume {
		if _, err := os.Stat(native); err != nil {
			return nil, fmt.Errorf("pi: resume needs %s: %w", native, err)
		}
	}
	args := append(append([]string{}, h.Cmd[1:]...), h.Args...)
	args = append(args, "--mode", "rpc", "--session", native)
	cmd := exec.Command(h.Cmd[0], args...)
	cmd.Dir = s.Work
	cmd.Env = append(os.Environ(), h.Env...)
	stderr, err := os.OpenFile(filepath.Join(s.Native, "pi.stderr"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	cmd.Stderr = stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	p := &piProc{cmd: cmd, stdin: stdin, out: make(chan Out, 256)}
	go func() {
		defer stderr.Close()
		defer close(p.out)
		r := bufio.NewReaderSize(stdout, 1<<20)
		for {
			line, err := r.ReadBytes('\n')
			if len(line) > 0 {
				p.out <- Out{Raw: line, Events: p.normalize(line)}
			}
			if err != nil {
				cmd.Wait()
				return
			}
		}
	}()
	return p, nil
}

func (p *piProc) write(v any) error {
	b, _ := json.Marshal(v)
	_, err := p.stdin.Write(append(b, '\n'))
	return err
}

// Send forwards steer and cancel at once; prompts wait until Pi is idle,
// because Pi rejects a plain prompt while a turn is running.
func (p *piProc) Send(in Input) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	switch in.Kind {
	case "cancel":
		return p.write(map[string]any{"id": in.Key, "type": "abort"})
	case "steer":
		if p.busy {
			return p.write(map[string]any{"id": in.Key, "type": "steer", "message": in.Text})
		}
	}
	if p.busy {
		p.queue = append(p.queue, in)
		return nil
	}
	p.busy = true
	return p.write(map[string]any{"id": in.Key, "type": "prompt", "message": in.Text})
}

func (p *piProc) settled() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.busy = false
	if len(p.queue) > 0 {
		next := p.queue[0]
		p.queue = p.queue[1:]
		p.busy = true
		p.write(map[string]any{"id": next.Key, "type": "prompt", "message": next.Text})
	}
}

func (p *piProc) Out() <-chan Out { return p.out }

func (p *piProc) Close() error {
	p.stdin.Close()
	for range p.out {
	}
	return nil
}

type piMsg struct {
	Role       string          `json:"role"`
	Content    json.RawMessage `json:"content"`
	ToolCallID string          `json:"toolCallId"`
	ToolName   string          `json:"toolName"`
	IsError    bool            `json:"isError"`
}

type piPart struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

func (p *piProc) normalize(line []byte) []Event {
	var r struct {
		Type    string `json:"type"`
		Success *bool  `json:"success"`
		Error   string `json:"error"`
		Aborted bool   `json:"aborted"`
		Message *piMsg `json:"message"`
	}
	if json.Unmarshal(line, &r) != nil {
		return nil
	}
	switch r.Type {
	case "agent_start":
		return []Event{{Kind: "turn.start"}}
	case "agent_settled":
		reason := "done"
		if r.Aborted {
			reason = "aborted"
		}
		defer p.settled()
		return []Event{{Kind: "turn.end", Data: map[string]any{"reason": reason}}}
	case "response":
		if r.Success != nil && !*r.Success {
			p.settled()
			return []Event{{Kind: "error", Data: map[string]any{"text": r.Error}}}
		}
	case "message_end":
		if r.Message == nil {
			return nil
		}
		return piMessage(r.Message)
	}
	return nil
}

func piMessage(m *piMsg) []Event {
	var parts []piPart
	if json.Unmarshal(m.Content, &parts) != nil {
		var s string
		json.Unmarshal(m.Content, &s)
		parts = []piPart{{Type: "text", Text: s}}
	}
	var text []string
	var evs []Event
	for _, c := range parts {
		switch c.Type {
		case "text":
			text = append(text, c.Text)
		case "toolCall":
			evs = append(evs, Event{Kind: "tool.call", Data: map[string]any{"id": c.ID, "name": c.Name, "args": c.Arguments, "effect": "once"}})
		}
	}
	joined := strings.Join(text, "")
	switch m.Role {
	case "assistant":
		if joined != "" {
			evs = append([]Event{{Kind: "message", Data: map[string]any{"role": "assistant", "text": joined}}}, evs...)
		}
		return evs
	case "toolResult":
		return []Event{{Kind: "tool.result", Data: map[string]any{"id": m.ToolCallID, "name": m.ToolName, "text": joined, "error": m.IsError}}}
	}
	return nil
}

// Package fake is a deterministic harness for tests. It speaks the same
// stdin shape as Pi's RPC mode ({"type":"prompt","id","message"}) and keeps
// a turn counter in its state directory, so a test can tell whether a resumed
// run really loaded the earlier history: the turn number keeps counting.
package fake

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type state struct {
	Turns int      `json:"turns"`
	Seen  []string `json:"seen"`
}

// ExitCode is returned by Run when a prompt says "exit N".
type ExitCode int

func (e ExitCode) Error() string { return fmt.Sprintf("exit %d", int(e)) }
func (e ExitCode) ExitCode() int { return int(e) }

func Run(in io.Reader, out io.Writer, dir string) error {
	path := filepath.Join(dir, "fake.json")
	var st state
	if b, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(b, &st); err != nil {
			return err
		}
	}
	enc := json.NewEncoder(out)
	enc.Encode(map[string]any{"type": "ready", "turns": st.Turns})
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		var m struct{ Type, ID, Message string }
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			enc.Encode(map[string]any{"type": "error", "error": err.Error()})
			continue
		}
		switch m.Type {
		case "prompt", "steer":
			var code int
			if n, _ := fmt.Sscanf(m.Message, "exit %d", &code); n == 1 {
				return ExitCode(code)
			}
			st.Turns++
			st.Seen = append(st.Seen, m.Message)
			b, _ := json.Marshal(st)
			if err := os.WriteFile(path+".tmp", b, 0o644); err != nil {
				return err
			}
			if err := os.Rename(path+".tmp", path); err != nil {
				return err
			}
			enc.Encode(map[string]any{"type": "reply", "id": m.ID, "turn": st.Turns, "text": "echo: " + m.Message})
		case "abort":
			enc.Encode(map[string]any{"type": "aborted", "id": m.ID})
		default:
			enc.Encode(map[string]any{"type": "error", "id": m.ID, "error": "unknown type " + m.Type})
		}
	}
	return sc.Err()
}

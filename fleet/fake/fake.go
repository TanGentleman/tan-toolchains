// Package fake is a deterministic harness for tests. Each turn reads the
// prompt and bumps a turn counter kept in the state directory, so a test can
// tell whether a turn on another node really continued from the checkpoint:
// the turn number keeps counting. "exit N" exits with N; "sleep" blocks
// until the turn is cancelled.
package fake

import (
	"context"
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

func Run(ctx context.Context, dir, prompt string, out io.Writer) (int, error) {
	path := filepath.Join(dir, "fake.json")
	var st state
	if b, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(b, &st); err != nil {
			return 1, err
		}
	}
	var code int
	if n, _ := fmt.Sscanf(prompt, "exit %d", &code); n == 1 {
		return code, nil
	}
	enc := json.NewEncoder(out)
	if prompt == "sleep" {
		enc.Encode(map[string]any{"type": "sleeping", "turn": st.Turns + 1})
		<-ctx.Done()
		return -1, nil
	}
	st.Turns++
	st.Seen = append(st.Seen, prompt)
	b, _ := json.Marshal(st)
	if err := os.WriteFile(path+".tmp", b, 0o600); err != nil {
		return 1, err
	}
	if err := os.Rename(path+".tmp", path); err != nil {
		return 1, err
	}
	return 0, enc.Encode(map[string]any{"type": "reply", "turn": st.Turns, "text": "echo: " + prompt})
}

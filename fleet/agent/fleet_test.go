package agent

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestLive talks to the real OpenRouter. It needs FLEET_LIVE=1 and
// OPENROUTER_API_KEY, costs a few cents, and is never run by CI. Models
// default to cheap ones; override with FLEET_LIVE_<KIND>_MODEL.
func TestLive(t *testing.T) {
	key := os.Getenv("OPENROUTER_API_KEY")
	if os.Getenv("FLEET_LIVE") != "1" || key == "" {
		t.Skip("set FLEET_LIVE=1 and OPENROUTER_API_KEY")
	}
	for _, kind := range kinds {
		t.Run(kind, func(t *testing.T) {
			b := bin(t, kind)
			model := liveModels[kind]
			w := newWorld(t, "openrouter.ai,.openrouter.ai,127.0.0.1,localhost")
			root := t.TempDir()
			cfg := func(n string) Config {
				os.MkdirAll(filepath.Join(root, n, "work"), 0o755)
				return Config{Kind: kind, Model: model, Bin: b, Key: key,
					State: filepath.Join(root, n, "state"), Work: filepath.Join(root, n, "work")}
			}
			a := start(t, cfg("a"))
			out, end := a.turn("t1", "Remember the codeword TOKZEBRA. Reply with only the word OK.")
			if end == nil || end["code"].(float64) != 0 {
				t.Fatalf("turn 1: %v\n%s\nstderr:\n%s", end, strings.Join(out, "\n"), a.errb)
			}
			a.close()
			os.MkdirAll(filepath.Join(root, "b"), 0o755)
			copyDir(t, filepath.Join(root, "a", "state"), filepath.Join(root, "b", "state"))
			bs := start(t, cfg("b"))
			out, end = bs.turn("t2", "What was the codeword? Reply with only the codeword.")
			if end == nil || end["code"].(float64) != 0 || !contains(out, "TOKZEBRA") {
				t.Fatalf("turn 2 forgot the codeword: %v\n%s\nstderr:\n%s", end, strings.Join(out, "\n"), bs.errb)
			}
			bs.close()
			if hs := w.trap.Hosts(); len(hs) > 0 {
				t.Fatalf("traffic besides openrouter.ai: %v", hs)
			}
			noSecret(t, key, root, strings.Join(a.all, "\n"), strings.Join(bs.all, "\n"), a.errb.String(), bs.errb.String())
		})
	}
}

// Cheap defaults for live runs; override with FLEET_LIVE_<KIND>_MODEL.
var liveModels = func() map[string]string {
	m := map[string]string{"pi": "thinkingmachines/inkling-2-small", "claude": "anthropic/claude-haiku-5.5", "codex": "openai/gpt-6-luna"}
	for k := range m {
		if v := os.Getenv("FLEET_LIVE_" + strings.ToUpper(k) + "_MODEL"); v != "" {
			m[k] = v
		}
	}
	return m
}()

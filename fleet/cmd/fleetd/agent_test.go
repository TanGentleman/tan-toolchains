package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeCtr installs a pi-ctr that runs script and points FLEET_PI_CTR_BIN at it.
func fakeCtr(t *testing.T, script string) {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "pi-ctr")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\n"+script+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FLEET_PI_CTR_BIN", bin)
}

func TestPiConfig(t *testing.T) {
	t.Setenv("HOME", "/home/x")
	t.Setenv("PI_CONFIG_DIR", "/cfg")
	t.Setenv("OPENROUTER_API_KEY", "sk-or-v1-real")
	fakeCtr(t, `[ "$1" = --config ] || exit 9
[ "$PI_CTR_HOME" = /home/x ] && [ "$PI_CONFIG_DIR" = /cfg ] && [ -z "$OPENROUTER_API_KEY" ] || exit 8
echo '{"v":1,"config":"/cfg/config.json","image":"min","tag":"pi-min:local","egress":"offline","model_url":"http://gateway:8090","source":{"image":"file"}}'`)
	c, err := piConfig()
	if err != nil {
		t.Fatal(err)
	}
	if want := (NodeConfig{Image: "min", Egress: "offline", ModelURL: "http://gateway:8090"}); c != want {
		t.Fatalf("got %+v, want %+v", c, want)
	}
}

func TestPiConfigRefusals(t *testing.T) {
	for _, tc := range []struct{ script, want string }{
		{`echo 'run.sh: /cfg/config.json needs "v": 1, not 2' >&2; exit 2`, `needs "v": 1, not 2`},
		{`echo '{"v":2,"image":"min","egress":"standard","model_url":"openrouter"}'`, `want {"v":1`},
		{`echo '{"v":1,"image":"min"}'`, `want {"v":1`},
		{`echo nope`, `got "nope"`},
	} {
		fakeCtr(t, tc.script)
		if _, err := piConfig(); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err %v, want %q", tc.script, err, tc.want)
		}
	}
}

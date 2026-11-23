package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/TanGentleman/tan-toolchains/fleet/agent"
)

// runAgent is `fleetd agent KIND [-model M] [-bin PATH] [-- CLI ARGS]`, the
// harness fleetd registers as pi-ctr. KIND pi-ctr runs Pi's adapter with
// -bin pi-container/pi-ctr: Pi runs in pi-container's normal mode, the child
// gets only the placeholder key, and the proxy holds the real one. It runs one turn with
// the prompt read from stdin. Unset flags fall back to
// FLEET_SESSION_MODEL (the model chosen at spawn, set by the node),
// FLEET_<KIND>_MODEL, FLEET_MODEL and FLEET_<KIND>_BIN.
func runAgent(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: fleetd agent pi-ctr|pi|claude|codex [-model M] [-bin PATH] [-- CLI ARGS]")
		return 2
	}
	kind := args[0]
	up := strings.ToUpper(strings.ReplaceAll(kind, "-", "_"))
	fs := flag.NewFlagSet("agent", flag.ContinueOnError)
	model := fs.String("model", firstEnv("FLEET_SESSION_MODEL", "FLEET_"+up+"_MODEL", "FLEET_MODEL"), "OpenRouter model id")
	bin := fs.String("bin", os.Getenv("FLEET_"+up+"_BIN"), "CLI executable (default: "+kind+" on PATH)")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	prompt, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "fleetd agent:", err)
		return 1
	}
	c := agent.Config{
		Kind: kind, Model: *model, Bin: *bin, Args: fs.Args(),
		State: os.Getenv("FLEET_STATE"), Work: os.Getenv("FLEET_WORK"),
		Key: os.Getenv("OPENROUTER_API_KEY"), Base: os.Getenv("FLEET_OPENROUTER_BASE"),
	}
	if kind == "pi-ctr" {
		if c, err = piCtr(c); err != nil {
			fmt.Fprintln(os.Stderr, "fleetd agent:", err)
			return 1
		}
	}
	err = agent.Run(c, string(prompt), os.Stdout, os.Stderr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "fleetd agent:", err)
		if errors.Is(err, agent.ErrSession) {
			return 3
		}
		return 1
	}
	return 0
}

// PiPlaceholder is the key Pi sees in pi-container's normal mode; the proxy
// swaps in the real one.
const PiPlaceholder = "sk-or-v1-placeholder"

// ctrEnv is what pi-ctr needs from fleetd's environment besides the adapter's
// allowlist: the turn, and how to reach run.sh's config and container CLI.
var ctrEnv = []string{
	"FLEET_SID", "FLEET_STATE", "FLEET_REPO", "FLEET_BRANCH", "FLEET_BASE", "FLEET_PUSH", "FLEET_RESULT",
	"PI_CONFIG_DIR", "PI_ENV_FILE", "PI_IMAGE", "PI_CPUS", "PI_MEMORY", "PI_CTR_MAX_FILE_BYTES", "CONTAINER_CLI",
}

func piCtr(c agent.Config) (agent.Config, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return c, err
	}
	if c.Bin == "" {
		c.Bin = "pi-ctr"
	}
	c.Kind, c.Contained, c.Key = "pi", true, PiPlaceholder
	// run.sh finds its config and checks mounts against the real home, not
	// the adapter's.
	c.Env = append(c.Env, "PI_CTR_HOME="+home)
	for _, k := range ctrEnv {
		if v, ok := os.LookupEnv(k); ok {
			c.Env = append(c.Env, k+"="+v)
		}
	}
	return c, nil
}

func firstEnv(names ...string) string {
	for _, n := range names {
		if v := os.Getenv(n); v != "" {
			return v
		}
	}
	return ""
}

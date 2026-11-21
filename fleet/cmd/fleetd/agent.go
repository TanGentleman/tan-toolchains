package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/TanGentleman/tan-toolchains/fleet/agent"
)

// runAgent is `fleetd agent KIND [-model M] [-bin PATH] [-- CLI ARGS]`, the
// harness fleetd registers as pi, claude and codex. Unset flags fall back to
// FLEET_<KIND>_MODEL, FLEET_MODEL and FLEET_<KIND>_BIN.
func runAgent(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: fleetd agent pi|claude|codex [-model M] [-bin PATH] [-- CLI ARGS]")
		return 2
	}
	kind := args[0]
	up := strings.ToUpper(kind)
	fs := flag.NewFlagSet("agent", flag.ContinueOnError)
	model := fs.String("model", firstEnv("FLEET_"+up+"_MODEL", "FLEET_MODEL"), "OpenRouter model id")
	bin := fs.String("bin", os.Getenv("FLEET_"+up+"_BIN"), "CLI executable (default: "+kind+" on PATH)")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	err := agent.Run(agent.Config{
		Kind: kind, Model: *model, Bin: *bin, Args: fs.Args(),
		State: os.Getenv("FLEET_STATE"), Work: os.Getenv("FLEET_WORK"),
		Key: os.Getenv("OPENROUTER_API_KEY"), Base: os.Getenv("FLEET_OPENROUTER_BASE"),
	}, os.Stdin, os.Stdout, os.Stderr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "fleetd agent:", err)
		if errors.Is(err, agent.ErrSession) {
			return 3
		}
		return 1
	}
	return 0
}

func firstEnv(names ...string) string {
	for _, n := range names {
		if v := os.Getenv(n); v != "" {
			return v
		}
	}
	return ""
}

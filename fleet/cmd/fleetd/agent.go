package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/agent"
)

// runPiCtr is `fleetd pi-ctr [-model M] [-bin PATH] [-stop] [-- PI ARGS]`,
// the command fleetd runs once per turn of its pi-ctr harness. It runs Pi
// through pi-container/pi-ctr (in the locked VM, placeholder key) with the
// prompt read from stdin. -model defaults to $FLEET_SESSION_MODEL, the model
// chosen at spawn; -bin to $FLEET_PI_CTR_BIN, else pi-ctr on PATH. -stop
// runs `pi-ctr --stop`, which removes the session's container; fleetd runs it
// for a turn the previous fleetd left running.
func runPiCtr(args []string) int {
	fs := flag.NewFlagSet("pi-ctr", flag.ContinueOnError)
	model := fs.String("model", os.Getenv("FLEET_SESSION_MODEL"), "OpenRouter model id")
	bin := fs.String("bin", os.Getenv("FLEET_PI_CTR_BIN"), "pi-ctr executable (default: pi-ctr on PATH)")
	stop := fs.Bool("stop", false, "remove the session's container and exit")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, "fleetd pi-ctr:", err)
		return 1
	}
	if *bin == "" {
		*bin = "pi-ctr"
	}
	// run.sh finds its config and checks mounts against the real home.
	env := []string{"PI_CTR_HOME=" + home}
	for _, k := range ctrEnv {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
		}
	}
	stopCtr := func() error {
		cmd := exec.Command(*bin, "--stop")
		cmd.Env, cmd.Stdout, cmd.Stderr = env, os.Stderr, os.Stderr
		return cmd.Run()
	}
	if *stop {
		if err := stopCtr(); err != nil {
			fmt.Fprintln(os.Stderr, "fleetd pi-ctr -stop:", err)
			return 1
		}
		return 0
	}
	prompt, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "fleetd pi-ctr:", err)
		return 1
	}
	go orphanWatch(stopCtr)
	err = agent.Run(agent.Config{Model: *model, State: os.Getenv("FLEET_STATE"), Bin: *bin, Args: fs.Args(), Env: env},
		string(prompt), os.Stdout, os.Stderr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "fleetd pi-ctr:", err)
		if errors.Is(err, agent.ErrSession) {
			return 3
		}
		return 1
	}
	return 0
}

// orphanWatch ends the turn when fleetd dies without stopping it (kill -9):
// fleetd starts this process as the leader of the turn's process group, so
// once the parent is gone it removes the container and kills the group, and
// nothing the dead turn started can write to the state folder or push
// later. Outside a group of its own (run by hand) it does nothing.
func orphanWatch(stopCtr func() error) {
	if syscall.Getpgrp() != os.Getpid() {
		return
	}
	parent := os.Getppid()
	for os.Getppid() == parent {
		time.Sleep(200 * time.Millisecond)
	}
	fmt.Fprintln(os.Stderr, "fleetd pi-ctr: fleetd is gone; stopping the turn")
	stopCtr()
	syscall.Kill(0, syscall.SIGKILL)
}

// ctrEnv is what pi-ctr needs from fleetd's environment besides the
// adapter's allowlist: the turn, and how to reach run.sh's config and the
// container CLI.
var ctrEnv = []string{
	"FLEET_SID", "FLEET_STATE", "FLEET_REPO", "FLEET_BRANCH", "FLEET_BASE", "FLEET_PUSH", "FLEET_RESULT",
	"PI_CONFIG_DIR", "PI_ENV_FILE", "PI_IMAGE", "PI_CPUS", "PI_MEMORY", "PI_CTR_MAX_FILE_BYTES", "CONTAINER_CLI",
}

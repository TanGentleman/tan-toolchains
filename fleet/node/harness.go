package node

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"slices"
	"strings"
	"syscall"
	"time"
)

// A Harness runs one turn of an agent: one process, the prompt on stdin,
// every stdout line recorded verbatim. Whatever must carry over to the next
// turn lives in Turn.State: the node rebuilds that directory from the latest
// checkpoint before each turn and checkpoints it after.
type Harness interface {
	Run(ctx context.Context, t Turn, stdout io.Writer) (code int, err error)
}

// A Stopper stops whatever a turn left running when the fleetd that ran it
// died mid-turn. fleetd calls it at start, before recording that turn as
// exited, and refuses to start if it fails.
type Stopper interface {
	Stop(sid, state string) error
}

type Turn struct {
	Sid    string
	Prompt string
	Model  string // chosen at spawn; "" means the harness default
	State  string // harness-owned files, checkpointed; also the working directory
	Repo   string // OWNER/REPO to clone, "" for none
	Branch string // branch chosen at spawn
	Base   string // commit to start from when Push doesn't exist yet
	Push   string // branch the turn pushes to, fleet/<sid>
	Result string // file where the harness reports {"commit","base"}
	Stderr io.Writer
}

// Exec runs a command per turn in Turn.State. $FLEET_SID and $FLEET_STATE in
// Argv are expanded, and the same names are set in the environment, plus
// $FLEET_SESSION_MODEL when the session has a model, and $FLEET_REPO,
// $FLEET_BRANCH, $FLEET_BASE, $FLEET_PUSH and $FLEET_RESULT when it has a repo. Cancelling ctx sends
// the whole process group SIGTERM, then SIGKILL after Grace. StopArgv, if
// set, is what Stop runs, with $FLEET_SID and $FLEET_STATE set.
type Exec struct {
	Argv     []string
	StopArgv []string
	Env      []string
	Drop     []string      // names removed from fleetd's environment before Env is added
	Grace    time.Duration // default 3s
}

func (h Exec) env(vars map[string]string) []string {
	var env []string
	for _, kv := range os.Environ() {
		if k, _, _ := strings.Cut(kv, "="); !slices.Contains(h.Drop, k) {
			env = append(env, kv)
		}
	}
	env = append(env, h.Env...)
	for k, v := range vars {
		env = append(env, k+"="+v)
	}
	return env
}

func (h Exec) Stop(sid, state string) error {
	if len(h.StopArgv) == 0 {
		return nil
	}
	cmd := exec.Command(h.StopArgv[0], h.StopArgv[1:]...)
	cmd.Env = h.env(map[string]string{"FLEET_SID": sid, "FLEET_STATE": state})
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%s: %w: %s", strings.Join(h.StopArgv, " "), err, bytes.TrimSpace(out))
	}
	return nil
}

func (h Exec) Run(ctx context.Context, t Turn, stdout io.Writer) (int, error) {
	vars := map[string]string{"FLEET_SID": t.Sid, "FLEET_STATE": t.State}
	for k, v := range map[string]string{"FLEET_REPO": t.Repo, "FLEET_BRANCH": t.Branch, "FLEET_BASE": t.Base, "FLEET_PUSH": t.Push, "FLEET_RESULT": t.Result} {
		if v != "" {
			vars[k] = v
		}
	}
	argv := make([]string, len(h.Argv))
	for i, a := range h.Argv {
		argv[i] = os.Expand(a, func(k string) string {
			if v, ok := vars[k]; ok {
				return v
			}
			return "$" + k
		})
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = t.State
	cmd.Env = h.env(vars)
	if t.Model != "" {
		cmd.Env = append(cmd.Env, "FLEET_SESSION_MODEL="+t.Model)
	}
	cmd.Stdin = strings.NewReader(t.Prompt)
	cmd.Stdout, cmd.Stderr = stdout, t.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	grace := h.Grace
	if grace <= 0 {
		grace = 3 * time.Second
	}
	var kill *time.Timer
	cmd.Cancel = func() error {
		pg := -cmd.Process.Pid
		kill = time.AfterFunc(grace, func() { syscall.Kill(pg, syscall.SIGKILL) })
		return syscall.Kill(pg, syscall.SIGTERM)
	}
	cmd.WaitDelay = grace + 2*time.Second
	err := cmd.Run()
	if kill != nil {
		kill.Stop()
		syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) // whatever outlived the leader
	}
	if ee := (*exec.ExitError)(nil); errors.As(err, &ee) {
		return ee.ExitCode(), nil
	}
	if err != nil {
		return -1, err
	}
	return 0, nil
}

// Func runs a harness in-process; tests use it.
type Func func(ctx context.Context, t Turn, stdout io.Writer) (int, error)

func (f Func) Run(ctx context.Context, t Turn, stdout io.Writer) (int, error) {
	return f(ctx, t, stdout)
}

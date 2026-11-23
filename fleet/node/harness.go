package node

import (
	"context"
	"errors"
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
// turn, on this node or another, lives in Turn.State: the node rebuilds that
// directory from the latest checkpoint before each turn and checkpoints it
// after.
type Harness interface {
	Run(ctx context.Context, t Turn, stdout io.Writer) (code int, err error)
}

type Turn struct {
	Sid    string
	Prompt string
	Model  string // chosen at spawn; "" means the harness default
	State  string // harness-owned files, checkpointed and moved on handoff
	Work   string // working directory; not replicated
	Stderr io.Writer
}

// Exec runs a command per turn. $FLEET_SID, $FLEET_STATE and $FLEET_WORK in
// Argv are expanded, and the same names are set in the environment, plus
// $FLEET_SESSION_MODEL when the session has a model. Cancelling ctx kills
// the whole process group.
type Exec struct {
	Argv []string
	Env  []string
	Drop []string // names removed from fleetd's environment before Env is added
}

func (h Exec) Run(ctx context.Context, t Turn, stdout io.Writer) (int, error) {
	vars := map[string]string{"FLEET_SID": t.Sid, "FLEET_STATE": t.State, "FLEET_WORK": t.Work}
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
	cmd.Dir = t.Work
	for _, kv := range os.Environ() {
		if k, _, _ := strings.Cut(kv, "="); !slices.Contains(h.Drop, k) {
			cmd.Env = append(cmd.Env, kv)
		}
	}
	cmd.Env = append(cmd.Env, h.Env...)
	for k, v := range vars {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	if t.Model != "" {
		cmd.Env = append(cmd.Env, "FLEET_SESSION_MODEL="+t.Model)
	}
	cmd.Stdin = strings.NewReader(t.Prompt)
	cmd.Stdout, cmd.Stderr = stdout, t.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
	err := cmd.Run()
	if ee := (*exec.ExitError)(nil); errors.As(err, &ee) {
		return ee.ExitCode(), nil
	}
	if err != nil {
		return -1, err
	}
	return 0, nil
}

// Func runs a harness in-process; tests use it with fake.Run.
type Func func(ctx context.Context, t Turn, stdout io.Writer) (int, error)

func (f Func) Run(ctx context.Context, t Turn, stdout io.Writer) (int, error) {
	return f(ctx, t, stdout)
}

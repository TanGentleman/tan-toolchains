package node

import (
	"bufio"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// A Harness starts one run of an agent. The contract is JSON lines: fleetd
// writes {"type":"prompt"|"steer"|"abort","id","message"} to stdin (Pi's RPC
// shape) and records every stdout line verbatim without parsing it. Harness
// state that must survive a move to another node lives in Spec.State.
type Harness interface {
	Start(Spec) (Proc, error)
}

type Spec struct {
	Sid    string
	Work   string // working directory; not replicated
	State  string // harness-owned files, checkpointed and moved on handoff
	Stderr io.Writer
	Env    []string // extra NAME=VALUE for the harness, after Exec.Env
}

type Proc interface {
	Send(line []byte) error
	Lines() <-chan []byte // closed when the run ends
	Stop()                // close stdin, kill after a grace period
	Code() int            // exit code, valid once Lines is closed
}

// Exec runs a command. $FLEET_SID, $FLEET_STATE and $FLEET_WORK in Argv are
// expanded, and the same names are set in the environment.
type Exec struct {
	Argv []string
	Env  []string
}

func (h Exec) Start(s Spec) (Proc, error) {
	vars := map[string]string{"FLEET_SID": s.Sid, "FLEET_STATE": s.State, "FLEET_WORK": s.Work}
	argv := make([]string, len(h.Argv))
	for i, a := range h.Argv {
		argv[i] = os.Expand(a, func(k string) string {
			if v, ok := vars[k]; ok {
				return v
			}
			return "$" + k
		})
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = s.Work
	cmd.Env = append(append(os.Environ(), h.Env...), s.Env...)
	for k, v := range vars {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	cmd.Stderr = s.Stderr
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
	p := newProc(stdin, func() { cmd.Process.Kill() })
	go p.read(stdout, func() int {
		err := cmd.Wait()
		if ee := (*exec.ExitError)(nil); errors.As(err, &ee) {
			return ee.ExitCode()
		}
		if err != nil {
			return -1
		}
		return 0
	})
	return p, nil
}

// Func runs a harness in-process; tests use it with fake.Run. An error that
// has an ExitCode() int method sets the run's exit code.
type Func func(stdin io.Reader, stdout io.Writer, state string) error

func (f Func) Start(s Spec) (Proc, error) {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	code := make(chan int, 1)
	go func() {
		err := f(inR, outW, s.State)
		c := 0
		if ec, ok := err.(interface{ ExitCode() int }); ok {
			c = ec.ExitCode()
		} else if err != nil {
			c = 1
		}
		code <- c
		inR.Close()
		outW.Close()
	}()
	p := newProc(inW, func() { inR.CloseWithError(errors.New("killed")) })
	go p.read(outR, func() int { return <-code })
	return p, nil
}

type proc struct {
	mu    sync.Mutex
	stdin io.WriteCloser
	kill  func()
	lines chan []byte
	done  chan struct{}
	code  int
}

func newProc(stdin io.WriteCloser, kill func()) *proc {
	return &proc{stdin: stdin, kill: kill, lines: make(chan []byte, 1024), done: make(chan struct{})}
}

func (p *proc) read(r io.Reader, wait func() int) {
	br := bufio.NewReaderSize(r, 1<<16)
	for {
		line, err := br.ReadBytes('\n')
		if s := strings.TrimRight(string(line), "\r\n"); s != "" {
			p.lines <- []byte(s)
		}
		if err != nil {
			break
		}
	}
	p.code = wait()
	close(p.done)
	close(p.lines)
}

func (p *proc) Send(line []byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, err := p.stdin.Write(append(append([]byte(nil), line...), '\n'))
	return err
}

func (p *proc) Lines() <-chan []byte { return p.lines }
func (p *proc) Code() int            { return p.code }

func (p *proc) Stop() {
	p.mu.Lock()
	p.stdin.Close()
	p.mu.Unlock()
	select {
	case <-p.done:
	case <-time.After(5 * time.Second):
		p.kill()
	}
}

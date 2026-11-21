// Package harness drives agent loops. fleetd records every byte a harness
// emits (Out.Raw) and the normalized events derived from it (Out.Events);
// the normalized view can always be rebuilt from the raw bytes.
package harness

import (
	"context"
	"fmt"
)

type Spec struct {
	Sid    string
	Work   string // working directory for the agent
	Native string // directory holding the harness's own session files
	Resume bool   // native files exist from an earlier run
}

type Input struct {
	Key  string `json:"key"`
	Kind string `json:"kind"` // prompt | steer | cancel
	Text string `json:"text,omitempty"`
}

type Event struct {
	Kind string `json:"kind"`
	Data any    `json:"data,omitempty"`
}

// Out is one chunk of harness output: raw bytes plus what they mean.
type Out struct {
	Raw    []byte
	Events []Event
}

type Proc interface {
	Send(Input) error
	Out() <-chan Out // closed when the harness exits
	Close() error    // stop and wait; native files are complete afterwards
}

type Harness interface {
	Start(ctx context.Context, s Spec) (Proc, error)
	NativeFiles() []string // names under Spec.Native to checkpoint
}

type Registry map[string]Harness

func (r Registry) Get(name string) (Harness, error) {
	h, ok := r[name]
	if !ok {
		return nil, fmt.Errorf("unknown harness %q", name)
	}
	return h, nil
}

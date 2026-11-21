// Package journal is a per-session append-only event log.
//
// Invariants:
//   - Events are numbered 1..n with no gaps; a line is never rewritten.
//   - Readers only see the durable prefix (events covered by an fsync).
//   - An input's idempotency key lives inside its event, so the dedupe set
//     is rebuilt from the log and can never be ahead of it.
//   - A torn final line (crash mid-write) is truncated on open.
package journal

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"time"
)

type Event struct {
	V    int             `json:"v"`
	Sid  string          `json:"sid"`
	Seq  uint64          `json:"seq"`
	Run  int             `json:"run"`
	Node string          `json:"node"`
	T    string          `json:"t"`
	By   string          `json:"by,omitempty"`
	Kind string          `json:"kind"`
	Key  string          `json:"key,omitempty"`
	Data json.RawMessage `json:"data,omitempty"`
	Raw  *RawRef         `json:"raw,omitempty"`
}

// RawRef points at the harness's native bytes in raw-<run>.log.
type RawRef struct {
	Run int   `json:"run"`
	Off int64 `json:"off"`
	Len int   `json:"len"`
}

var ErrDiverged = errors.New("journal: replica diverged from source")

type Journal struct {
	dir string

	mu      sync.Mutex
	f       *os.File
	raw     *os.File
	rawRun  int
	rawOff  int64
	lines   [][]byte // lines[i] is event seq i+1, without newline
	events  []Event
	durable uint64
	dirty   bool
	keys    map[string]uint64 // scoped key -> seq
	changed chan struct{}
	closed  bool
	err     error

	sync time.Duration
	stop chan struct{}
	done chan struct{}
}

// Open loads dir/events.jsonl, truncating a torn tail, and starts group commit.
func Open(dir string, syncEvery time.Duration) (*Journal, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(dir+"/events.jsonl", os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return nil, err
	}
	j := &Journal{dir: dir, f: f, keys: map[string]uint64{}, changed: make(chan struct{}),
		sync: syncEvery, stop: make(chan struct{}), done: make(chan struct{})}
	if err := j.load(); err != nil {
		f.Close()
		return nil, err
	}
	j.durable = uint64(len(j.events))
	go j.loop()
	return j, nil
}

func (j *Journal) load() error {
	data, err := io.ReadAll(j.f)
	if err != nil {
		return err
	}
	var good int64
	for len(data) > 0 {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			break // torn tail
		}
		line := data[:i]
		var e Event
		if err := json.Unmarshal(line, &e); err != nil || e.Seq != uint64(len(j.events)+1) {
			break
		}
		j.index(append([]byte(nil), line...), e)
		good += int64(i + 1)
		data = data[i+1:]
	}
	if err := j.f.Truncate(good); err != nil {
		return err
	}
	_, err = j.f.Seek(good, io.SeekStart)
	return err
}

func (j *Journal) index(line []byte, e Event) {
	j.lines = append(j.lines, line)
	j.events = append(j.events, e)
	if e.Key != "" {
		j.keys[e.Kind+"/"+e.By+"/"+e.Key] = e.Seq
	}
}

func (j *Journal) loop() {
	defer close(j.done)
	t := time.NewTicker(j.sync)
	defer t.Stop()
	for {
		select {
		case <-j.stop:
			j.flush()
			return
		case <-t.C:
			j.flush()
		}
	}
}

// flush fsyncs raw bytes first, then events, then advances the watermark.
func (j *Journal) flush() {
	j.mu.Lock()
	if !j.dirty || j.err != nil {
		j.mu.Unlock()
		return
	}
	n := uint64(len(j.events))
	raw := j.raw
	j.dirty = false
	j.mu.Unlock()

	var err error
	if raw != nil {
		err = raw.Sync()
	}
	if err == nil {
		err = j.f.Sync() // F_FULLFSYNC on darwin
	}

	j.mu.Lock()
	defer j.mu.Unlock()
	if err != nil {
		j.err = fmt.Errorf("journal: fsync: %w", err)
	} else if n > j.durable {
		j.durable = n
	}
	close(j.changed)
	j.changed = make(chan struct{})
}

// Append assigns the next seq to e and writes it. If e.Key is set and an
// event of the same kind, author and key exists, it returns that event's seq
// and dup=true without writing. The event is not visible until durable.
func (j *Journal) Append(e Event, raw []byte) (seq uint64, dup bool, err error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.closed {
		return 0, false, errors.New("journal: closed")
	}
	if j.err != nil {
		return 0, false, j.err
	}
	if e.Key != "" {
		if s, ok := j.keys[e.Kind+"/"+e.By+"/"+e.Key]; ok {
			return s, true, nil
		}
	}
	if raw != nil {
		ref, err := j.writeRaw(e.Run, raw)
		if err != nil {
			return 0, false, err
		}
		e.Raw = ref
	}
	e.V = 1
	e.Seq = uint64(len(j.events) + 1)
	if e.T == "" {
		e.T = time.Now().UTC().Format(time.RFC3339Nano)
	}
	line, err := json.Marshal(e)
	if err != nil {
		return 0, false, err
	}
	if _, err := j.f.Write(append(line, '\n')); err != nil {
		j.err = err
		return 0, false, err
	}
	j.index(line, e)
	j.dirty = true
	return e.Seq, false, nil
}

// AppendReplica appends an event line copied from the session's owner. The
// line is stored byte for byte so replicas stay comparable.
func (j *Journal) AppendReplica(line []byte) error {
	var e Event
	if err := json.Unmarshal(line, &e); err != nil {
		return err
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	n := uint64(len(j.events))
	if e.Seq <= n {
		if !bytes.Equal(j.lines[e.Seq-1], line) {
			return fmt.Errorf("%w at seq %d", ErrDiverged, e.Seq)
		}
		return nil
	}
	if e.Seq != n+1 {
		return fmt.Errorf("journal: replica gap: have %d, got %d", n, e.Seq)
	}
	if _, err := j.f.Write(append(append([]byte(nil), line...), '\n')); err != nil {
		j.err = err
		return err
	}
	j.index(append([]byte(nil), line...), e)
	j.dirty = true
	return nil
}

func (j *Journal) writeRaw(run int, b []byte) (*RawRef, error) {
	if j.raw == nil || j.rawRun != run {
		if j.raw != nil {
			j.raw.Sync()
			j.raw.Close()
		}
		f, err := os.OpenFile(fmt.Sprintf("%s/raw-%d.log", j.dir, run), os.O_RDWR|os.O_CREATE|os.O_APPEND, 0o644)
		if err != nil {
			return nil, err
		}
		st, err := f.Stat()
		if err != nil {
			f.Close()
			return nil, err
		}
		j.raw, j.rawRun, j.rawOff = f, run, st.Size()
	}
	ref := &RawRef{Run: run, Off: j.rawOff, Len: len(b)}
	if _, err := j.raw.Write(b); err != nil {
		return nil, err
	}
	j.rawOff += int64(len(b))
	return ref, nil
}

// ReadRaw returns the native bytes an event points at.
func (j *Journal) ReadRaw(r RawRef) ([]byte, error) {
	f, err := os.Open(fmt.Sprintf("%s/raw-%d.log", j.dir, r.Run))
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b := make([]byte, r.Len)
	_, err = f.ReadAt(b, r.Off)
	return b, err
}

// WaitDurable blocks until seq is durable.
func (j *Journal) WaitDurable(ctx context.Context, seq uint64) error {
	for {
		j.mu.Lock()
		d, ch, err := j.durable, j.changed, j.err
		j.mu.Unlock()
		if err != nil {
			return err
		}
		if d >= seq {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ch:
		}
	}
}

// Read returns durable events with seq > after, at most limit (0 = all),
// plus a channel closed when more may be available.
func (j *Journal) Read(after uint64, limit int) ([]Event, [][]byte, <-chan struct{}) {
	j.mu.Lock()
	defer j.mu.Unlock()
	end := j.durable
	if after >= end {
		return nil, nil, j.changed
	}
	if limit > 0 && end-after > uint64(limit) {
		end = after + uint64(limit)
	}
	return append([]Event(nil), j.events[after:end]...), append([][]byte(nil), j.lines[after:end]...), j.changed
}

// Head is the durable seq.
func (j *Journal) Head() uint64 {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.durable
}

// All returns every durable event.
func (j *Journal) All() []Event {
	ev, _, _ := j.Read(0, 0)
	return ev
}

// Close flushes and closes. Pending appends become durable first.
func (j *Journal) Close() error {
	j.mu.Lock()
	if j.closed {
		j.mu.Unlock()
		return nil
	}
	j.closed = true
	j.mu.Unlock()
	close(j.stop)
	<-j.done
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.raw != nil {
		j.raw.Close()
	}
	return j.f.Close()
}

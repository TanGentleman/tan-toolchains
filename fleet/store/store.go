// Package store keeps event logs and blobs on local disk.
//
// A Log is one append-only file of newline-terminated lines. Append returns
// only after the lines are fsynced, and readers only ever see lines that
// Append has returned, so nothing visible can be lost in a crash. A torn
// final line left by a crash (no newline yet) is cut off on Open. A complete
// line that the caller rejects is never cut: Open refuses the file instead,
// so a rule change can't silently drop the history after it.
package store

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
)

type Log struct {
	mu      sync.Mutex
	f       *os.File
	lines   [][]byte
	changed chan struct{}
	err     error
}

// Open loads path. It cuts a torn final line, and returns an error, leaving
// the file untouched, if valid rejects any complete line.
func Open(path string, valid func(line []byte) error) (*Log, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	data, err := io.ReadAll(f)
	if err != nil {
		f.Close()
		return nil, err
	}
	l := &Log{f: f, changed: make(chan struct{})}
	var good int64
	for n := 1; ; n++ {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			break
		}
		if err := valid(data[:i]); err != nil {
			f.Close()
			return nil, fmt.Errorf("%s line %d: %w", path, n, err)
		}
		l.lines = append(l.lines, append([]byte(nil), data[:i]...))
		good += int64(i + 1)
		data = data[i+1:]
	}
	if len(data) > 0 {
		if err := f.Truncate(good); err == nil {
			err = f.Sync()
		}
		if err != nil {
			f.Close()
			return nil, err
		}
	}
	if _, err := f.Seek(good, io.SeekStart); err != nil {
		f.Close()
		return nil, err
	}
	return l, nil
}

// Append writes lines and fsyncs them before making them visible. After a
// write or sync error the log refuses further appends; reopen to recover.
func (l *Log) Append(lines ...[]byte) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.err != nil {
		return l.err
	}
	var buf bytes.Buffer
	for _, ln := range lines {
		if bytes.IndexByte(ln, '\n') >= 0 {
			return errors.New("store: line contains a newline")
		}
		buf.Write(ln)
		buf.WriteByte('\n')
	}
	if _, err := l.f.Write(buf.Bytes()); err != nil {
		l.err = err
		return err
	}
	if err := l.f.Sync(); err != nil {
		l.err = fmt.Errorf("store: fsync: %w", err)
		return l.err
	}
	for _, ln := range lines {
		l.lines = append(l.lines, append([]byte(nil), ln...))
	}
	close(l.changed)
	l.changed = make(chan struct{})
	return nil
}

// Read returns lines after the first `after`, and a channel that is closed
// on the next Append.
func (l *Log) Read(after uint64) ([][]byte, <-chan struct{}) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if after >= uint64(len(l.lines)) {
		return nil, l.changed
	}
	return l.lines[after:len(l.lines):len(l.lines)], l.changed
}

func (l *Log) Len() uint64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return uint64(len(l.lines))
}

func (l *Log) Close() error { return l.f.Close() }

// Blobs is a content-addressed directory: each file is named by its SHA-256.
type Blobs struct{ Dir string }

func (b Blobs) Path(sha string) string { return filepath.Join(b.Dir, sha) }

// Put copies r into the store and returns its hash and size.
func (b Blobs) Put(r io.Reader) (string, int64, error) {
	if err := os.MkdirAll(b.Dir, 0o700); err != nil {
		return "", 0, err
	}
	tmp, err := os.CreateTemp(b.Dir, ".tmp-*")
	if err != nil {
		return "", 0, err
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, h), r)
	if err == nil {
		err = tmp.Sync()
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return "", 0, err
	}
	sha := hex.EncodeToString(h.Sum(nil))
	return sha, n, os.Rename(tmp.Name(), b.Path(sha))
}

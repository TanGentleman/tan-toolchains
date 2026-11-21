package node

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/core"
)

// LoginHeader carries the caller's identity. `tailscale serve` sets it on
// every tailnet request and strips any value the client sent, so fleetd
// trusts it only because it listens on loopback behind serve. Node-to-node
// calls set it too: through serve it is replaced by the calling device's
// user, and in local tests it passes through unchanged.
const LoginHeader = "Tailscale-User-Login"

type httpError struct {
	Status int
	Msg    string
}

func (e *httpError) Error() string { return fmt.Sprintf("peer: %d %s", e.Status, e.Msg) }

func (n *Node) call(ctx context.Context, method, url, login string, body, out any) error {
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, r)
	if err != nil {
		return err
	}
	req.Header.Set(LoginHeader, login)
	req.Header.Set("Content-Type", "application/json")
	resp, err := n.cfg.Client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUnreachable, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 500 {
		return fmt.Errorf("%w: %s", ErrUnreachable, resp.Status)
	}
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return &httpError{resp.StatusCode, string(bytes.TrimSpace(b))}
	}
	if out == nil {
		return nil
	}
	if w, ok := out.(io.Writer); ok {
		_, err = io.Copy(w, resp.Body)
		return err
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// Pull copies sid's events from base after the local head, byte for byte,
// then the blobs of its latest checkpoint. Events are checked with
// core.Apply, so a copy can fall behind but never accept a line the writer
// could not have written.
func (n *Node) Pull(ctx context.Context, base, sid, login string) error {
	s, err := n.open(sid)
	if err != nil {
		return err
	}
	for {
		s.mu.Lock()
		head := s.st.Head
		s.mu.Unlock()
		var body bytes.Buffer
		if err := n.call(ctx, http.MethodGet, fmt.Sprintf("%s/v1/sessions/%s/events?after=%d&limit=5000", base, sid, head), login, nil, &body); err != nil {
			return err
		}
		got, err := n.appendCopied(s, body.Bytes())
		if err != nil {
			return err
		}
		if got < 5000 {
			break
		}
	}
	s.mu.Lock()
	files := s.st.Files
	s.mu.Unlock()
	for _, f := range files {
		if n.blobs.Has(f.Sha) {
			continue
		}
		var b bytes.Buffer
		if err := n.call(ctx, http.MethodGet, base+"/v1/blobs/"+f.Sha, login, nil, &b); err != nil {
			return err
		}
		if err := n.blobs.PutVerified(f.Sha, &b); err != nil {
			return err
		}
	}
	return nil
}

func (n *Node) appendCopied(s *session, body []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.broken != nil {
		return 0, s.broken
	}
	var lines [][]byte
	count := 0
	sc := bufio.NewScanner(bytes.NewReader(body))
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		line := append([]byte(nil), sc.Bytes()...)
		count++
		var e core.Event
		if err := json.Unmarshal(line, &e); err != nil {
			return 0, err
		}
		if e.Seq <= s.st.Head {
			have, _ := s.log.Read(e.Seq - 1)
			if len(have) == 0 || !bytes.Equal(have[0], line) {
				return 0, fmt.Errorf("%w at seq %d", ErrDiverged, e.Seq)
			}
			continue
		}
		if err := s.apply(e); err != nil {
			s.broken = err
			return 0, err
		}
		lines = append(lines, line)
	}
	if err := sc.Err(); err != nil {
		return 0, err
	}
	if len(lines) > 0 {
		if err := s.log.Append(lines...); err != nil {
			s.broken = err
			return 0, err
		}
	}
	return count, nil
}

// PullAll copies every session base lists whose head is ahead of ours.
func (n *Node) PullAll(ctx context.Context, base string) error {
	var list []Summary
	if err := n.call(ctx, http.MethodGet, base+"/v1/sessions", n.cfg.PeerLogin, nil, &list); err != nil {
		return err
	}
	var errs []error
	for _, r := range list {
		if s := n.get(r.Sid); s != nil {
			s.mu.Lock()
			head := s.st.Head
			s.mu.Unlock()
			if head >= r.Head {
				continue
			}
		}
		if err := n.Pull(ctx, base, r.Sid, n.cfg.PeerLogin); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", r.Sid, err))
		}
	}
	return errors.Join(errs...)
}

func (n *Node) pullLoop() {
	defer n.wg.Done()
	t := time.NewTicker(n.cfg.PullEvery)
	defer t.Stop()
	for {
		select {
		case <-n.stop:
			return
		case <-t.C:
		}
		for _, p := range n.cfg.Peers {
			ctx, cancel := context.WithTimeout(context.Background(), n.cfg.PullEvery*5)
			n.PullAll(ctx, p)
			cancel()
		}
	}
}

package node

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// Nodes copy each other's sessions by pulling; a node never pushes. A
// session's writer never pulls it, and copied lines must match byte for byte.

func (n *Node) pullLoop() {
	defer n.wg.Done()
	t := time.NewTicker(n.cfg.PullEvery)
	defer t.Stop()
	for {
		ctx, cancel := context.WithTimeout(context.Background(), n.cfg.PullEvery*5)
		n.PullOnce(ctx)
		cancel()
		select {
		case <-n.stop:
			return
		case <-t.C:
		}
	}
}

func (n *Node) PullOnce(ctx context.Context) {
	for _, base := range n.cfg.Peers {
		if err := n.pullPeer(ctx, base); err != nil && ctx.Err() == nil {
			log.Printf("pull %s: %v", base, err)
		}
	}
}

func (n *Node) pullPeer(ctx context.Context, base string) error {
	var info struct {
		Name string `json:"name"`
	}
	if err := n.peerJSON(ctx, "GET", base+"/v1/node", nil, &info); err != nil {
		return err
	}
	n.mu.Lock()
	n.peerURL[info.Name] = base
	n.mu.Unlock()
	var metas []Meta
	if err := n.peerJSON(ctx, "GET", base+"/v1/sessions", nil, &metas); err != nil {
		return err
	}
	for _, m := range metas {
		if s := n.get(m.Sid); s != nil {
			if s.j.Head() >= m.Head {
				continue
			}
			if lm := s.Meta(); lm.Node == n.cfg.Name && lm.State != "sealed" {
				continue // we are the writer
			}
		}
		if err := n.pullSession(ctx, base, m.Sid); err != nil {
			log.Printf("pull %s from %s: %v", m.Sid, info.Name, err)
		}
	}
	return nil
}

func (n *Node) pullSession(ctx context.Context, base, sid string) error {
	s, err := n.open(sid)
	if err != nil {
		return err
	}
	for {
		head := s.j.Head()
		resp, err := n.peerDo(ctx, "GET", fmt.Sprintf("%s/v1/sessions/%s/events?after=%d&limit=1000", base, sid, head), nil)
		if err != nil {
			return err
		}
		var got, last uint64
		sc := bufio.NewScanner(resp.Body)
		sc.Buffer(make([]byte, 1<<20), 64<<20)
		for sc.Scan() {
			if err := s.j.AppendReplica(sc.Bytes()); err != nil {
				resp.Body.Close()
				return err
			}
			got++
			var e struct {
				Seq uint64 `json:"seq"`
			}
			json.Unmarshal(sc.Bytes(), &e)
			last = e.Seq
		}
		resp.Body.Close()
		if err := sc.Err(); err != nil {
			return err
		}
		if got == 0 {
			break
		}
		if err := s.j.WaitDurable(ctx, last); err != nil {
			return err
		}
		if got < 1000 {
			break
		}
	}
	m := s.Meta()
	for _, f := range m.Checkpoint {
		if err := n.pullBlob(ctx, base, f.Sha); err != nil {
			return err
		}
	}
	for run, end := range m.MaxRaw {
		if err := n.pullRaw(ctx, base, s, run, end); err != nil {
			return err
		}
	}
	return nil
}

func (n *Node) pullBlob(ctx context.Context, base, sha string) error {
	if _, err := os.Stat(n.blobPath(sha)); err == nil {
		return nil
	}
	resp, err := n.peerDo(ctx, "GET", base+"/v1/blobs/"+sha, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	got, err := n.putBlob(b)
	if err != nil {
		return err
	}
	if got != sha {
		os.Remove(n.blobPath(got))
		return fmt.Errorf("blob %s: content hashes to %s", sha, got)
	}
	return nil
}

// pullRaw copies raw harness bytes [local size, end) of one run.
func (n *Node) pullRaw(ctx context.Context, base string, s *Session, run int, end int64) error {
	path := filepath.Join(s.dir, fmt.Sprintf("raw-%d.log", run))
	var have int64
	if st, err := os.Stat(path); err == nil {
		have = st.Size()
	}
	if have >= end {
		return nil
	}
	resp, err := n.peerDo(ctx, "GET", fmt.Sprintf("%s/v1/sessions/%s/raw/%d?off=%d&end=%d", base, s.ID, run, have, end), nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if int64(len(b)) != end-have {
		return fmt.Errorf("raw %d: got %d bytes, want %d", run, len(b), end-have)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.WriteAt(b, have); err != nil {
		return err
	}
	return f.Sync()
}

func (n *Node) ownerURL(name string) (string, error) {
	n.mu.Lock()
	base, ok := n.peerURL[name]
	n.mu.Unlock()
	if !ok {
		return "", fmt.Errorf("%w: node %s is not a known peer", ErrUnreachable, name)
	}
	return base, nil
}

func (n *Node) peerDo(ctx context.Context, method, url string, body any) (*http.Response, error) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, rd)
	if err != nil {
		return nil, err
	}
	for k, v := range n.cfg.PeerHeader {
		req.Header[k] = v
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := n.cfg.Client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnreachable, err)
	}
	if resp.StatusCode/100 != 2 {
		msg := readAll(resp.Body)
		resp.Body.Close()
		return nil, &PeerError{Status: resp.StatusCode, Msg: string(bytes.TrimSpace(msg))}
	}
	return resp, nil
}

type PeerError struct {
	Status int
	Msg    string
}

func (e *PeerError) Error() string { return "peer: " + strconv.Itoa(e.Status) + " " + e.Msg }

func (n *Node) peerJSON(ctx context.Context, method, url string, body, out any) error {
	resp, err := n.peerDo(ctx, method, url, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// Forward sends a request to the session's writer on behalf of the caller.
func (n *Node) Forward(ctx context.Context, nodeName, path string, as, asDisplay string, body any, out any) error {
	base, err := n.ownerURL(nodeName)
	if err != nil {
		return err
	}
	b, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, "POST", base+path, bytes.NewReader(b))
	if err != nil {
		return err
	}
	for k, v := range n.cfg.PeerHeader {
		req.Header[k] = v
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Fleet-As", as)
	req.Header.Set("X-Fleet-As-Display", asDisplay)
	resp, err := n.cfg.Client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUnreachable, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return &PeerError{Status: resp.StatusCode, Msg: string(bytes.TrimSpace(readAll(resp.Body)))}
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

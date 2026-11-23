// Package fakeor is a deterministic stand-in for OpenRouter's chat
// completions API, the one Pi uses. It answers streaming or not, and
// records every request so tests can check what Pi sent.
//
// The reply names every distinct word matching Token found anywhere in the
// request body, so a test can prove a resumed session carried its history:
// the second turn's reply must still name the first turn's token. Each
// call reports 10 input and 5 output tokens.
package fakeor

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
)

var Token = regexp.MustCompile(`\bTOK[A-Z0-9]+\b`)

type Request struct {
	Method, Path string
	Authed       bool // carried "Authorization: Bearer <Key>"
	Model        string
	Stream       bool
	Tokens       []string
}

type Server struct {
	Key string // required bearer token

	mu   sync.Mutex
	reqs []Request
}

func (s *Server) Requests() []Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Request(nil), s.reqs...)
}

// Reply is the text answered for body, and the tokens it names.
func Reply(body []byte) (string, []string) {
	seen := map[string]bool{}
	for _, t := range Token.FindAll(body, -1) {
		seen[string(t)] = true
	}
	toks := make([]string, 0, len(seen))
	for t := range seen {
		toks = append(toks, t)
	}
	sort.Strings(toks)
	return "seen " + strings.Join(toks, " "), toks
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(io.LimitReader(r.Body, 64<<20))
	var in struct {
		Model  string `json:"model"`
		Stream bool   `json:"stream"`
	}
	json.Unmarshal(body, &in)
	text, toks := Reply(body)
	rec := Request{Method: r.Method, Path: r.URL.Path, Authed: r.Header.Get("Authorization") == "Bearer "+s.Key,
		Model: in.Model, Stream: in.Stream, Tokens: toks}
	s.mu.Lock()
	s.reqs = append(s.reqs, rec)
	s.mu.Unlock()

	if !rec.Authed {
		http.Error(w, `{"error":{"message":"no auth","code":401}}`, http.StatusUnauthorized)
		return
	}
	if r.Method != "POST" || !strings.HasSuffix(r.URL.Path, "/v1/chat/completions") {
		http.Error(w, `{"error":{"message":"not found","code":404}}`, http.StatusNotFound)
		return
	}
	usage := map[string]int{"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
	if !in.Stream {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"id": "chatcmpl-fake", "object": "chat.completion", "created": 0, "model": in.Model,
			"choices": []any{map[string]any{"index": 0, "finish_reason": "stop",
				"message": map[string]any{"role": "assistant", "content": text}}},
			"usage": usage,
		})
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	chunk := func(delta map[string]any, finish any, u any) {
		c := map[string]any{"id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": 0, "model": in.Model,
			"choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}}}
		if u != nil {
			c["usage"] = u
		}
		b, _ := json.Marshal(c)
		fmt.Fprintf(w, "data: %s\n\n", b)
	}
	chunk(map[string]any{"role": "assistant", "content": ""}, nil, nil)
	chunk(map[string]any{"content": text}, nil, nil)
	chunk(map[string]any{}, "stop", usage)
	fmt.Fprint(w, "data: [DONE]\n\n")
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

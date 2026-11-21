// Package fakeor is a deterministic stand-in for OpenRouter. It answers the
// three wire formats the supported CLIs use (Anthropic messages, OpenAI chat
// completions, OpenAI responses), streaming or not, and records every request
// so tests can check what each CLI sent and that nothing else was contacted.
//
// The reply names every distinct word matching Token found anywhere in the
// request body, so a test can prove a resumed session carried its history:
// the second turn's reply must still name the first turn's token.
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
	Auth         string // "bearer", "x-api-key", "bad" or ""
	Model        string
	Stream       bool
	Tokens       []string
}

type Server struct {
	Key string // required bearer token / x-api-key

	mu   sync.Mutex
	reqs []Request
}

func (s *Server) Requests() []Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Request(nil), s.reqs...)
}

func (s *Server) auth(r *http.Request) string {
	if a := r.Header.Get("Authorization"); a != "" {
		if a == "Bearer "+s.Key {
			return "bearer"
		}
		return "bad"
	}
	if k := r.Header.Get("X-Api-Key"); k != "" {
		if k == s.Key {
			return "x-api-key"
		}
		return "bad"
	}
	return ""
}

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
	rec := Request{Method: r.Method, Path: r.URL.Path, Auth: s.auth(r), Model: in.Model, Stream: in.Stream, Tokens: toks}
	s.mu.Lock()
	s.reqs = append(s.reqs, rec)
	s.mu.Unlock()

	if rec.Auth != "bearer" && rec.Auth != "x-api-key" {
		http.Error(w, `{"error":{"message":"no auth","code":401}}`, http.StatusUnauthorized)
		return
	}
	switch {
	case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/v1/messages"):
		anthropic(w, in.Model, in.Stream, text)
	case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/v1/chat/completions"):
		chat(w, in.Model, in.Stream, text)
	case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/v1/responses"):
		responses(w, in.Model, text)
	default:
		http.Error(w, `{"error":{"message":"not found","code":404}}`, http.StatusNotFound)
	}
}

type sse struct {
	w http.ResponseWriter
}

func newSSE(w http.ResponseWriter) sse {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	return sse{w}
}

func (s sse) send(event string, v any) {
	b, _ := json.Marshal(v)
	if event != "" {
		fmt.Fprintf(s.w, "event: %s\n", event)
	}
	fmt.Fprintf(s.w, "data: %s\n\n", b)
	if f, ok := s.w.(http.Flusher); ok {
		f.Flush()
	}
}

type m = map[string]any

func anthropic(w http.ResponseWriter, model string, stream bool, text string) {
	usage := m{"input_tokens": 10, "output_tokens": 5, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
	if !stream {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(m{"id": "msg_fake", "type": "message", "role": "assistant", "model": model,
			"content": []m{{"type": "text", "text": text}}, "stop_reason": "end_turn", "stop_sequence": nil, "usage": usage})
		return
	}
	s := newSSE(w)
	s.send("message_start", m{"type": "message_start", "message": m{"id": "msg_fake", "type": "message", "role": "assistant",
		"model": model, "content": []m{}, "stop_reason": nil, "stop_sequence": nil, "usage": m{"input_tokens": 10, "output_tokens": 0}}})
	s.send("content_block_start", m{"type": "content_block_start", "index": 0, "content_block": m{"type": "text", "text": ""}})
	s.send("content_block_delta", m{"type": "content_block_delta", "index": 0, "delta": m{"type": "text_delta", "text": text}})
	s.send("content_block_stop", m{"type": "content_block_stop", "index": 0})
	s.send("message_delta", m{"type": "message_delta", "delta": m{"stop_reason": "end_turn", "stop_sequence": nil}, "usage": m{"output_tokens": 5}})
	s.send("message_stop", m{"type": "message_stop"})
}

func chat(w http.ResponseWriter, model string, stream bool, text string) {
	usage := m{"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
	if !stream {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(m{"id": "chatcmpl-fake", "object": "chat.completion", "created": 0, "model": model,
			"choices": []m{{"index": 0, "message": m{"role": "assistant", "content": text}, "finish_reason": "stop"}}, "usage": usage})
		return
	}
	s := newSSE(w)
	chunk := func(delta m, finish any, u any) m {
		c := m{"id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": 0, "model": model,
			"choices": []m{{"index": 0, "delta": delta, "finish_reason": finish}}}
		if u != nil {
			c["usage"] = u
		}
		return c
	}
	s.send("", chunk(m{"role": "assistant", "content": ""}, nil, nil))
	s.send("", chunk(m{"content": text}, nil, nil))
	s.send("", chunk(m{}, "stop", usage))
	fmt.Fprint(w, "data: [DONE]\n\n")
}

func responses(w http.ResponseWriter, model, text string) {
	s := newSSE(w)
	item := func(status string, content []m) m {
		return m{"type": "message", "id": "msg_fake", "role": "assistant", "status": status, "content": content}
	}
	part := m{"type": "output_text", "text": text, "annotations": []m{}}
	resp := func(status string, output []m) m {
		return m{"id": "resp_fake", "object": "response", "created_at": 0, "status": status, "model": model, "output": output,
			"usage": m{"input_tokens": 10, "output_tokens": 5, "total_tokens": 15,
				"input_tokens_details": m{"cached_tokens": 0}, "output_tokens_details": m{"reasoning_tokens": 0}}}
	}
	s.send("response.created", m{"type": "response.created", "sequence_number": 0, "response": resp("in_progress", []m{})})
	s.send("response.output_item.added", m{"type": "response.output_item.added", "sequence_number": 1, "output_index": 0, "item": item("in_progress", []m{})})
	s.send("response.content_part.added", m{"type": "response.content_part.added", "sequence_number": 2, "item_id": "msg_fake", "output_index": 0, "content_index": 0, "part": m{"type": "output_text", "text": "", "annotations": []m{}}})
	s.send("response.output_text.delta", m{"type": "response.output_text.delta", "sequence_number": 3, "item_id": "msg_fake", "output_index": 0, "content_index": 0, "delta": text})
	s.send("response.output_text.done", m{"type": "response.output_text.done", "sequence_number": 4, "item_id": "msg_fake", "output_index": 0, "content_index": 0, "text": text})
	s.send("response.content_part.done", m{"type": "response.content_part.done", "sequence_number": 5, "item_id": "msg_fake", "output_index": 0, "content_index": 0, "part": part})
	s.send("response.output_item.done", m{"type": "response.output_item.done", "sequence_number": 6, "output_index": 0, "item": item("completed", []m{part})})
	s.send("response.completed", m{"type": "response.completed", "sequence_number": 7, "response": resp("completed", []m{item("completed", []m{part})})})
}

// Trap is an HTTP proxy that refuses everything and records where each
// request was going. Point HTTPS_PROXY/HTTP_PROXY at it (with NO_PROXY
// covering the fake) and any traffic besides model calls shows up here.
type Trap struct {
	mu    sync.Mutex
	hosts []string
}

func (t *Trap) Hosts() []string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return append([]string(nil), t.hosts...)
}

func (t *Trap) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	t.mu.Lock()
	t.hosts = append(t.hosts, r.Host)
	t.mu.Unlock()
	http.Error(w, "blocked by fakeor.Trap", http.StatusForbidden)
}

package fakeor

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func post(t *testing.T, url, path, auth, body string) (int, string) {
	req, _ := http.NewRequest("POST", url+path, strings.NewReader(body))
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(b)
}

func TestServer(t *testing.T) {
	s := &Server{Key: "k"}
	srv := httptest.NewServer(s)
	defer srv.Close()
	body := `{"model":"m","stream":%s,"messages":[{"role":"user","content":"x TOKB TOKA TOKB"}]}`
	for _, c := range []struct{ stream, want string }{
		{"false", `"content":"seen TOKA TOKB"`},
		{"true", "data: [DONE]"},
	} {
		code, out := post(t, srv.URL, "/api/v1/chat/completions", "Bearer k", strings.Replace(body, "%s", c.stream, 1))
		if code != 200 || !strings.Contains(out, c.want) || !strings.Contains(out, `"prompt_tokens":10`) {
			t.Errorf("stream=%s: %d %q", c.stream, code, out)
		}
	}
	for _, auth := range []string{"Bearer wrong", ""} {
		if code, _ := post(t, srv.URL, "/api/v1/chat/completions", auth, `{}`); code != 401 {
			t.Errorf("auth %q: %d", auth, code)
		}
	}
	if code, _ := post(t, srv.URL, "/v1/messages", "Bearer k", `{}`); code != 404 {
		t.Errorf("other API: %d", code)
	}
	r := s.Requests()
	if len(r) != 5 || r[0].Model != "m" || !r[1].Stream || strings.Join(r[0].Tokens, ",") != "TOKA,TOKB" || r[2].Authed || !r[4].Authed {
		t.Errorf("recorded: %+v", r)
	}
}

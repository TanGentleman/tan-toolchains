package fakeor

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func post(t *testing.T, url, path, hdr, val, body string) (int, string) {
	req, _ := http.NewRequest("POST", url+path, strings.NewReader(body))
	if hdr != "" {
		req.Header.Set(hdr, val)
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
	for _, c := range []struct{ path, stream, want string }{
		{"/v1/messages", "false", `"text":"seen TOKA TOKB"`},
		{"/v1/messages", "true", "event: message_stop"},
		{"/api/v1/chat/completions", "false", `"content":"seen TOKA TOKB"`},
		{"/api/v1/chat/completions", "true", "data: [DONE]"},
		{"/api/v1/responses", "true", "response.completed"},
	} {
		code, out := post(t, srv.URL, c.path, "Authorization", "Bearer k", strings.Replace(body, "%s", c.stream, 1))
		if code != 200 || !strings.Contains(out, c.want) {
			t.Errorf("%s stream=%s: %d %q", c.path, c.stream, code, out)
		}
	}
	if code, _ := post(t, srv.URL, "/v1/messages", "X-Api-Key", "k", `{}`); code != 200 {
		t.Errorf("x-api-key: %d", code)
	}
	for _, c := range [][2]string{{"Authorization", "Bearer wrong"}, {"X-Api-Key", "wrong"}, {"", ""}} {
		if code, _ := post(t, srv.URL, "/v1/messages", c[0], c[1], `{}`); code != 401 {
			t.Errorf("auth %v: %d", c, code)
		}
	}
	if code, _ := post(t, srv.URL, "/v1/embeddings", "Authorization", "Bearer k", `{}`); code != 404 {
		t.Errorf("unknown path: %d", code)
	}
	if code, _ := post(t, srv.URL, "/v1/messages", "Authorization", "Bearer k", `not json TOKZ`); code != 200 {
		t.Errorf("malformed body: %d", code)
	}
	r := s.Requests()
	if len(r) != 11 || r[0].Model != "m" || r[1].Stream != true || strings.Join(r[0].Tokens, ",") != "TOKA,TOKB" || r[6].Auth != "bad" {
		t.Errorf("recorded: %+v", r)
	}
}

func TestTrap(t *testing.T) {
	tr := &Trap{}
	srv := httptest.NewServer(tr)
	defer srv.Close()
	res, err := http.Get(srv.URL + "/x")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 403 || len(tr.Hosts()) != 1 {
		t.Fatalf("%d %v", res.StatusCode, tr.Hosts())
	}
}

"""gateway.py against a fake backend."""
import http.client
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import gateway

REPLY = ('<|message_model|><|content_thinking|>Need weather.<|end_message|>'
         '<|message_model|>get_weather<|content_invoke_tool_json|>'
         '{"name":"get_weather","args":{"city":"Paris"}}<|end_message|><|content_model_end_sampling|>')
TEXT = '<|message_model|><|content_thinking|>hm<|end_message|><|message_model|><|content_text|>Hello there<|end_message|>'


class Fake(BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Fake.seen.append(body)
        reply = REPLY if body.get("tools") else TEXT
        self.send_response(200)
        if not body.get("stream"):
            data = json.dumps({"choices": [{"index": 0, "message": {"role": "assistant", "content": reply},
                                            "finish_reason": "stop"}], "usage": {"completion_tokens": 9}}).encode()
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            return self.wfile.write(data)
        self.end_headers()
        for i in range(0, len(reply), 5):  # split markers across chunks
            d = {"choices": [{"index": 0, "delta": {"content": reply[i:i + 5]}, "finish_reason": None}]}
            self.wfile.write(b"data: " + json.dumps(d).encode() + b"\n\n")
        d = {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
        self.wfile.write(b"data: " + json.dumps(d).encode() + b"\n\ndata: [DONE]\n\n")


def serve(handler):
    s = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s.server_address[1]


class T(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        handler = type("H", (gateway.Handler,), {"upstream": ("127.0.0.1", serve(Fake)), "parser": "inkling",
                                                 "upstream_model": "default_model", "model_name": "m1"})
        cls.handler, cls.port = handler, serve(handler)

    def post(self, path, body, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("POST", path, json.dumps(body), {"Content-Type": "application/json", **(headers or {})})
        return c.getresponse()

    def test_log_has_session_not_text(self):
        with tempfile.TemporaryDirectory() as d:
            self.handler.log_file = os.path.join(d, "requests.jsonl")
            try:
                for sid in ("0198c5a2-7d1e-7abc-9def-0123456789ab", "bad id\"x", "a" * 129, None):
                    self.post("/api/v1/chat/completions",
                              {"stream": True, "messages": [{"role": "user", "content": "SECRET-PROMPT"}]},
                              {"x-session-id": sid} if sid else {}).read()
                with open(self.handler.log_file) as f:
                    text = f.read()
            finally:
                self.handler.log_file = None
        recs = [json.loads(l) for l in text.splitlines()]
        self.assertEqual([r.get("session") for r in recs],
                         ["0198c5a2-7d1e-7abc-9def-0123456789ab", None, None, None])
        self.assertNotIn("SECRET-PROMPT", text)
        self.assertNotIn("Hello there", text)
        self.assertTrue(all("ttft_ms" in r for r in recs))

    def test_tool_call_whole(self):
        r = self.post("/api/v1/chat/completions", {"model": "client/name", "tools": [{}],
                      "reasoning": {"effort": "low"}, "provider": {}, "messages": []})
        d = json.loads(r.read())
        c = d["choices"][0]
        self.assertEqual(c["finish_reason"], "tool_calls")
        self.assertEqual(c["message"]["reasoning_content"], "Need weather.")
        self.assertIsNone(c["message"]["content"])
        self.assertEqual(c["message"]["tool_calls"][0]["function"],
                         {"name": "get_weather", "arguments": '{"city": "Paris"}'})
        self.assertEqual(d["model"], "client/name")
        up = Fake.seen[-1]
        self.assertEqual(up["chat_template_kwargs"], {"reasoning_effort": "low"})
        self.assertNotIn("provider", up)
        self.assertEqual(up["model"], "default_model")

    def test_stream(self):
        for body, want in (({"tools": [{}]}, "tool_calls"), ({}, "stop")):
            r = self.post("/v1/chat/completions", {"stream": True, "messages": [], **body})
            chunks = [json.loads(l[6:]) for l in r if l.startswith(b"data: {")]
            deltas = [c["choices"][0]["delta"] for c in chunks]
            self.assertEqual(deltas[0]["role"], "assistant")
            self.assertEqual(chunks[-1]["choices"][0]["finish_reason"], want)
            text = "".join(d.get("content") or "" for d in deltas)
            calls = [t for d in deltas for t in d.get("tool_calls", [])]
            self.assertNotIn("<|", text)
            if want == "stop":
                self.assertEqual(text, "Hello there")
            else:
                self.assertEqual([c["function"]["name"] for c in calls], ["get_weather"])

    def test_parser_none_passes_through(self):
        self.handler.parser, self.handler.upstream_model = "none", None
        try:
            r = self.post("/v1/chat/completions", {"tools": [{}], "reasoning": {"effort": "low"}, "messages": []})
            d = json.loads(r.read())
            s = self.post("/v1/chat/completions", {"stream": True, "messages": []})
            text = "".join(json.loads(l[6:])["choices"][0]["delta"].get("content") or ""
                           for l in s if l.startswith(b"data: {"))
        finally:
            self.handler.parser, self.handler.upstream_model = "inkling", "default_model"
        self.assertEqual(d["choices"][0]["message"]["content"], REPLY)
        self.assertEqual(d["model"], "m1")
        up = Fake.seen[-2]
        self.assertEqual((up["reasoning_effort"], "chat_template_kwargs" in up, "model" in up), ("low", False, False))
        self.assertEqual(text, TEXT)

    def test_get(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        for p, code in (("/health", 200), ("/api/v1/models", 200), ("/api/v1/key", 200), ("/x", 404)):
            c.request("GET", p)
            r = c.getresponse()
            body = json.loads(r.read())
            self.assertEqual(r.status, code, p)
            if p.endswith("models"):
                self.assertEqual(body["data"][0]["id"], "m1")


if __name__ == "__main__":
    unittest.main()

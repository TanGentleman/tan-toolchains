"""Fake OpenAI-compatible model: asks for one bash call, then replies with its output."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, COMMAND = int(sys.argv[1]), sys.argv[2]
USAGE = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}


class Model(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        results = [m for m in body.get("messages", []) if m.get("role") == "tool"]
        if results:
            content = results[-1]["content"]
            text = content if isinstance(content, str) else json.dumps(content)
            delta, finish = {"role": "assistant", "content": "tool said: " + text}, "stop"
        else:
            call = {"index": 0, "id": "call_1", "type": "function",
                    "function": {"name": "bash", "arguments": json.dumps({"command": COMMAND})}}
            delta, finish = {"role": "assistant", "content": None, "tool_calls": [call]}, "tool_calls"
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for choice in ({"index": 0, "delta": delta}, {"index": 0, "delta": {}, "finish_reason": finish}):
                chunk = {"id": "x", "object": "chat.completion.chunk", "created": 0, "model": "m",
                         "choices": [choice], "usage": USAGE}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            return
        out = json.dumps({"id": "x", "object": "chat.completion", "created": 0, "model": "m", "usage": USAGE,
                          "choices": [{"index": 0, "message": delta, "finish_reason": finish}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", PORT), Model).serve_forever()

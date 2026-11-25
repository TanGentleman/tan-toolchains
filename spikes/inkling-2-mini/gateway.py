#!/usr/bin/env python3
"""OpenAI-compatible gateway in front of mlx_lm.server for Inkling 2 Mini.

mlx_lm.server returns Inkling's message markup as plain content. This turns it
into reasoning_content, content and tool_calls, maps reasoning effort to the
chat template, and logs one JSON line per request (no prompt or reply text).
Stdlib only."""
import argparse
import errno
import http.client
import json
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MSG, END, BODY = "<|message_model|>", "<|end_message|>", "<|content_"
EOS = "<|content_model_end_sampling|>"
EFFORTS = {"none", "minimal", "low", "medium", "high", "xhigh", "max"}
DROP = ("provider", "transforms", "models", "route", "usage", "plugins")


class Parser:
    """Streaming parser for <|message_model|>[name]<|content_KIND|>...<|end_message|>."""

    def __init__(self):
        self.buf, self.state, self.kind, self.header, self.tool = "", "out", None, "", ""

    def feed(self, text):
        out = []
        self.buf += text
        while self.buf:
            i = self.buf.find("<|")
            if i == -1:
                keep = 1 if self.buf.endswith("<") else 0
                self._text(self.buf[: len(self.buf) - keep], out)
                self.buf = self.buf[len(self.buf) - keep :]
                break
            if i:
                self._text(self.buf[:i], out)
                self.buf = self.buf[i:]
            j = self.buf.find("|>", 2)
            if j == -1:
                break
            tok, self.buf = self.buf[: j + 2], self.buf[j + 2 :]
            if tok == MSG:
                self.state, self.kind, self.header, self.tool = "header", None, "", ""
            elif tok == EOS:
                pass
            elif tok.startswith(BODY):
                self.state, self.kind = "body", tok[len(BODY) : -2]
            elif tok == END:
                if self.kind == "invoke_tool_json":
                    out.append(self._call())
                self.state, self.kind = "out", None
            else:
                self._text(tok, out)
        return out

    def flush(self):
        out = []
        if self.buf:
            self._text(self.buf, out)
            self.buf = ""
        if self.kind == "invoke_tool_json" and self.tool.strip():
            out.append(self._call())
        self.kind = None
        return out

    def _text(self, t, out):
        if not t:
            return
        if self.state == "header":
            self.header += t
        elif self.kind == "thinking":
            out.append(("reasoning", t))
        elif self.kind == "invoke_tool_json":
            self.tool += t
        else:
            out.append(("content", t))

    def _call(self):
        raw, self.tool = self.tool, ""
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            return ("content", raw)
        args = obj.get("args", obj.get("arguments", {}))
        return ("tool_call", {
            "id": "call_" + uuid.uuid4().hex[:24],
            "type": "function",
            "function": {
                "name": obj.get("name") or self.header.strip(),
                "arguments": args if isinstance(args, str) else json.dumps(args),
            },
        })


def rewrite(body):
    effort = body.pop("reasoning_effort", None)
    reasoning = body.pop("reasoning", None)
    if isinstance(reasoning, dict):
        effort = reasoning.get("effort", effort)
    for k in DROP:
        body.pop(k, None)
    if effort in EFFORTS:
        body.setdefault("chat_template_kwargs", {}).setdefault("reasoning_effort", effort)
    body["model"] = "default_model"
    return effort


class Handler(BaseHTTPRequestHandler):
    upstream = ("127.0.0.1", 8091)
    log_file = None

    def log_message(self, *a):
        pass

    def _json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _record(self, rec):
        line = json.dumps(rec)
        print(line, file=sys.stderr, flush=True)
        if self.log_file:
            with open(self.log_file, "a") as f:
                f.write(line + "\n")

    def do_GET(self):
        path = self.path.split("?")[0].removeprefix("/api")
        if path == "/health":
            try:
                c = http.client.HTTPConnection(*self.upstream, timeout=5)
                c.request("GET", "/health")
                ok = c.getresponse().status == 200
            except OSError:
                ok = False
            self._json(200 if ok else 503, {"status": "ok" if ok else "loading"})
        elif path == "/v1/models":
            self._json(200, {"object": "list", "data": [
                {"id": "thinkingmachines/inkling-2-mini", "object": "model", "owned_by": "local"}]})
        elif path == "/v1/key":
            self._json(200, {"data": {"label": "local-inkling-2-mini"}})
        else:
            self._json(404, {"error": {"message": f"no route {path}"}})

    def do_POST(self):
        path = self.path.split("?")[0].removeprefix("/api")
        if path != "/v1/chat/completions":
            return self._json(404, {"error": {"message": f"no route {path}"}})
        t0 = time.monotonic()
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        model = body.get("model") or "thinkingmachines/inkling-2-mini"
        stream = bool(body.get("stream"))
        rec = {"ts": time.time(), "model": model, "stream": stream,
               "effort": rewrite(body), "messages": len(body.get("messages", [])),
               "tools": len(body.get("tools") or [])}
        try:
            conn = http.client.HTTPConnection(*self.upstream, timeout=1800)
            conn.request("POST", "/v1/chat/completions", json.dumps(body),
                         {"Content-Type": "application/json"})
            resp = conn.getresponse()
        except OSError as e:
            rec.update(status=502, error=str(e))
            self._record(rec)
            return self._json(502, {"error": {"message": f"mlx_lm.server: {e}"}})
        rec["status"] = resp.status
        if resp.status != 200:
            data = resp.read()
            rec["error"] = data[:500].decode(errors="replace")
            self._record(rec)
            self.send_response(resp.status)
            self.send_header("Content-Type", resp.getheader("Content-Type", "application/json"))
            self.end_headers()
            self.wfile.write(data)
            return
        try:
            (self._stream if stream else self._whole)(resp, model, rec, t0)
        except (BrokenPipeError, ConnectionResetError):
            rec["error"] = "client disconnected"
        rec["ms"] = round((time.monotonic() - t0) * 1000)
        self._record(rec)

    def _whole(self, resp, model, rec, t0):
        data = json.loads(resp.read())
        data["model"] = model
        for choice in data.get("choices", []):
            msg = choice.get("message", {})
            p = Parser()
            events = p.feed(msg.get("content") or "") + p.flush()
            reasoning = "".join(t for k, t in events if k == "reasoning").strip()
            content = "".join(t for k, t in events if k == "content").strip()
            calls = (msg.get("tool_calls") or []) + [t for k, t in events if k == "tool_call"]
            msg["content"] = content or None
            if reasoning:
                msg["reasoning_content"] = msg["reasoning"] = reasoning
            if calls:
                msg["tool_calls"] = calls
                choice["finish_reason"] = "tool_calls"
            rec.update(finish=choice.get("finish_reason"), tool_calls=len(calls),
                       reasoning_chars=len(reasoning), content_chars=len(content))
        rec["usage"] = data.get("usage")
        self._json(200, data)

    def _stream(self, resp, model, rec, t0):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        p, n_calls, sent_role = Parser(), 0, False
        rec.update(reasoning_chars=0, content_chars=0)
        cid, created = "chatcmpl-" + uuid.uuid4().hex[:24], int(time.time())

        def send(delta, finish=None, usage=None):
            nonlocal sent_role
            if not sent_role:
                delta = {"role": "assistant", **delta}
                sent_role = True
            chunk = {"id": cid, "object": "chat.completion.chunk", "created": created,
                     "model": model, "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if usage:
                chunk["usage"] = usage
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()

        def emit(events):
            nonlocal n_calls
            for kind, val in events:
                if "ttft_ms" not in rec:
                    rec["ttft_ms"] = round((time.monotonic() - t0) * 1000)
                if kind == "reasoning":
                    rec["reasoning_chars"] += len(val)
                    send({"reasoning_content": val, "reasoning": val})
                elif kind == "content":
                    rec["content_chars"] += len(val)
                    send({"content": val})
                else:
                    send({"tool_calls": [{"index": n_calls, **val}]})
                    n_calls += 1

        finish, usage, upstream_calls = None, None, set()
        for line in resp:
            if not line.startswith(b"data: "):
                continue
            payload = line[6:].strip()
            if payload == b"[DONE]":
                break
            chunk = json.loads(payload)
            usage = chunk.get("usage") or usage
            for choice in chunk.get("choices", []):
                delta = choice.get("delta") or {}
                # Non-Inkling models: mlx_lm.server parses these itself.
                for tc in delta.get("tool_calls") or []:
                    send({"tool_calls": [{**tc, "index": n_calls + tc.get("index", 0)}]})
                    upstream_calls.add(tc.get("index", 0))
                if delta.get("reasoning"):
                    emit([("reasoning", delta["reasoning"])])
                emit(p.feed(delta.get("content") or ""))
                finish = choice.get("finish_reason") or finish
        emit(p.flush())
        n_calls += len(upstream_calls)
        finish = "tool_calls" if n_calls else (finish or "stop")
        send({}, finish, usage)
        self.wfile.write(b"data: [DONE]\n\n")
        rec.update(finish=finish, tool_calls=n_calls, usage=usage)


def check(base):
    """Smoke test against a running gateway."""
    def post(body):
        c = http.client.HTTPConnection(base.split("//")[1], timeout=600)
        c.request("POST", "/v1/chat/completions", json.dumps(body), {"Content-Type": "application/json"})
        return c.getresponse()

    tool = {"type": "function", "function": {
        "name": "get_weather", "description": "Current weather for a city.",
        "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}
    t, host = time.monotonic(), base.split("//")[1]
    while True:
        try:
            c = http.client.HTTPConnection(host, timeout=5)
            c.request("GET", "/health")
            if c.getresponse().status == 200:
                break
        except OSError:
            pass
        if time.monotonic() - t > 600:
            sys.exit("gateway or mlx_lm.server not up after 600s")
        time.sleep(2)
    print(f"ready      {time.monotonic() - t:5.1f}s")
    t = time.monotonic()
    r = post({"model": "thinkingmachines/inkling-2-mini", "reasoning_effort": "low", "tools": [tool],
              "messages": [{"role": "user", "content": "What's the weather in Paris? Use the tool."}]})
    msg = json.loads(r.read())["choices"][0]["message"]
    calls = msg.get("tool_calls") or []
    print(f"tool call  {time.monotonic() - t:5.1f}s  {'ok' if calls else 'FAIL'}  {[c['function'] for c in calls] or msg}")
    t = time.monotonic()
    r = post({"model": "thinkingmachines/inkling-2-mini", "stream": True, "reasoning_effort": "none",
              "max_tokens": 64, "messages": [{"role": "user", "content": "Say hello in five words."}]})
    text = ""
    for line in r:
        if line.startswith(b"data: {"):
            text += json.loads(line[6:])["choices"][0]["delta"].get("content") or ""
    print(f"stream     {time.monotonic() - t:5.1f}s  {'ok' if text.strip() else 'FAIL'}  {text.strip()!r}")
    sys.exit(0 if calls and text.strip() else 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", action="append", help="HOST:PORT, repeatable (default 127.0.0.1:8090)")
    ap.add_argument("--upstream", default="127.0.0.1:8091")
    ap.add_argument("--log")
    ap.add_argument("--check", metavar="URL")
    a = ap.parse_args()
    if a.check:
        return check(a.check)
    uh, up = a.upstream.rsplit(":", 1)
    Handler.upstream, Handler.log_file = (uh, int(up)), a.log
    first, *rest = [(h, int(p)) for h, p in (x.rsplit(":", 1) for x in a.listen or ["127.0.0.1:8090"])]
    for addr in rest:
        threading.Thread(target=serve, args=(addr, a.upstream), daemon=True).start()
    serve(first, a.upstream)


def serve(addr, upstream):
    # The container network's host address exists only while a container runs.
    waiting = False
    while True:
        try:
            srv = ThreadingHTTPServer(addr, Handler)
            break
        except OSError as e:
            if e.errno != errno.EADDRNOTAVAIL:
                raise
            if not waiting:
                print(f"gateway waiting for {addr[0]} (appears when a container starts)", file=sys.stderr, flush=True)
                waiting = True
            time.sleep(1)
    print(f"gateway on http://{addr[0]}:{addr[1]}/v1 -> mlx_lm.server {upstream}", file=sys.stderr, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

"""Unit tests for proxy.py's route policy. No network, no container runtime."""
from __future__ import annotations

import asyncio
import importlib.util
import os
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY = os.path.join(HERE, "..", "proxy.py")
REAL_KEY = "sk-or-v1-" + "a" * 64


def load(**env: str):
    clean = {k: v for k, v in os.environ.items() if not k.startswith("PI_")}
    with mock.patch.dict(os.environ, {**clean, **env}, clear=True):
        spec = importlib.util.spec_from_file_location("proxy_under_test", PROXY)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    mod.log = lambda msg: None
    return mod


OFFLINE = {"PI_PROXY_EGRESS": "offline", "PI_PROXY_MODEL_HOST": "192.168.64.1", "PI_PROXY_MODEL_PORT": "8090"}


class Writer:
    def __init__(self) -> None:
        self.data = b""

    def write(self, b: bytes) -> None:
        self.data += b

    async def drain(self) -> None:
        pass

    def close(self) -> None:
        pass


def request(mod, raw: bytes) -> tuple[bytes, list[str]]:
    """Run handle() on raw and return (response, routes taken)."""
    routes: list[str] = []

    async def tunnel(r, w, host):
        routes.append("tunnel " + host)

    async def mitm(r, w, host):
        routes.append("mitm " + host)

    async def run() -> bytes:
        reader = asyncio.StreamReader()
        reader.feed_data(raw)
        reader.feed_eof()
        writer = Writer()
        with mock.patch.object(mod, "tunnel", tunnel), mock.patch.object(mod, "mitm", mitm):
            await mod.handle(reader, writer)
        return writer.data

    return asyncio.run(run()), routes


def connect(host: str) -> bytes:
    return f"CONNECT {host}:443 HTTP/1.1\r\nHost: {host}:443\r\n\r\n".encode()


GITHUB_HOSTS = ["github.com", "api.github.com", "codeload.github.com", "objects.githubusercontent.com",
                "raw.githubusercontent.com", "uploads.github.com", "GitHub.com."]


class Normal(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = load()

    def test_github_tunnels(self) -> None:
        for host in GITHUB_HOSTS:
            _, routes = request(self.mod, connect(host))
            self.assertEqual(routes, ["tunnel " + host], host)

    def test_openrouter_mitm(self) -> None:
        _, routes = request(self.mod, connect("openrouter.ai"))
        self.assertEqual(routes, ["mitm openrouter.ai"])

    def test_other_hosts_refused(self) -> None:
        for host in ["example.com", "gist.github.com", "1.1.1.1", "192.168.64.1"]:
            resp, routes = request(self.mod, connect(host))
            self.assertTrue(resp.startswith(b"HTTP/1.1 403"), host)
            self.assertEqual(routes, [], host)

    def test_egress_reports_standard(self) -> None:
        resp, _ = request(self.mod, b"GET /egress HTTP/1.1\r\n\r\n")
        self.assertTrue(resp.endswith(b"\r\n\r\nstandard\n"))

    def test_check_egress_accepts_standard(self) -> None:
        self.mod.check_egress()

    def test_model_host_is_plain_http(self) -> None:
        mod = load(PI_PROXY_MODEL_HOST="192.168.64.1", PI_PROXY_MODEL_PORT="8090")
        self.assertEqual((mod.UPSTREAM_HOST, mod.UPSTREAM_PORT, mod.UPSTREAM_TLS), ("192.168.64.1", 8090, False))
        self.assertIsNone(mod.upstream_context())
        self.assertEqual((self.mod.UPSTREAM_PORT, self.mod.UPSTREAM_TLS), (443, True))

    def test_model_host_never_gets_the_key(self) -> None:
        mod = load(PI_PROXY_MODEL_HOST="192.168.64.1", PI_PROXY_MODEL_PORT="8090")
        mod.openrouter_key = lambda: REAL_KEY
        sent = Writer()

        async def open_connection(host, port, ssl=None):
            reader = asyncio.StreamReader()
            reader.feed_data(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
            reader.feed_eof()
            return reader, sent

        async def run() -> None:
            with mock.patch.object(asyncio, "open_connection", open_connection):
                await mod.forward_openrouter("openrouter.ai", "GET", "/api/v1/key", [], b"", Writer())

        asyncio.run(run())
        self.assertIn(b"Host: 192.168.64.1:8090\r\n", sent.data)
        self.assertIn(b"Bearer sk-or-v1-placeholder", sent.data)
        self.assertNotIn(REAL_KEY.encode(), sent.data)


class Offline(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = load(**OFFLINE)
        self.mod.openrouter_key = lambda: REAL_KEY

    def test_github_refused(self) -> None:
        for host in GITHUB_HOSTS:
            resp, routes = request(self.mod, connect(host))
            self.assertTrue(resp.startswith(b"HTTP/1.1 403"), host)
            self.assertEqual(routes, [], host)

    def test_other_hosts_refused(self) -> None:
        for host in ["example.com", "1.1.1.1", "192.168.64.1"]:
            resp, routes = request(self.mod, connect(host))
            self.assertTrue(resp.startswith(b"HTTP/1.1 403"), host)
            self.assertEqual(routes, [], host)

    def test_plain_http_refused(self) -> None:
        resp, _ = request(self.mod, b"GET http://192.168.64.1:8090/v1/models HTTP/1.1\r\n\r\n")
        self.assertTrue(resp.startswith(b"HTTP/1.1 403"))

    def test_egress_reports_offline(self) -> None:
        resp, _ = request(self.mod, b"GET /egress HTTP/1.1\r\n\r\n")
        self.assertTrue(resp.endswith(b"\r\n\r\noffline\n"))

    def forward(self) -> tuple[list, bytes]:
        calls: list = []
        sent = Writer()

        async def open_connection(host, port, ssl=None):
            calls.append((host, port, ssl))
            reader = asyncio.StreamReader()
            reader.feed_data(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
            reader.feed_eof()
            return reader, sent

        async def run() -> None:
            with mock.patch.object(asyncio, "open_connection", open_connection):
                await self.mod.forward_openrouter(
                    "openrouter.ai", "GET", "/api/v1/key",
                    [b"Authorization: Bearer sk-or-v1-placeholder"], b"", Writer())

        asyncio.run(run())
        return calls, sent.data

    def test_model_calls_go_to_local_upstream_only(self) -> None:
        calls, sent = self.forward()
        self.assertEqual(calls, [("192.168.64.1", 8090, None)])
        self.assertIn(b"Host: 192.168.64.1:8090\r\n", sent)
        self.assertNotIn(REAL_KEY.encode(), sent)

    def test_no_fallback_to_openrouter(self) -> None:
        for host in ["", "openrouter.ai", "1.1.1.1", "127.0.0.1"]:
            self.mod.UPSTREAM_HOST = host
            with self.assertRaises(PermissionError, msg=host):
                self.forward()

    def test_check_egress_needs_local_upstream(self) -> None:
        self.mod.check_egress()
        for host in ["", "openrouter.ai", "api.openrouter.ai", "localhost", "127.0.0.1", "1.1.1.1",
                     "100.100.100.100", "fd00::1", "192.168.64.1 "]:
            mod = load(**{**OFFLINE, "PI_PROXY_MODEL_HOST": host})
            with self.assertRaises(RuntimeError, msg=host):
                mod.check_egress()

    def test_check_egress_rejects_unknown_mode(self) -> None:
        for mode in ["", "normal", "Offline", "online"]:
            with self.assertRaises(RuntimeError, msg=mode):
                load(PI_PROXY_EGRESS=mode).check_egress()

    @unittest.skipIf(sys.version_info < (3, 11), "proxy.py main() needs Python 3.11")
    def test_main_refuses_to_start_without_upstream(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            mod = load(PI_PROXY_EGRESS="offline", PI_PROXY_ADDR_FILE=os.path.join(d, "proxy.addr"))
            mod.openrouter_key = mock.Mock(side_effect=AssertionError("key read before the egress check"))
            with self.assertRaises(SystemExit) as cm:
                mod.main()
            self.assertIn("offline egress needs PI_PROXY_MODEL_HOST", str(cm.exception))


if __name__ == "__main__":
    unittest.main(verbosity=1)

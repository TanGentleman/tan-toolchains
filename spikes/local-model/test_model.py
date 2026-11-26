"""The model CLI and config.py with a fake venv (fake backend and gateway), so
no MLX or weights are needed."""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

import config

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "model")
NAME = "inkling-2-mini"

# Records its argv; healthy FAKE_LOAD_S seconds after start; on TERM, waits
# FAKE_EXIT_S, then writes backend.exited, so a test can tell serve waited.
FAKE_BACKEND = '''
import json, os, signal, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
home = os.environ["LOCAL_MODEL_HOME"]
with open(os.path.join(home, "backend.argv"), "w") as f:
    json.dump({"argv": sys.argv[1:], "offline": os.environ.get("HF_HUB_OFFLINE"), "pid": os.getpid()}, f)
if os.environ.get("FAKE_FAIL"):
    sys.exit("fake backend: failing on purpose")
port = int(sys.argv[sys.argv.index("--port") + 1])
ready = time.monotonic() + float(os.environ.get("FAKE_LOAD_S", "0.3"))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200 if time.monotonic() >= ready else 503); self.end_headers()
def term(*_):
    time.sleep(float(os.environ.get("FAKE_EXIT_S", "0.5")))
    with open(os.path.join(home, "backend.exited"), "w") as f:
        f.write(str(os.getpid()))
    os._exit(0)
signal.signal(signal.SIGTERM, term)
srv = ThreadingHTTPServer(("127.0.0.1", port), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
while True: time.sleep(1)
'''

# Takes gateway.py's arguments; /health asks the upstream, like the real one.
FAKE_GATEWAY = '''
import http.client, json, os, signal, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
a = sys.argv[1:]
if "--check" in a:
    print("fake check", " ".join(a)); sys.exit(0)
with open(os.path.join(os.environ["LOCAL_MODEL_HOME"], "gateway.argv"), "w") as f:
    json.dump(a, f)
host, port = a[a.index("--listen") + 1].rsplit(":", 1)
uh, up = a[a.index("--upstream") + 1].rsplit(":", 1)
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        try:
            c = http.client.HTTPConnection(uh, int(up), timeout=2); c.request("GET", "/health")
            ok = c.getresponse().status == 200
        except OSError:
            ok = False
        self.send_response(200 if ok else 503); self.end_headers()
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
ThreadingHTTPServer((host, int(port)), H).serve_forever()
'''


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def running(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


class CLI(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        home = self.home = os.path.join(self.dir, "data")
        self.user = os.path.join(self.dir, "user")
        fakes = os.path.join(self.dir, "fakes")
        write(os.path.join(fakes, "gateway.py"), FAKE_GATEWAY)
        # The venv's python: the fake gateway for gateway.py, the real python otherwise.
        write(os.path.join(home, "venv", "bin", "python"),
              f'#!/bin/sh\ncase $1 in */gateway.py) shift; exec "{sys.executable}" "{fakes}/gateway.py" "$@" ;; esac\n'
              f'exec "{sys.executable}" "$@"\n', 0o755)
        write(os.path.join(home, "venv", "bin", "mlx_lm.server"), f"#!{sys.executable}\n{FAKE_BACKEND}", 0o755)
        # --containers reads the container network's host address; use loopback.
        self.fake_container = os.path.join(self.dir, "container-bin")
        write(os.path.join(self.fake_container, "container"),
              "#!/bin/sh\n[ \"$*\" = 'network inspect default' ] || exit 1\n"
              "echo '[{\"status\":{\"ipv4Gateway\":\"127.0.0.1\"}}]'\n", 0o755)
        rev = config.load_model(os.path.join(HERE, "models", NAME + ".json"))["weights"]["revision"]
        write(os.path.join(home, "models", NAME, ".complete"), rev + "\n")
        write(os.path.join(home, ".local-model-spike"), "")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("LOCAL_MODEL_", "PI_", "FAKE_"))}
        self.port = free_port()
        self.env.update(HOME=self.user, LOCAL_MODEL_HOME=home, PATH=f"{fakes}:{os.environ['PATH']}",
                        LOCAL_MODEL_PORT=str(self.port), LOCAL_MODEL_BACKEND_PORT=str(free_port()))

    def model(self, *args, **env):
        return subprocess.run([MODEL, *args], env={**self.env, **env}, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=90)

    def ok(self, *args, **env):
        r = self.model(*args, **env)
        self.assertEqual(r.returncode, 0, f"model {' '.join(args)}: {r.stdout}{r.stderr}")
        return r

    def fails(self, *args, **env):
        r = self.model(*args, **env)
        self.assertNotEqual(r.returncode, 0, f"model {' '.join(args)}: {r.stdout}")
        return r.stderr

    def status(self):
        s = json.loads(self.ok("status", "--json").stdout)
        self.assertEqual(s["v"], 1)
        return s

    def argv(self, name):
        with open(os.path.join(self.home, name + ".argv")) as f:
            return json.load(f)

    def serve(self, *args, **env):
        """model serve in its own session, like a terminal tab; returns once it answers."""
        p = subprocess.Popen([MODEL, "serve", *args], env={**self.env, **env}, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        self.addCleanup(p.stdout.close)
        self.addCleanup(lambda: p.poll() is None and (os.killpg(p.pid, signal.SIGKILL), p.wait()))
        for _ in range(200):
            if p.poll() is not None or self.status()["state"] != "down":
                break
            time.sleep(0.05)
        return p

    def wait_up(self, p):
        """Reads serve's output until it says it is ready; that output is kept for communicate."""
        seen = ""
        for line in p.stdout:
            seen += line
            if line.startswith("ready after"):
                self.assertEqual(self.status()["state"], "up")
                p.seen = seen
                return
        self.fail(seen)

    def backend_pid(self):
        return self.argv("backend")["pid"]

    def test_serve_owns_the_model(self):
        down = self.status()
        self.assertEqual((down["state"], down["model"], down["backend"], down["model_url"]),
                         ("down", NAME, "mlx-lm", None))
        p = self.serve(FAKE_LOAD_S="1")
        self.assertEqual(self.status()["state"], "loading")
        self.wait_up(p)
        s = self.status()
        self.assertEqual((s["url"], s["model_url"]), (f"http://127.0.0.1:{self.port}/v1", None))
        self.assertIn("in another terminal", self.fails("serve"))
        self.assertIn("a server is running", self.fails("uninstall"))
        backend = self.backend_pid()
        p.send_signal(signal.SIGINT)
        out, _ = p.communicate(timeout=30)
        self.assertEqual(p.returncode, 130, out)
        self.assertIn("ready after", p.seen)
        self.assertIn("the model is unloaded", out)
        with open(os.path.join(self.home, "backend.exited")) as f:
            self.assertEqual(int(f.read()), backend)  # exited before serve did
        self.assertFalse(running(backend))
        self.assertEqual(self.status(), down)
        self.assertFalse(os.path.exists(os.path.join(self.home, "run")))

    def test_closing_the_terminal_unloads(self):
        for sig, group in ((signal.SIGHUP, True), (signal.SIGHUP, False), (signal.SIGTERM, False)):
            with self.subTest(sig=sig, group=group):
                p = self.serve()
                self.wait_up(p)
                backend = self.backend_pid()
                (os.killpg if group else os.kill)(p.pid, sig)
                p.communicate(timeout=30)
                self.assertFalse(running(backend))
                self.assertEqual(self.status()["state"], "down")

    def test_config_drives_the_backend_and_gateway(self):
        self.wait_up(self.serve())
        m = config.load_model(os.path.join(HERE, "models", NAME + ".json"))
        b = self.argv("backend")
        self.assertEqual(b["offline"], "1")
        self.assertEqual(b["argv"], ["--model", os.path.join(self.home, "models", NAME), "--host", "127.0.0.1",
                                     "--port", self.env["LOCAL_MODEL_BACKEND_PORT"], *m["server_args"]])
        g = self.argv("gateway")
        for flag, val in (("--parser", "inkling"), ("--upstream-model", "default_model"), ("--model-name", NAME),
                          ("--listen", f"127.0.0.1:{self.port}")):
            self.assertEqual(g[g.index(flag) + 1], val)

    def test_containers(self):
        self.env["PATH"] = f"{self.fake_container}:{self.env['PATH']}"
        self.wait_up(self.serve("--containers"))
        self.assertEqual(self.status()["model_url"], f"http://gateway:{self.port}")
        g = self.argv("gateway")
        self.assertEqual([g[i + 1] for i, x in enumerate(g) if x == "--listen"], [f"127.0.0.1:{self.port}"] * 2)
        self.assertIn(f"--egress offline --model-url http://gateway:{self.port}", self.ok("status").stdout)

    def test_no_container_network(self):
        self.wait_up(self.serve())
        self.assertIn("serve --containers", self.ok("status").stdout)

    def test_serve_reports_a_failed_start(self):
        p = self.serve(FAKE_FAIL="1")
        out, _ = p.communicate(timeout=30)
        self.assertEqual(p.returncode, 1)
        self.assertIn("the backend or the gateway exited", out)
        self.assertIn("failing on purpose", out)
        self.assertEqual(self.status()["state"], "down")

    def test_missing_weights(self):
        os.remove(os.path.join(self.home, "models", NAME, ".complete"))
        self.assertIn("weights for inkling-2-mini missing", self.fails("serve"))

    def test_check_and_usage(self):
        out = self.ok("check").stdout
        self.assertIn(f"--check http://127.0.0.1:{self.port} --model-name {NAME}", out)
        for args in ((), ("bogus",), ("up",), ("down",), ("status", "--yaml"), ("serve", "x"),
                     ("install", "x"), ("uninstall", "--all")):
            r = self.model(*args)
            self.assertEqual(r.returncode, 2, args)
            self.assertIn("model serve [--containers]", r.stderr)

    def test_selected_model(self):
        cfg = os.path.join(self.user, ".config", "local-model", "config.json")
        write(cfg, '{"v": 1}')
        self.assertEqual(self.status()["model"], NAME)
        write(cfg, '{"v": 1, "model": "nope"}')
        self.assertIn("no model 'nope'", self.fails("check"))
        write(cfg, '{"v": 2, "model": "inkling-2-mini"}')
        self.assertIn("v must be 1", self.fails("serve"))

    @unittest.skipIf(sys.platform == "darwin", "the platform check passes on a Mac")
    def test_install_refuses_other_platforms(self):
        self.assertIn("needs Darwin/arm64", self.fails("install"))

    def test_uninstall_refuses_foreign_homes(self):
        os.remove(os.path.join(self.home, ".local-model-spike"))
        self.assertIn("not deleting anything", self.fails("uninstall"))
        self.assertTrue(os.path.isdir(os.path.join(self.home, "models")))
        self.assertIn("nothing at", self.ok("uninstall", LOCAL_MODEL_HOME=os.path.join(self.dir, "none")).stdout)
        write(os.path.join(self.home, ".local-model-spike"), "")
        self.assertIn("needs a terminal to confirm", self.fails("uninstall", "--keep-model"))
        self.assertTrue(os.path.isdir(os.path.join(self.home, "venv")))


class Config(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        with open(os.path.join(HERE, "models", NAME + ".json")) as f:
            self.good = json.load(f)

    def load(self, m):
        p = os.path.join(self.dir, "m.json")
        write(p, json.dumps(m))
        return config.load_model(p)

    def test_shipped_models_load(self):
        for f in os.listdir(os.path.join(HERE, "models")):
            m = config.load_model(os.path.join(HERE, "models", f))
            self.assertIn(m["backend"], config.BACKENDS)

    def test_defaults(self):
        m = self.load({"v": 1, "backend": "mlx-lm", "parser": "none",
                       "weights": {"repo": "a/b", "revision": "0" * 40}})
        self.assertEqual((m["server_args"], m["weights"]["exclude"]), ([], []))

    def test_refused(self):
        w = self.good["weights"]
        for bad, why in (({"v": 2}, "v must be 1"), ({"backend": "vllm"}, "backend must be"),
                         ({"parser": "x"}, "parser must be"), ({"extra": 1}, "unknown keys"),
                         ({"weights": {**w, "revision": "main"}}, "40-hex"),
                         ({"weights": {**w, "repo": "x"}}, "ORG/NAME"),
                         ({"server_args": "--temp 1"}, "list of non-empty strings"),
                         ({"server_args": ["--port", "1"]}, "must not set --port"),
                         ({"server_args": ["--model=x"]}, "must not set --model")):
            with self.subTest(why), self.assertRaisesRegex(config.ConfigError, why):
                self.load({**self.good, **bad})

    def test_selection(self):
        models, cfg = os.path.join(self.dir, "models"), os.path.join(self.dir, "config.json")
        write(os.path.join(models, "a.json"), "{}")
        self.assertEqual(config.selected(models, cfg), "a")
        write(os.path.join(models, "b.json"), "{}")
        with self.assertRaisesRegex(config.ConfigError, "2 models"):
            config.selected(models, cfg)
        write(cfg, '{"v": 1, "model": "b"}')
        self.assertEqual(config.selected(models, cfg), "b")
        write(cfg, '{"v": 1, "model": "b", "image": "min"}')
        with self.assertRaisesRegex(config.ConfigError, "unknown keys"):
            config.selected(models, cfg)


if __name__ == "__main__":
    unittest.main()

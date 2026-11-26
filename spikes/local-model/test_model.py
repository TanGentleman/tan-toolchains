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
# FAKE_EXIT_S, then writes backend.exited, so a test can tell down waited.
FAKE_BACKEND = '''
import json, os, signal, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
home = os.environ["LOCAL_MODEL_HOME"]
with open(os.path.join(home, "backend.argv"), "w") as f:
    json.dump({"argv": sys.argv[1:], "offline": os.environ.get("HF_HUB_OFFLINE")}, f)
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
        self.run_dir = os.path.join(home, "run")
        fakes = os.path.join(self.dir, "fakes")
        write(os.path.join(fakes, "gateway.py"), FAKE_GATEWAY)
        # The venv's python: the fake gateway for gateway.py, the real python otherwise.
        write(os.path.join(home, "venv", "bin", "python"),
              f'#!/bin/sh\ncase $1 in */gateway.py) shift; exec "{sys.executable}" "{fakes}/gateway.py" "$@" ;; esac\n'
              f'exec "{sys.executable}" "$@"\n', 0o755)
        write(os.path.join(home, "venv", "bin", "mlx_lm.server"), f"#!{sys.executable}\n{FAKE_BACKEND}", 0o755)
        # --containers reads the container network's host address; use loopback.
        write(os.path.join(fakes, "container"),
              "#!/bin/sh\n[ \"$*\" = 'network inspect default' ] || exit 1\n"
              "echo '[{\"status\":{\"ipv4Gateway\":\"127.0.0.1\"}}]'\n", 0o755)
        rev = config.load_model(os.path.join(HERE, "models", NAME + ".json"))["weights"]["revision"]
        write(os.path.join(home, "models", NAME, ".complete"), rev + "\n")
        write(os.path.join(home, ".local-model-spike"), "")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("LOCAL_MODEL_", "PI_", "FAKE_"))}
        self.port = free_port()
        self.env.update(HOME=self.user, LOCAL_MODEL_HOME=home, PATH=f"{fakes}:{os.environ['PATH']}",
                        LOCAL_MODEL_PORT=str(self.port), LOCAL_MODEL_BACKEND_PORT=str(free_port()))
        self.addCleanup(self.model, "down")

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

    def pid(self, name):
        with open(os.path.join(self.run_dir, f"{name}.pid")) as f:
            return int(f.readline())

    def argv(self, name):
        with open(os.path.join(self.home, name + ".argv")) as f:
            return json.load(f)

    def test_up_status_down_idempotent(self):
        down = self.status()
        self.assertEqual((down["state"], down["pid"], down["model"], down["backend"], down["model_url"]),
                         ("down", None, NAME, "mlx-lm", None))
        self.assertIn("already down", self.ok("down").stdout)
        self.assertIn("loading the model", self.ok("up", FAKE_LOAD_S="2").stdout)
        s = self.status()
        serve, backend = self.pid("serve"), self.pid("backend")
        self.assertEqual((s["state"], s["pid"], s["url"], s["model_url"]),
                         ("up", serve, f"http://127.0.0.1:{self.port}/v1", None))
        self.assertIn(f"already up: pid {serve}", self.ok("up").stdout)
        self.assertEqual(self.pid("serve"), serve)

        self.assertIn("model is unloaded", self.ok("down").stdout)
        with open(os.path.join(self.home, "backend.exited")) as f:
            self.assertEqual(int(f.read()), backend)  # exited before down returned
        self.assertFalse(running(backend) or running(serve))
        self.assertEqual(os.listdir(self.run_dir), [])
        self.assertEqual(self.status(), down)
        self.assertIn("already down", self.ok("down").stdout)

    def test_config_drives_the_backend_and_gateway(self):
        self.ok("up")
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
        self.ok("up", "--containers")
        s = self.status()
        self.assertEqual(s["model_url"], f"http://gateway:{self.port}")
        g = self.argv("gateway")
        self.assertEqual([g[i + 1] for i, x in enumerate(g) if x == "--listen"], [f"127.0.0.1:{self.port}"] * 2)
        self.assertIn(f"--egress offline --model-url http://gateway:{self.port}", self.ok("status").stdout)
        self.assertIn("already up", self.ok("up").stdout)  # it also listens on loopback
        self.ok("down")
        self.ok("up")
        self.assertIn("running without --containers", self.fails("up", "--containers"))
        self.assertIn("up --containers", self.ok("status").stdout)

    def test_stale_pid_files_are_not_killed(self):
        other = subprocess.Popen(["sleep", "60"])
        self.addCleanup(other.wait)
        self.addCleanup(other.kill)
        os.makedirs(self.run_dir, exist_ok=True)
        for name, text in (("serve", f"{other.pid}\nThu Jan  1 00:00:00 1970\n"),
                           ("backend", f"{other.pid}\n"), ("gateway", "not-a-pid\n")):
            write(os.path.join(self.run_dir, f"{name}.pid"), text)
        self.assertEqual(self.status()["state"], "down")
        self.assertIn("already down", self.ok("down").stdout)
        self.assertTrue(running(other.pid))
        self.assertEqual(os.listdir(self.run_dir), [])
        write(os.path.join(self.run_dir, "serve.pid"), f"{other.pid}\nThu Jan  1 00:00:00 1970\n")
        self.ok("up")
        self.assertNotEqual(self.pid("serve"), other.pid)
        self.ok("down")
        self.assertTrue(running(other.pid))

    def test_up_reports_a_failed_start(self):
        err = self.fails("up", FAKE_FAIL="1")
        self.assertIn("exited before the model was ready", err)
        self.assertIn("failing on purpose", err)
        self.assertEqual(self.status()["state"], "down")

    def test_missing_weights(self):
        os.remove(os.path.join(self.home, "models", NAME, ".complete"))
        self.assertIn("weights for inkling-2-mini missing", self.fails("up"))

    def test_orphans_after_serve_dies(self):
        self.ok("up")
        serve, backend, gw = self.pid("serve"), self.pid("backend"), self.pid("gateway")
        os.kill(serve, signal.SIGKILL)
        for _ in range(50):
            if not running(serve):
                break
            time.sleep(0.1)
        s = self.status()
        self.assertEqual((s["state"], s["pid"]), ("orphaned", backend))
        self.assertIn("left over", self.fails("up"))
        self.assertIn("already running: backend", self.fails("serve"))
        self.assertIn("leftover", self.ok("down").stdout)
        self.assertFalse(running(backend) or running(gw))

    def test_foreground_serve_is_seen_and_stopped(self):
        p = subprocess.Popen([MODEL, "serve"], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(p.wait)
        self.addCleanup(p.kill)
        for _ in range(100):
            if os.path.exists(os.path.join(self.run_dir, "serve.pid")):
                break
            time.sleep(0.1)
        self.ok("up")  # waits for the foreground server instead of starting one
        self.assertEqual(self.status()["pid"], p.pid)
        self.assertIn("already running: serve", self.fails("serve"))
        self.ok("down")
        self.assertEqual(p.wait(timeout=10), 130)

    def test_check_and_usage(self):
        out = self.ok("check").stdout
        self.assertIn(f"--check http://127.0.0.1:{self.port} --model-name {NAME}", out)
        for args in ((), ("bogus",), ("up", "x"), ("down", "x"), ("status", "--yaml"), ("serve", "x"),
                     ("install", "x"), ("uninstall", "--all")):
            r = self.model(*args)
            self.assertEqual(r.returncode, 2, args)
            self.assertIn("model up [--containers]", r.stderr)

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

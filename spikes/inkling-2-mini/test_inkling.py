"""python3 test_inkling.py: the inkling CLI with a fake venv: fake mlx_lm.server
and fake gateway processes, so no MLX or model is needed."""
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

HERE = os.path.dirname(os.path.abspath(__file__))
INKLING = os.path.join(HERE, "inkling")

# Healthy FAKE_MLX_LOAD_S seconds after start; on TERM, waits FAKE_MLX_EXIT_S,
# then writes mlx.exited, so a test can tell down waited for the exit.
FAKE_MLX = '''
import os, signal, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
if os.environ.get("FAKE_MLX_FAIL"):
    sys.exit("fake mlx_lm.server: failing on purpose")
port = int(sys.argv[sys.argv.index("--port") + 1])
ready = time.monotonic() + float(os.environ.get("FAKE_MLX_LOAD_S", "0.3"))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200 if time.monotonic() >= ready else 503); self.end_headers()
def term(*_):
    time.sleep(float(os.environ.get("FAKE_MLX_EXIT_S", "0.5")))
    with open(os.path.join(os.environ["INKLING_HOME"], "mlx.exited"), "w") as f:
        f.write(str(os.getpid()))
    os._exit(0)
signal.signal(signal.SIGTERM, term)
srv = ThreadingHTTPServer(("127.0.0.1", port), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
while True: time.sleep(1)
'''

# Takes gateway.py's arguments; /health asks the upstream, like the real one.
FAKE_GATEWAY = '''
import http.client, signal, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
a = sys.argv[2:]
if "--check" in a:
    print("fake check", a[a.index("--check") + 1]); sys.exit(0)
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


class CLI(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        home = self.home = os.path.join(self.dir, "home")
        self.run_dir = os.path.join(home, "run")
        bin_ = os.path.join(home, "venv", "bin")
        os.makedirs(bin_)
        fakes = os.path.join(self.dir, "fakes")
        os.makedirs(fakes)
        with open(os.path.join(fakes, "gateway.py"), "w") as f:
            f.write(FAKE_GATEWAY)
        self.script(os.path.join(bin_, "python"),
                    f'#!/bin/sh\nexec "{sys.executable}" "{fakes}/gateway.py" "$@"\n')
        self.script(os.path.join(bin_, "mlx_lm.server"), f"#!{sys.executable}\n{FAKE_MLX}")
        # `up pi` reads the container network's host address; use loopback.
        self.script(os.path.join(fakes, "container"),
                    "#!/bin/sh\n[ \"$*\" = 'network inspect default' ] || exit 1\n"
                    "echo '[{\"status\":{\"ipv4Gateway\":\"127.0.0.1\"}}]'\n")
        model = os.path.join(self.dir, "model")
        os.makedirs(model)
        open(os.path.join(model, "config.json"), "w").close()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("INKLING_", "PI_", "FAKE_"))}
        self.port = free_port()
        self.env.update(INKLING_HOME=home, INKLING_MODEL_DIR=model, PATH=f"{fakes}:{os.environ['PATH']}",
                        INKLING_PORT=str(self.port), INKLING_MLX_PORT=str(free_port()),
                        INKLING_UP_TIMEOUT="20", INKLING_DOWN_TIMEOUT="10")
        self.addCleanup(self.inkling, "down")

    def script(self, path, text):
        with open(path, "w") as f:
            f.write(text)
        os.chmod(path, 0o755)

    def inkling(self, *args, **env):
        return subprocess.run([INKLING, *args], env={**self.env, **env}, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=60)

    def ok(self, *args, **env):
        r = self.inkling(*args, **env)
        self.assertEqual(r.returncode, 0, f"inkling {' '.join(args)}: {r.stdout}{r.stderr}")
        return r

    def status(self):
        s = json.loads(self.ok("status", "--json").stdout)
        self.assertEqual(s["v"], 1)
        return s

    def pid(self, name):
        with open(os.path.join(self.run_dir, f"{name}.pid")) as f:
            return int(f.readline())

    def test_up_status_down_idempotent(self):
        self.assertEqual(self.status()["state"], "down")
        self.assertIn("already down", self.ok("down").stdout)
        self.assertIn("up: http://127.0.0.1", self.ok("up").stdout)
        s = self.status()
        serve, mlx = self.pid("serve"), self.pid("mlx")
        self.assertEqual((s["state"], s["pid"], s["port"], s["pi"]), ("up", serve, self.port, False))
        self.assertEqual(s["batch"], {"decode_concurrency": 2, "prompt_concurrency": 1,
                                      "prompt_cache_size": 4, "prompt_cache_gb": 4})
        self.assertIsInstance(s["uptime_s"], int)
        human = self.ok("status").stdout
        self.assertIn("state   up", human)
        self.assertIn("batch   decode 2, prompt 1; prompt cache 4 entries, 4 GB", human)

        self.assertIn(f"already up: pid {serve}", self.ok("up").stdout)
        self.assertEqual(self.pid("serve"), serve)

        self.assertIn("model is unloaded", self.ok("down").stdout)
        with open(os.path.join(self.home, "mlx.exited")) as f:
            self.assertEqual(int(f.read()), mlx)  # exited before down returned
        self.assertFalse(running(mlx) or running(serve))
        self.assertEqual(os.listdir(self.run_dir), [])
        self.assertEqual(self.status(), {**s, "state": "down", "pid": None, "pi": False,
                                         "uptime_s": None, "batch": None})
        self.assertIn("already down", self.ok("down").stdout)

    def test_waits_for_load_and_env_settings(self):
        r = self.ok("up", FAKE_MLX_LOAD_S="2", INKLING_DECODE_CONCURRENCY="4")
        self.assertIn("loading the model", r.stdout)
        s = self.status()
        self.assertEqual((s["state"], s["batch"]["decode_concurrency"]), ("up", 4))

    def test_pi_mode(self):
        self.ok("up", "pi")
        self.assertTrue(self.status()["pi"])
        self.assertIn("and the container network (pi)", self.ok("status").stdout)
        self.assertIn("already up", self.ok("up").stdout)  # pi also listens on loopback
        self.ok("down")
        self.ok("up")
        r = self.inkling("up", "pi")
        self.assertEqual(r.returncode, 1)
        self.assertIn("running without pi", r.stderr)

    def test_stale_pid_files_are_not_killed(self):
        other = subprocess.Popen(["sleep", "60"])
        self.addCleanup(other.wait)
        self.addCleanup(other.kill)
        os.makedirs(self.run_dir)
        for name, text in (("serve", f"{other.pid}\nThu Jan  1 00:00:00 1970\n"),
                           ("mlx", f"{other.pid}\n"), ("gateway", "not-a-pid\n")):
            with open(os.path.join(self.run_dir, f"{name}.pid"), "w") as f:
                f.write(text)
        self.assertEqual(self.status()["state"], "down")
        self.assertIn("already down", self.ok("down").stdout)
        self.assertTrue(running(other.pid))
        self.assertEqual(os.listdir(self.run_dir), [])
        with open(os.path.join(self.run_dir, "serve.pid"), "w") as f:
            f.write(f"{other.pid}\nThu Jan  1 00:00:00 1970\n")
        self.ok("up")
        self.assertNotEqual(self.pid("serve"), other.pid)
        self.ok("down")
        self.assertTrue(running(other.pid))

    def test_up_reports_a_failed_start(self):
        r = self.inkling("up", FAKE_MLX_FAIL="1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("exited before the model was ready", r.stderr)
        self.assertIn("failing on purpose", r.stderr)
        self.assertEqual(self.status()["state"], "down")

    def test_up_timeout_leaves_it_loading(self):
        r = self.inkling("up", FAKE_MLX_LOAD_S="60", INKLING_UP_TIMEOUT="1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("still loading after 1s", r.stderr)
        self.assertEqual(self.status()["state"], "loading")
        self.ok("down")
        self.assertEqual(self.status()["state"], "down")

    def test_down_kills_a_server_that_will_not_exit(self):
        self.ok("up", FAKE_MLX_EXIT_S="60")
        mlx = self.pid("mlx")
        r = self.ok("down", INKLING_DOWN_TIMEOUT="1")
        self.assertIn("sending KILL", r.stderr)
        self.assertFalse(running(mlx))

    def test_leftovers_after_serve_sh_dies(self):
        self.ok("up")
        serve, mlx, gw = self.pid("serve"), self.pid("mlx"), self.pid("gateway")
        os.kill(serve, signal.SIGKILL)
        for _ in range(50):
            if not running(serve):
                break
            time.sleep(0.1)
        s = self.status()
        self.assertEqual((s["state"], s["pid"]), ("orphaned", mlx))
        r = self.inkling("up")
        self.assertEqual(r.returncode, 1)
        self.assertIn("left over", r.stderr)
        r = subprocess.run([os.path.join(HERE, "serve.sh")], env=self.env, capture_output=True,
                           text=True, timeout=20)
        self.assertEqual(r.returncode, 1)
        self.assertIn("already running: mlx", r.stderr)
        self.assertIn("leftover", self.ok("down").stdout)
        self.assertFalse(running(mlx) or running(gw))

    def test_serve_sh_refuses_a_second_server(self):
        self.ok("up")
        r = subprocess.run([os.path.join(HERE, "serve.sh")], env=self.env, capture_output=True,
                           text=True, timeout=20)
        self.assertEqual(r.returncode, 1)
        self.assertIn("already running: serve", r.stderr)
        self.assertEqual(self.status()["state"], "up")  # its pid files are untouched

    def test_foreground_serve_is_seen_and_stopped(self):
        p = subprocess.Popen([INKLING, "serve"], env=self.env, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        self.addCleanup(p.wait)
        self.addCleanup(p.kill)
        for _ in range(100):
            if os.path.exists(os.path.join(self.run_dir, "serve.pid")):
                break
            time.sleep(0.1)
        self.ok("up")  # waits for the foreground server instead of starting one
        self.assertEqual(self.status()["pid"], p.pid)
        self.ok("down")
        self.assertEqual(p.wait(timeout=10), 130)

    def test_check_and_usage(self):
        self.assertEqual(self.ok("check").stdout.strip(), f"fake check http://127.0.0.1:{self.port}")
        for args in ((), ("bogus",), ("up", "x"), ("down", "x"), ("status", "--yaml"), ("serve", "x"),
                     ("uninstall", "--all")):
            r = self.inkling(*args)
            self.assertEqual(r.returncode, 2, args)
            self.assertIn("inkling up [pi]", r.stderr)
        r = self.inkling("up", INKLING_UP_TIMEOUT="0")
        self.assertEqual(r.returncode, 1)
        self.assertIn("INKLING_UP_TIMEOUT must be a positive integer", r.stderr)


if __name__ == "__main__":
    unittest.main()

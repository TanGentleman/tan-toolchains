"""python3 test_eval.py: task schema, checks, runs, --jobs and bench.py with a fake
Pi, and serve.sh settings with a fake mlx_lm.server."""
import glob
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

import bench
import eval as ev

HERE = os.path.dirname(os.path.abspath(__file__))
GOOD = {"v": 1, "id": "t", "prompt": "do it", "files": {"in.txt": "b\na\n"},
        "checks": [{"type": "file_equals", "path": "out.txt", "text": "a\nb"},
                   {"type": "file_unchanged", "path": "in.txt"}]}
# Fake Pi: reads the prompt on stdin, sorts in.txt into out.txt.
SORTER = [sys.executable, "-c",
          "import sys; sys.stdin.read(); open('out.txt','w').write(''.join(sorted(open('in.txt'))));"
          "print('{\"type\": \"agent_end\"}');"]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def task(self, t):
        p = os.path.join(self.dir, "task.json")
        with open(p, "w") as f:
            json.dump(t, f)
        return p


class Schema(Base):
    def test_shipped_tasks_load(self):
        paths = glob.glob(os.path.join(HERE, "evals", "*.json"))
        self.assertTrue(paths)
        for p in paths:
            t = ev.load_task(p)
            self.assertEqual(os.path.basename(p), t["id"] + ".json")

    def test_good(self):
        t = ev.load_task(self.task(GOOD))
        self.assertEqual(t["timeout_s"], 900)
        self.assertEqual(len(t["sha256"]), 64)

    def test_refusals(self):
        bad = [
            {**GOOD, "v": 2},
            {k: v for k, v in GOOD.items() if k != "v"},
            {**GOOD, "extra": 1},
            {**GOOD, "id": "Bad Id"},
            {**GOOD, "prompt": " "},
            {**GOOD, "timeout_s": 0},
            {**GOOD, "timeout_s": 1.5},
            {**GOOD, "timeout_s": True},
            {**GOOD, "files": {"../x": ""}},
            {**GOOD, "files": {"/etc/x": ""}},
            {**GOOD, "files": {"a//b": ""}},
            {**GOOD, "files": {"a": 1}},
            {**GOOD, "checks": []},
            {**GOOD, "checks": [{"type": "run", "path": "a"}]},
            {**GOOD, "checks": [{"type": "file_equals", "path": "a"}]},
            {**GOOD, "checks": [{"type": "file_equals", "path": "a", "text": "x", "regex": "x"}]},
            {**GOOD, "checks": [{"type": "file_matches", "path": "a", "regex": "("}]},
            {**GOOD, "checks": [{"type": "file_unchanged", "path": "nope"}]},
            [GOOD],
        ]
        for t in bad:
            with self.subTest(t=t), self.assertRaises(ev.TaskError):
                ev.load_task(self.task(t))
        p = os.path.join(self.dir, "broken.json")
        with open(p, "w") as f:
            f.write("{")
        with self.assertRaises(ev.TaskError):
            ev.load_task(p)


class Checks(Base):
    def write(self, p, text):
        os.makedirs(os.path.dirname(os.path.join(self.dir, p)), exist_ok=True)
        with open(os.path.join(self.dir, p), "w") as f:
            f.write(text)

    def check(self, **c):
        return ev.run_check(c, self.dir, {"seed.txt": "s\n"})

    def test_kinds(self):
        self.write("a/out.txt", "x = 1\nreturn a + b\n")
        self.write("seed.txt", "s\n")
        self.assertTrue(self.check(type="file_equals", path="a/out.txt", text="x = 1\nreturn a + b")[0])
        self.assertFalse(self.check(type="file_equals", path="a/out.txt", text="x = 1")[0])
        self.assertTrue(self.check(type="file_contains", path="a/out.txt", text="a + b")[0])
        self.assertTrue(self.check(type="file_matches", path="a/out.txt", regex=r"^return a \+ b$")[0])
        self.assertFalse(self.check(type="file_matches", path="a/out.txt", regex=r"^a \+ b$")[0])
        self.assertTrue(self.check(type="file_unchanged", path="seed.txt")[0])
        self.write("seed.txt", "changed\n")
        ok, detail = self.check(type="file_unchanged", path="seed.txt")
        self.assertFalse(ok)
        self.assertIn("changed", detail)
        self.assertEqual(self.check(type="file_contains", path="gone", text="x"), (False, "missing"))

    def test_symlinks_refused(self):
        outside = os.path.join(self.dir, "secret")
        self.write("secret", "token")
        work = os.path.join(self.dir, "work")
        os.makedirs(work)
        os.symlink(outside, os.path.join(work, "out.txt"))
        os.symlink(self.dir, os.path.join(work, "d"))
        for p in ("out.txt", "d/secret"):
            ok, detail = ev.run_check({"type": "file_contains", "path": p, "text": "token"}, work, {})
            self.assertFalse(ok)
            self.assertIn("symlink", detail)


class Runs(Base):
    def run_task(self, t, pi, log=""):
        return ev.run_task(ev.load_task(self.task(t)), pi, os.path.join(self.dir, "out"),
                           log or os.path.join(self.dir, "none.jsonl"), {"repo": "r", "revision": "x"})

    def test_pass_and_result_schema(self):
        log = os.path.join(self.dir, "requests.jsonl")
        with open(log, "w") as f:
            f.write(json.dumps({"ts": time.time() - 3600, "status": 200, "usage": {"completion_tokens": 99}}) + "\n")
        pi = SORTER[:2] + [SORTER[2] + (
            f"import json,time; open({log!r},'a').write(json.dumps({{'ts': time.time(), 'status': 200,"
            "'usage': {'prompt_tokens': 7, 'completion_tokens': 3}}) + '\\n'"
            "+ json.dumps({'ts': time.time(), 'status': 502, 'error': 'x'}) + '\\nnot json\\n')")]
        run, r = self.run_task(GOOD, pi, log)
        self.assertTrue(r["ok"], r)
        self.assertEqual(tuple(r), ev.RESULT_KEYS)
        self.assertEqual(r["requests"], {"count": 2, "errors": 1, "prompt_tokens": 7, "completion_tokens": 3})
        with open(os.path.join(run, "result.json")) as f:
            self.assertEqual(json.load(f), r)
        with open(os.path.join(run, "pi.jsonl")) as f:
            self.assertIn("agent_end", f.read())

    def test_wrong_output_fails(self):
        _, r = self.run_task(GOOD, [sys.executable, "-c", "open('out.txt','w').write('b\\na\\n')"])
        self.assertFalse(r["ok"])
        self.assertEqual([c["ok"] for c in r["checks"]], [False, True])

    def test_pi_exit_code_fails(self):
        _, r = self.run_task(GOOD, SORTER[:2] + [SORTER[2] + "sys.exit(3)"])
        self.assertFalse(r["ok"])
        self.assertEqual(r["exit_code"], 3)

    def test_timeout_kills_process_group(self):
        marker = os.path.join(self.dir, "child-alive")
        pi = ["bash", "-c", f"(sleep 3; touch {marker}) & sleep 60"]
        _, r = self.run_task({**GOOD, "timeout_s": 1}, pi)
        self.assertTrue(r["timed_out"])
        self.assertFalse(r["ok"])
        time.sleep(3)
        self.assertFalse(os.path.exists(marker))

    def test_cli(self):
        out = os.path.join(self.dir, "out")
        args = [sys.executable, os.path.join(HERE, "eval.py"), self.task(GOOD), "--out", out,
                "--requests-log", os.path.join(self.dir, "none.jsonl"), "--model", "r@x"]
        p = subprocess.run(args + ["--"] + SORTER, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout, r"^t +[0-9.]+s  ok  0 requests")
        p = subprocess.run(args + ["--", "bash", "-c", "echo run.sh: refused >&2; exit 1"],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertIn("pi.log: run.sh: refused", p.stdout)
        p = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)
        p = subprocess.run(args[:2] + [self.task({**GOOD, "v": 0})] + args[3:] + ["--", "true"],
                           capture_output=True, text=True)
        self.assertIn("v must be 1", p.stderr)


def tagged_pi(log, sleep=1.0, n=2):
    """Fake Pi: prints a session header, logs n gateway records for its session
    (plus one untagged), holds them open for `sleep` s, and sorts in.txt.
    argv[1] is the instance it was given."""
    code = (
        "import json, sys, time, uuid\n"
        "sys.stdin.read()\n"
        "sid = str(uuid.uuid4())\n"
        "print(json.dumps({'type': 'session', 'version': 3, 'id': sid}), flush=True)\n"
        f"log = {log!r}\n"
        f"for i in range({n}):\n"
        "    with open(log, 'a') as f:\n"
        "        f.write(json.dumps({'ts': time.time(), 'status': 200, 'session': sid, 'ttft_ms': 100 * (i + 1),\n"
        "                            'usage': {'prompt_tokens': 10, 'completion_tokens': 1}}) + '\\n')\n"
        "with open(log, 'a') as f:\n"
        "    f.write(json.dumps({'ts': time.time(), 'status': 200, 'usage': {'completion_tokens': 50}}) + '\\n')\n"
        f"time.sleep({sleep})\n"
        "open('instance.txt', 'w').write(sys.argv[1])\n"
        "open('out.txt', 'w').write(''.join(sorted(open('in.txt'))))\n"
    )
    return [sys.executable, "-c", code, "{instance}"]


class Jobs(Base):
    def test_overlapping_runs_count_only_their_session(self):
        log = os.path.join(self.dir, "requests.jsonl")
        tasks = [ev.load_task(self.task(GOOD))] * 4
        seen = []
        t0 = time.monotonic()
        results = ev.run_all(tasks, tagged_pi(log), os.path.join(self.dir, "out"), log,
                             {"repo": "r", "revision": "x"}, jobs=2, done=lambda t, run, r: seen.append(run))
        self.assertLess(time.monotonic() - t0, 3.8)  # 4 x 1 s, two at a time
        self.assertEqual(len(seen), 4)
        self.assertEqual(len({run for run, _ in results}), 4)  # same id and second: own folders
        instances = set()
        for run, r in results:
            self.assertTrue(r["ok"], r)
            self.assertEqual(tuple(r), ev.RESULT_KEYS)
            self.assertEqual(r["v"], 1)
            # The untagged records of overlapping runs (50 tokens each) are not counted.
            self.assertEqual(r["requests"], {"count": 2, "errors": 0, "prompt_tokens": 20, "completion_tokens": 2})
            with open(os.path.join(run, "work", "instance.txt")) as f:
                instances.add(f.read())
        self.assertEqual(instances, {"eval-1", "eval-2"})

    def test_session_less_runs(self):
        log = os.path.join(self.dir, "requests.jsonl")
        pi = SORTER[:2] + [SORTER[2] + (
            f"import json,time; open({log!r},'a').write(json.dumps({{'ts': time.time(), 'status': 200,"
            "'usage': {'completion_tokens': 3}}) + '\\n'); time.sleep(0.5)")]
        tasks = [ev.load_task(self.task(GOOD))] * 2
        # Alone, the time window is safe; overlapped, nothing can be attributed.
        _, alone = ev.run_all(tasks[:1], pi, os.path.join(self.dir, "a"), log, {}, jobs=1)[0]
        self.assertEqual(alone["requests"]["count"], 1)
        both = ev.run_all(tasks, pi, os.path.join(self.dir, "b"), log, {}, jobs=2)
        self.assertEqual([r["requests"]["count"] for _, r in both], [0, 0])

    def test_run_records(self):
        recs = [{"ts": 5, "session": "a"}, {"ts": 6}, {"ts": 7, "session": "b"}, {"ts": 1, "session": "a"}]
        self.assertEqual(ev.run_records(recs, 2, 9, "a", False), [recs[0]])
        self.assertEqual(ev.run_records(recs, 2, 6, None, True), recs[:2])
        self.assertEqual(ev.run_records(recs, 2, 9, None, False), [])

    def test_pi_session(self):
        run = os.path.join(self.dir, "run")
        os.makedirs(run)
        self.assertIsNone(ev.pi_session(run))
        with open(os.path.join(run, "pi.jsonl"), "w") as f:
            f.write('not json\n{"type": "session", "id": "019a-x"}\n')
        self.assertEqual(ev.pi_session(run), "019a-x")

    def test_cli_jobs(self):
        out, log = os.path.join(self.dir, "out"), os.path.join(self.dir, "requests.jsonl")
        args = [sys.executable, os.path.join(HERE, "eval.py"), self.task(GOOD), self.task(GOOD),
                "--out", out, "--requests-log", log]
        p = subprocess.run(args + ["--jobs", "2", "--"] + tagged_pi(log, 0.2), capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.count(" ok  2 requests, 2 tokens out"), 2)
        for jobs, pi, err in (("2", SORTER, "needs {instance}"), ("0", SORTER, "--jobs must be"),
                              ("9", tagged_pi(log), "--jobs must be")):
            p = subprocess.run(args + ["--jobs", jobs, "--"] + pi, capture_output=True, text=True)
            self.assertEqual(p.returncode, 2, jobs)
            self.assertIn(err, p.stderr)

    def test_interrupt_stops_running_tasks(self):
        marker = os.path.join(self.dir, "alive")
        t = self.task({**GOOD, "timeout_s": 60})
        p = subprocess.Popen([sys.executable, os.path.join(HERE, "eval.py"), t, t, "--jobs", "2",
                              "--out", os.path.join(self.dir, "out"), "--requests-log", "/dev/null", "--",
                              "bash", "-c", f"(sleep 3; touch {marker}) & sleep 60", "{instance}"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(1)
        p.send_signal(signal.SIGINT)
        self.assertEqual(p.wait(20), 130)
        time.sleep(3)
        self.assertFalse(os.path.exists(marker))


class Bench(Base):
    def test_summarize(self):
        runs = []
        for i, sid in enumerate(("s1", "s2", None)):
            run = os.path.join(self.dir, f"r{i}")
            os.makedirs(run)
            with open(os.path.join(run, "pi.jsonl"), "w") as f:
                f.write(json.dumps({"type": "session", "id": sid}) + "\n" if sid else "")
            runs.append((run, {"ok": i != 1}))
        recs = [{"ts": 1, "status": 200, "session": "s1", "ttft_ms": 300, "usage": {"prompt_tokens": 5, "completion_tokens": 1}},
                {"ts": 1, "status": 200, "session": "s2", "ttft_ms": 100, "usage": {"prompt_tokens": 5, "completion_tokens": 2}},
                {"ts": 1, "status": 200, "session": "s2", "ttft_ms": 200},
                {"ts": 1, "status": 200, "session": "old", "ttft_ms": 9000, "usage": {"completion_tokens": 99}}]
        s = bench.summarize(2, runs, recs, 1800.0)
        self.assertEqual(s, {"jobs": 2, "tasks": 3, "passed": 2, "wall_s": 1800.0, "tasks_per_hour": 6.0,
                             "passed_per_hour": 4.0, "requests": 3, "errors": 0, "prompt_tokens": 10,
                             "completion_tokens": 3, "total_tokens": 13, "p50_ttft_ms": 200, "untagged_sessions": 1})
        self.assertIn("p50 ttft s", bench.table([s]))

    def test_cli(self):
        out, log = os.path.join(self.dir, "bench"), os.path.join(self.dir, "requests.jsonl")
        info = os.path.join(self.dir, "serve.json")
        with open(info, "w") as f:
            json.dump({"decode_concurrency": 1}, f)
        args = [sys.executable, os.path.join(HERE, "bench.py"), self.task(GOOD), "--out", out,
                "--requests-log", log, "--serve-info", info, "--model", "r@x"]
        p = subprocess.run(args + ["--jobs", "1,2", "--repeat", "2", "--"] + tagged_pi(log, 0.2),
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("INKLING_DECODE_CONCURRENCY=2", p.stderr)
        [path] = glob.glob(os.path.join(out, "*", "bench.json"))
        with open(path) as f:
            b = json.load(f)
        self.assertEqual(b["v"], 1)
        self.assertEqual(b["serve"], {"decode_concurrency": 1})
        self.assertEqual([(s["jobs"], s["tasks"], s["passed"], s["requests"], s["completion_tokens"],
                           s["p50_ttft_ms"], s["untagged_sessions"]) for s in b["levels"]],
                         [(1, 2, 2, 4, 4, 150, 0), (2, 2, 2, 4, 4, 150, 0)])
        self.assertEqual(len(glob.glob(os.path.join(out, "*", "jobs-2", "*", "result.json"))), 2)
        for bad in (["--jobs", "0"], ["--jobs", "1,x"], ["--repeat", "0"]):
            p = subprocess.run(args + bad + ["--"] + tagged_pi(log), capture_output=True, text=True)
            self.assertEqual(p.returncode, 2, bad)
        p = subprocess.run(args + ["--"] + SORTER, capture_output=True, text=True)
        self.assertIn("needs {instance}", p.stderr)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Serve(Base):
    """serve.sh with a fake venv: real gateway.py, fake mlx_lm.server that records its argv."""

    def setUp(self):
        super().setUp()
        home = self.home = os.path.join(self.dir, "home")
        bin_ = os.path.join(home, "venv", "bin")
        os.makedirs(bin_)
        os.makedirs(os.path.join(home, "logs"))
        os.makedirs(os.path.join(home, "run"))
        os.symlink(sys.executable, os.path.join(bin_, "python"))
        with open(os.path.join(bin_, "mlx_lm.server"), "w") as f:
            f.write(f'#!/bin/sh\nprintf "%s\\n" "$@" > {home}/mlx.args\ntrap "exit 0" TERM\nsleep 60 & wait\n')
        os.chmod(os.path.join(bin_, "mlx_lm.server"), 0o755)
        model = os.path.join(self.dir, "model")
        os.makedirs(model)
        open(os.path.join(model, "config.json"), "w").close()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("INKLING_", "PI_"))}
        self.env.update(INKLING_HOME=home, INKLING_MODEL_DIR=model,
                        INKLING_PORT=str(free_port()), INKLING_MLX_PORT=str(free_port()))

    def serve(self, **env):
        return subprocess.Popen([os.path.join(HERE, "serve.sh")], env={**self.env, **env},
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)

    def wait_for(self, path):
        for _ in range(100):
            if os.path.exists(path):
                return
            time.sleep(0.1)
        self.fail(f"no {path}")

    def flags(self):
        with open(os.path.join(self.home, "mlx.args")) as f:
            a = f.read().split()
        return {k: a[a.index(k) + 1] for k in ("--decode-concurrency", "--prompt-concurrency",
                                                "--prompt-cache-size", "--prompt-cache-bytes")}

    def test_defaults_env_and_ctrl_c(self):
        for env, want in (({}, ("2", "1", "4", str(4 << 30))),
                          ({"INKLING_DECODE_CONCURRENCY": "4", "INKLING_PROMPT_CONCURRENCY": "2",
                            "INKLING_PROMPT_CACHE_SIZE": "6", "INKLING_PROMPT_CACHE_GB": "5"},
                           ("4", "2", "6", str(5 << 30)))):
            with self.subTest(env=env):
                p = self.serve(**env)
                info = os.path.join(self.home, "run", "serve.json")
                self.wait_for(os.path.join(self.home, "mlx.args"))
                self.wait_for(info)
                self.assertEqual(tuple(self.flags().values()), want)
                with open(info) as f:
                    self.assertEqual(json.load(f)["decode_concurrency"], int(want[0]))
                with open(os.path.join(self.home, "run", "mlx.pid")) as f:
                    mlx = int(f.readline())
                p.send_signal(signal.SIGINT)
                p.communicate(timeout=20)
                self.assertEqual(p.returncode, 130)
                self.assertRaises(ProcessLookupError, os.kill, mlx, 0)  # unloaded on return
                self.assertFalse(os.path.exists(info))
                os.remove(os.path.join(self.home, "mlx.args"))

    def test_refuses_bad_values(self):
        for v in ("0", "-1", "2x", "08"):
            p = self.serve(INKLING_DECODE_CONCURRENCY=v)
            _, err = p.communicate(timeout=20)
            self.assertEqual(p.returncode, 1, v)
            self.assertIn("INKLING_DECODE_CONCURRENCY must be a positive integer", err)
            self.assertFalse(os.path.exists(os.path.join(self.home, "mlx.args")))


if __name__ == "__main__":
    unittest.main()

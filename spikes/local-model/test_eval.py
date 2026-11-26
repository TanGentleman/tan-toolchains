"""eval.py: task schema, checks and runs with a fake Pi."""
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


class Sessions(Base):
    def test_run_counts_only_its_session(self):
        log = os.path.join(self.dir, "requests.jsonl")
        # Fake Pi: a session header, two records for its session and one without.
        pi = [sys.executable, "-c",
              "import json, sys, time\n"
              "sys.stdin.read()\n"
              "print(json.dumps({'type': 'session', 'version': 3, 'id': 's1'}))\n"
              f"with open({log!r}, 'a') as f:\n"
              "    for s in ('s1', 's1', None):\n"
              "        f.write(json.dumps({'ts': time.time(), 'status': 200, 'session': s,\n"
              "                            'usage': {'prompt_tokens': 10, 'completion_tokens': 1}}) + '\\n')\n"
              "open('out.txt', 'w').write(''.join(sorted(open('in.txt'))))\n"]
        [(run, r)] = ev.run_all([ev.load_task(self.task(GOOD))], pi, os.path.join(self.dir, "out"), log,
                                {"repo": "r", "revision": "x"})
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["requests"], {"count": 2, "errors": 0, "prompt_tokens": 20, "completion_tokens": 2})

    def test_run_records(self):
        recs = [{"ts": 5, "session": "a"}, {"ts": 6}, {"ts": 7, "session": "b"}, {"ts": 1, "session": "a"}]
        self.assertEqual(ev.run_records(recs, 2, 9, "a"), [recs[0]])
        self.assertEqual(ev.run_records(recs, 2, 6, None), recs[:2])

    def test_pi_session(self):
        run = os.path.join(self.dir, "run")
        os.makedirs(run)
        self.assertIsNone(ev.pi_session(run))
        with open(os.path.join(run, "pi.jsonl"), "w") as f:
            f.write('not json\n{"type": "session", "id": "019a-x"}\n')
        self.assertEqual(ev.pi_session(run), "019a-x")

    def test_interrupt_stops_the_running_task(self):
        marker = os.path.join(self.dir, "alive")
        p = subprocess.Popen([sys.executable, os.path.join(HERE, "eval.py"), self.task({**GOOD, "timeout_s": 60}),
                              "--out", os.path.join(self.dir, "out"), "--requests-log", "/dev/null", "--",
                              "bash", "-c", f"(sleep 3; touch {marker}) & sleep 60"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(1)
        p.send_signal(signal.SIGINT)
        self.assertEqual(p.wait(20), 130)
        time.sleep(3)
        self.assertFalse(os.path.exists(marker))


if __name__ == "__main__":
    unittest.main()

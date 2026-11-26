#!/usr/bin/env python3
"""Offline evals: Pi, in pi-container with offline egress, does a small task in
a fresh folder; the files it leaves are checked on the host. Model calls go
only to the local gateway. Tasks run one at a time. Stdlib only.

Task file (evals/*.json), "v": 1:
  {"v": 1, "id": "sort-names", "prompt": "...", "timeout_s": 900,
   "files": {"names.txt": "..."},
   "checks": [{"type": "file_equals", "path": "sorted.txt", "text": "..."}]}
Check types: file_equals, file_contains, file_matches (regex), file_unchanged.
Checks only read files; nothing Pi writes is run on the host.

Each run writes <out>/<run>/{work/, pi.jsonl, pi.log, result.json}; result.json
is "v": 1 (see RESULT_KEYS). Its "requests" are the gateway log lines that carry
the session id from Pi's first pi.jsonl line, else those in its time window.

  eval.py [TASK.json ...] --out DIR --requests-log FILE [--model REPO@REV] -- PI_COMMAND..."""
import argparse
import datetime
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time

V = 1
CHECKS = {"file_equals": "text", "file_contains": "text", "file_matches": "regex", "file_unchanged": None}
TASK_KEYS = {"v", "id", "prompt", "timeout_s", "files", "checks"}
RESULT_KEYS = ("v", "task", "task_sha256", "started", "ok", "exit_code", "timed_out",
               "seconds", "model", "requests", "checks")
ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")


class TaskError(ValueError):
    pass


def rel_path(p, where):
    if not isinstance(p, str) or not p or p.startswith("/") or "\\" in p:
        raise TaskError(f"{where}: path must be relative: {p!r}")
    if any(part in ("", ".", "..") for part in p.split("/")):
        raise TaskError(f"{where}: bad path {p!r}")
    return p


def load_task(path):
    with open(path, "rb") as f:
        raw = f.read()
    try:
        t = json.loads(raw)
    except json.JSONDecodeError as e:
        raise TaskError(f"{path}: {e}")
    if not isinstance(t, dict):
        raise TaskError(f"{path}: not an object")
    if t.get("v") != V:
        raise TaskError(f"{path}: v must be {V}, got {t.get('v')!r}")
    extra, missing = set(t) - TASK_KEYS, {"id", "prompt", "checks"} - set(t)
    if extra or missing:
        raise TaskError(f"{path}: unknown keys {sorted(extra)}, missing {sorted(missing)}")
    if not isinstance(t["id"], str) or not ID.match(t["id"]):
        raise TaskError(f"{path}: id must match {ID.pattern}")
    if not isinstance(t["prompt"], str) or not t["prompt"].strip():
        raise TaskError(f"{path}: prompt must be a non-empty string")
    t.setdefault("timeout_s", 900)
    if type(t["timeout_s"]) is not int or not 1 <= t["timeout_s"] <= 7200:
        raise TaskError(f"{path}: timeout_s must be an integer in 1..7200")
    files = t.setdefault("files", {})
    if not isinstance(files, dict) or not all(isinstance(v, str) for v in files.values()):
        raise TaskError(f"{path}: files must map paths to strings")
    for p in files:
        rel_path(p, f"{path}: files")
    if not isinstance(t["checks"], list) or not t["checks"]:
        raise TaskError(f"{path}: checks must be a non-empty list")
    for i, c in enumerate(t["checks"]):
        where = f"{path}: checks[{i}]"
        if not isinstance(c, dict) or c.get("type") not in CHECKS:
            raise TaskError(f"{where}: type must be one of {sorted(CHECKS)}")
        arg = CHECKS[c["type"]]
        want = {"type", "path"} | ({arg} if arg else set())
        if set(c) != want:
            raise TaskError(f"{where}: keys must be {sorted(want)}")
        rel_path(c["path"], where)
        if arg and not isinstance(c[arg], str):
            raise TaskError(f"{where}: {arg} must be a string")
        if arg == "regex":
            try:
                re.compile(c["regex"])
            except re.error as e:
                raise TaskError(f"{where}: regex: {e}")
        if c["type"] == "file_unchanged" and c["path"] not in files:
            raise TaskError(f"{where}: file_unchanged needs {c['path']!r} in files")
    t["sha256"] = hashlib.sha256(raw).hexdigest()
    return t


def read_in(work, p):
    """Text of work/p, or None. Refuses symlinks: Pi's paths are host paths too."""
    cur = work
    for part in p.split("/"):
        cur = os.path.join(cur, part)
        if os.path.islink(cur):
            raise OSError(f"{p} is or passes through a symlink")
    if not os.path.isfile(cur):
        return None
    with open(cur, "rb") as f:
        return f.read(1 << 20).decode("utf-8", errors="replace")


def run_check(c, work, files):
    try:
        got = read_in(work, c["path"])
    except OSError as e:
        return False, str(e)
    if got is None:
        return False, "missing"
    kind = c["type"]
    if kind == "file_equals":
        ok = got.strip() == c["text"].strip()
    elif kind == "file_contains":
        ok = c["text"] in got
    elif kind == "file_matches":
        ok = re.search(c["regex"], got, re.M) is not None
    else:
        ok = got == files[c["path"]]
    return ok, "" if ok else f"got {got[:200]!r}"


def read_log(log):
    """Gateway log records (dicts); unreadable lines are skipped."""
    try:
        with open(log) as f:
            lines = f.readlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(r, dict) and isinstance(r.get("ts", 0), (int, float)):
            out.append(r)
    return out


def pi_session(run):
    """Session id from Pi's JSON-mode header line, or None."""
    try:
        with open(os.path.join(run, "pi.jsonl"), errors="replace") as f:
            for _, line in zip(range(20), f):
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(e, dict) and e.get("type") == "session" and isinstance(e.get("id"), str):
                    return e["id"]
    except OSError:
        pass
    return None


def run_records(records, since, until, session):
    """This run's requests: by session id, else by time window."""
    if session:
        return [r for r in records if r.get("session") == session and r.get("ts", 0) >= since]
    return [r for r in records if since <= r.get("ts", 0) <= until]


def gateway_requests(records):
    out = {"count": 0, "errors": 0, "prompt_tokens": 0, "completion_tokens": 0}
    for r in records:
        out["count"] += 1
        out["errors"] += r.get("status") != 200 or "error" in r
        u = r.get("usage") or {}
        out["prompt_tokens"] += u.get("prompt_tokens") or 0
        out["completion_tokens"] += u.get("completion_tokens") or 0
    return out


def new_run_dir(out_dir, started, task_id):
    base = os.path.join(out_dir, started.strftime("%Y%m%dT%H%M%SZ") + "-" + task_id)
    run, n = base, 1
    while True:
        try:
            os.makedirs(run)
            return run
        except FileExistsError:
            n += 1
            run = f"{base}-{n}"


def run_task(t, pi_cmd, out_dir, requests_log, model):
    started = datetime.datetime.now(datetime.timezone.utc)
    run = new_run_dir(out_dir, started, t["id"])
    work = os.path.join(run, "work")
    os.makedirs(work)
    for p, text in t["files"].items():
        os.makedirs(os.path.dirname(os.path.join(work, p)), exist_ok=True)
        with open(os.path.join(work, p), "w") as f:
            f.write(text)
    t0, wall0 = time.monotonic(), time.time()
    timed_out = False
    with open(os.path.join(run, "pi.jsonl"), "wb") as so, open(os.path.join(run, "pi.log"), "wb") as se:
        p = subprocess.Popen(pi_cmd, cwd=work, stdin=subprocess.PIPE, stdout=so, stderr=se,
                             start_new_session=True)
        try:
            p.communicate(t["prompt"].encode(), timeout=t["timeout_s"])
        except subprocess.TimeoutExpired:
            timed_out = True
            stop(p)
        except KeyboardInterrupt:
            stop(p)
            raise
    wall1 = time.time()
    checks = []
    for c in t["checks"]:
        ok, detail = run_check(c, work, t["files"])
        checks.append({"type": c["type"], "path": c["path"], "ok": ok, "detail": detail})
    result = {
        "v": V, "task": t["id"], "task_sha256": t["sha256"],
        "started": started.isoformat(timespec="seconds"),
        "ok": p.returncode == 0 and not timed_out and all(c["ok"] for c in checks),
        "exit_code": p.returncode, "timed_out": timed_out,
        "seconds": round(time.monotonic() - t0, 1), "model": model,
        "requests": gateway_requests(run_records(read_log(requests_log), wall0, wall1,
                                                 pi_session(run))),
        "checks": checks,
    }
    with open(os.path.join(run, "result.json"), "w") as f:
        json.dump(result, f, indent=2)
        f.write("\n")
    return run, result


def stop(p):
    """SIGTERM the process group (run.sh, container), then SIGKILL after 30 s."""
    try:
        os.killpg(p.pid, signal.SIGTERM)
        p.wait(30)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
    except ProcessLookupError:
        pass


def run_all(tasks, pi_cmd, out_dir, requests_log, model, done=None):
    """Run tasks one at a time; done(task, run, result) as each ends."""
    results = []
    for t in tasks:
        run, r = run_task(t, pi_cmd, out_dir, requests_log, model)
        results.append((run, r))
        if done:
            done(t, run, r)
    return results


def print_result(t, run, r):
    why = "timeout" if r["timed_out"] else f"exit {r['exit_code']}" if r["exit_code"] else \
        "; ".join(f"{c['path']}: {c['type']} {c['detail']}" for c in r["checks"] if not c["ok"])
    n = r["requests"]
    print(f"{t['id']:<16} {r['seconds']:6.1f}s  {'ok' if r['ok'] else 'FAIL'}  "
          f"{n['count']} requests, {n['completion_tokens']} tokens out  {why}".rstrip())
    if r["exit_code"]:
        with open(os.path.join(run, "pi.log"), errors="replace") as f:
            for line in f.read().splitlines()[-5:]:
                print(f"{'':<16} pi.log: {line}")
    print(f"{'':<16} {run}/result.json", flush=True)


def parse_args(ap, argv):
    """argparse for the part before --; returns (args, PI_COMMAND)."""
    if "--" not in argv or argv.index("--") == len(argv) - 1:
        ap.error("needs -- PI_COMMAND...; the prompt goes on its stdin")
    i = argv.index("--")
    return ap.parse_args(argv[:i]), argv[i + 1:]


def load_tasks(paths, here):
    paths = paths or sorted(os.path.join(here, "evals", f)
                            for f in os.listdir(os.path.join(here, "evals")) if f.endswith(".json"))
    try:
        return [load_task(p) for p in paths]
    except (OSError, TaskError) as e:
        sys.exit(f"eval: {e}")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Run offline eval tasks with Pi.")
    ap.add_argument("tasks", nargs="*", help="task files (default: evals/*.json)")
    ap.add_argument("--out", required=True, help="directory for runs")
    ap.add_argument("--requests-log", required=True, help="gateway requests.jsonl")
    ap.add_argument("--model", default="", help="repo@revision, recorded in result.json")
    a, pi = parse_args(ap, sys.argv[1:])
    tasks = load_tasks(a.tasks, here)
    repo, _, rev = a.model.partition("@")
    try:
        results = run_all(tasks, pi, a.out, a.requests_log, {"repo": repo, "revision": rev},
                          print_result)
    except KeyboardInterrupt:
        sys.exit(130)
    sys.exit(0 if all(r["ok"] for _, r in results) else 1)


if __name__ == "__main__":
    main()

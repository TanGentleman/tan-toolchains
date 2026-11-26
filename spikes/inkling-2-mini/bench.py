#!/usr/bin/env python3
"""Throughput benchmark: the eval set at several --jobs levels, one after the
other, against the running serve.sh. Per level: tasks/hour, tokens, and p50
time to first token, from the gateway log lines of that level's Pi sessions.
Writes <out>/<time>/{jobs-N/<run>/..., bench.json}. Stdlib only.

  bench.py [TASK.json ...] --out DIR --requests-log FILE [--jobs 1,2,4] [--repeat R]
           [--serve-info FILE] [--model REPO@REV] -- PI_COMMAND..."""
import argparse
import datetime
import json
import os
import statistics
import sys
import time

import eval as ev

V = 1


def parse_levels(text):
    try:
        levels = [int(x) for x in text.split(",")]
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a list of integers: {text!r}")
    if not levels or any(not 1 <= n <= ev.MAX_JOBS for n in levels):
        raise argparse.ArgumentTypeError(f"each level must be in 1..{ev.MAX_JOBS}")
    return levels


def summarize(jobs, results, records, wall_s):
    """One level's numbers. results: [(run, result)]; records: the whole gateway log."""
    sessions = {ev.pi_session(run) for run, _ in results} - {None}
    mine = [r for r in records if r.get("session") in sessions]
    ttft = [r["ttft_ms"] for r in mine if isinstance(r.get("ttft_ms"), (int, float))]
    req = ev.gateway_requests(mine)
    n, ok = len(results), sum(r["ok"] for _, r in results)
    return {
        "jobs": jobs, "tasks": n, "passed": ok, "wall_s": round(wall_s, 1),
        "tasks_per_hour": round(n * 3600 / wall_s, 1) if wall_s else None,
        "passed_per_hour": round(ok * 3600 / wall_s, 1) if wall_s else None,
        "requests": req["count"], "errors": req["errors"],
        "prompt_tokens": req["prompt_tokens"], "completion_tokens": req["completion_tokens"],
        "total_tokens": req["prompt_tokens"] + req["completion_tokens"],
        "p50_ttft_ms": round(statistics.median(ttft)) if ttft else None,
        "untagged_sessions": n - len(sessions),
    }


def table(levels):
    rows = [("jobs", "tasks", "passed", "wall s", "tasks/h", "prompt tok", "output tok", "total tok", "p50 ttft s")]
    for s in levels:
        p50 = "-" if s["p50_ttft_ms"] is None else f"{s['p50_ttft_ms'] / 1000:.1f}"
        rows.append((str(s["jobs"]), str(s["tasks"]), str(s["passed"]), f"{s['wall_s']:.0f}",
                     f"{s['tasks_per_hour']}", str(s["prompt_tokens"]), str(s["completion_tokens"]),
                     str(s["total_tokens"]), p50))
    w = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    return "\n".join("  ".join(c.rjust(w[i]) for i, c in enumerate(r)) for r in rows)


def read_serve_info(path):
    try:
        with open(path) as f:
            info = json.load(f)
        return info if isinstance(info, dict) else {}
    except (OSError, ValueError):
        return {}


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Eval throughput at several --jobs levels.")
    ap.add_argument("tasks", nargs="*", help="task files (default: evals/*.json)")
    ap.add_argument("--out", required=True, help="directory for benchmarks")
    ap.add_argument("--requests-log", required=True, help="gateway requests.jsonl")
    ap.add_argument("--model", default="", help="repo@revision, recorded in result.json")
    ap.add_argument("--jobs", type=parse_levels, default=[1, 2, 4], help="levels (default 1,2,4)")
    ap.add_argument("--repeat", type=int, default=2, help="copies of the task set per level (default 2)")
    ap.add_argument("--serve-info", help="serve.sh's settings file, recorded in bench.json")
    argv = sys.argv[1:]
    if "--" not in argv or argv.index("--") == len(argv) - 1:
        ap.error("needs -- PI_COMMAND...; the prompt goes on its stdin")
    i = argv.index("--")
    a, pi = ap.parse_args(argv[:i]), argv[i + 1:]
    if not 1 <= a.repeat <= 20:
        ap.error("--repeat must be in 1..20")
    if not any("{instance}" in x for x in pi):
        ap.error("needs {instance} in PI_COMMAND so each task gets its own container")
    tasks = ev.load_tasks(a.tasks, here) * a.repeat
    serve = read_serve_info(a.serve_info) if a.serve_info else {}
    started = datetime.datetime.now(datetime.timezone.utc)
    out = os.path.join(a.out, started.strftime("%Y%m%dT%H%M%SZ"))
    os.makedirs(out)
    if serve.get("decode_concurrency") and max(a.jobs) > serve["decode_concurrency"]:
        print(f"bench: serve.sh decodes {serve['decode_concurrency']} at once; levels above that "
              "queue at the model. Restart it with INKLING_DECODE_CONCURRENCY="
              f"{max(a.jobs)} to measure them.", file=sys.stderr)
    repo, _, rev = a.model.partition("@")
    levels = []
    for jobs in a.jobs:
        print(f"== jobs {jobs}: {len(tasks)} tasks", flush=True)
        t0 = time.monotonic()
        try:
            results = ev.run_all(tasks, pi, os.path.join(out, f"jobs-{jobs}"), a.requests_log,
                                 {"repo": repo, "revision": rev}, jobs, ev.print_result)
        except KeyboardInterrupt:
            sys.exit(130)
        levels.append(summarize(jobs, results, ev.read_log(a.requests_log), time.monotonic() - t0))
    report = {"v": V, "started": started.isoformat(timespec="seconds"),
              "model": {"repo": repo, "revision": rev}, "serve": serve,
              "task_ids": [t["id"] for t in tasks], "levels": levels}
    with open(os.path.join(out, "bench.json"), "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    print()
    print(table(levels))
    untagged = sum(s["untagged_sessions"] for s in levels)
    if untagged:
        print(f"bench: {untagged} runs had no Pi session id; their requests are not counted", file=sys.stderr)
    print(f"\n{out}/bench.json")


if __name__ == "__main__":
    main()

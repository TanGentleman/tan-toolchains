"""Keyless Lens CLI run: Pi through LiteLLM beside Pi through fleetd, both on
the fake OpenRouter. Started by e2e/lens.sh, which sets the environment."""

import asyncio
import json
import os
import time
import urllib.request
import uuid

from litellm import AgentInput, AgentOutput, EvalAgent, EvalTarget, EvalTask, Harness, PredicateCheck
from litellm.harness.types import Usage

FLEET = os.environ["FLEET_URL"]
OWNER = os.environ.get("FLEET_OWNER", "tan")
RUN = uuid.uuid4().hex[:8]


def api(method: str, path: str, body: dict | None = None) -> bytes:
    req = urllib.request.Request(
        FLEET + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Tailscale-User-Login": OWNER, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


class FleetPi(EvalAgent):
    """Each "---" line in the prompt starts another fleet turn in the same session."""

    def turns(self, task: AgentInput) -> AgentOutput:
        prompts = task.prompt.split("\n---\n")
        key = f"lens-{RUN}-{task.task_id}-{task.trial}"
        sid = json.loads(api("POST", "/v1/sessions", {"harness": "pi", "model": "fake/model", "title": task.task_id, "key": key, "prompt": prompts[0]}))["sid"]
        for i, p in enumerate(prompts, 1):
            if i > 1:
                api("POST", f"/v1/sessions/{sid}/inputs", {"key": f"{key}-{i}", "text": p})
            for _ in range(600):
                st = json.loads(api("GET", f"/v1/sessions/{sid}"))
                if st["run"] >= i and not st["running"]:
                    break
                time.sleep(0.05)
        text, use, failed = "", Usage(), False
        for raw in api("GET", f"/v1/sessions/{sid}/events").splitlines():
            e = json.loads(raw)
            if e["kind"] == "exited" and (e.get("data") or {}).get("code"):
                failed = True
            if e["kind"] != "out":
                continue
            m = json.loads(e["data"])
            if m.get("type") == "message_end" and m["message"].get("role") == "assistant":
                text = "".join(c.get("text", "") for c in m["message"].get("content", []))
            if m.get("type") == "fleet.turn_end":
                u = m.get("usage") or {}
                use = Usage(use.input_tokens + u.get("input", 0), use.output_tokens + u.get("output", 0), use.calls + 1)
        return AgentOutput(text, usage=use, stop_reason="runtime_error" if failed else "done", session_id=sid)

    async def run(self, task: AgentInput) -> AgentOutput:
        return await asyncio.to_thread(self.turns, task)


targets = [
    EvalTarget(Harness.PI, "openai/fake-model", label="litellm/pi"),
    FleetPi("fleet/pi", model="fake/model"),
]


def echoes(*tokens: str):
    return PredicateCheck(lambda r: all(t in r.text for t in tokens))


tasks = [
    EvalTask("echo", "Reply with TOKAPPLE", check=echoes("TOKAPPLE")),
    EvalTask("two-turns", "Remember TOKALPHA\n---\nNow TOKBRAVO", check=echoes("TOKALPHA", "TOKBRAVO")),
    EvalTask("fails-on-purpose", "Reply with TOKFIG", check=echoes("TOKKIWI")),
]

run_options = {"max_turns": 2, "timeout": 120}

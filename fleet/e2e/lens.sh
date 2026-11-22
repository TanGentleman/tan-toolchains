#!/usr/bin/env bash
# Keyless Lens CLI run: Pi through LiteLLM beside Pi through a real fleetd,
# both against the fake OpenRouter. Needs pi and lens on PATH (see
# e2e/lens/README.md). Checks that real passes pass, the planted failure
# fails its check, and no attempt errors.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v lens >/dev/null || { echo "lens not on PATH; see e2e/lens/README.md"; exit 1; }
command -v pi >/dev/null || { echo "pi not on PATH"; exit 1; }
tmp=$(mktemp -d)
pids=()
cleanup() { kill ${pids[@]+"${pids[@]}"} 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
go build -o "$tmp/fleetd" ./cmd/fleetd
go build -o "$tmp/fakeor" ./cmd/fakeor

KEY=sk-or-v1-fake OR=127.0.0.1:17488 F=127.0.0.1:17433
"$tmp/fakeor" -listen $OR -trap 127.0.0.1:17489 -key $KEY >"$tmp/fakeor.log" 2>&1 &
pids+=($!)
OPENROUTER_API_KEY=$KEY FLEET_OPENROUTER_BASE=http://$OR/api \
  "$tmp/fleetd" -name lens -url http://$F -data "$tmp/node" -listen $F -owner tan 2>"$tmp/fleetd.log" &
pids+=($!)
for _ in $(seq 50); do curl -fs -H 'Tailscale-User-Login: tan' http://$F/v1/node >/dev/null && break; sleep 0.1; done

cp e2e/lens/evals.py "$tmp/"
(cd "$tmp" && FLEET_URL=http://$F OPENAI_API_BASE=http://$OR/v1 OPENAI_API_KEY=$KEY \
  lens run --config evals.py --trials "${TRIALS:-2}" </dev/null) || true # exits 1 on the planted failure

python3 - "$tmp"/.lens/runs/*/attempts.jsonl <<'PY' || { cat "$tmp/fleetd.log"; exit 1; }
import collections, json, sys
want = {"echo": "pass", "two-turns": "pass", "fails-on-purpose": "fail"}
seen = collections.Counter()
bad = []
for line in open(sys.argv[1]):
    a = json.loads(line)
    seen[a["target"]["label"]] += 1
    got = a["outcome"]["status"]
    if got != want[a["task_id"]] or a["check_error"] or a["stop_reason"] != "done":
        bad.append((a["target"]["label"], a["task_id"], got, a["check_error"], a["stop_reason"], a["output"][:200]))
if bad or set(seen) != {"litellm/pi", "fleet/pi"}:
    sys.exit(f"lens: unexpected results {bad} targets={dict(seen)}")
print(f"lens: ok {dict(seen)}")
PY

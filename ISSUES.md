# Issues

Known problems, newest first. GitHub issues are off for this repo, so they
live here. `pi-container/UPGRADES.md` still holds planned work; delete an
entry here when it is fixed.

## Gemini 4 Neon fails with 402: Pi asks for ~943k output tokens

Seen with Pi 1.7.0 through `pi-proxy`, OpenRouter model
`google/gemini-4-neon`. Other models work.

```
Error: 402: {"message":"This request requires more credits, or fewer max_tokens. You requested up to 942365 tokens, but can only afford 260444.
```

Pi's built-in catalog lists this model with `maxTokens: 943718`, and Pi sends
about that as `max_tokens`. OpenRouter refuses any request whose maximum output
at $15/M tokens costs more than the balance. Pi has no global output cap; its
per-model fix is a `modelOverrides` entry in `<agent-dir>/models.json`:

```json
{"providers":{"openrouter":{"modelOverrides":{"google/gemini-4-neon":{"maxTokens":65536}}}}}
```

Not fixed. Options:

- `run.sh` seeds `$PI_CONFIG_DIR/models.json` and mounts it read-only like
  `settings.json`. Pi-native, also applies under `--allow-egress`, one model
  per entry.
- `proxy.py` clamps `max_tokens` in OpenRouter request bodies to a
  `PI_MAX_TOKENS`. Covers every model, but not `--allow-egress`, and the proxy
  starts rewriting bodies.

## CI: fleet `TestRealPi` and `TestRealPiWrongKey` fail

Red on `container-bootstrap-7` and `-8` since the config.json/egress-profile
commits (2026-11-26); unrelated to the Pi version. `startProxy` in
`fleet/agent/realpi_test.go` predates two `proxy.py` changes:

1. It sets no `PI_PROXY_EGRESS`, so `proxy.py` exits at startup
   (`PI_PROXY_EGRESS must name the egress profile, not ''`). Adding
   `PI_PROXY_EGRESS=standard` and `PI_PROXY_MODEL_RULE=any` gets it running.
2. The test routes model calls to a local `fakeor` server through
   `PI_PROXY_MODEL_HOST` and expects that server to receive the real key.
   `proxy.py` now sends a model_url server `sk-or-v1-placeholder` and the real
   key only to openrouter.ai, so the fake upstream answers 401.

With both changed locally (fake server keyed on the placeholder),
`TestRealPi` passes on Pi 1.7.0. `TestRealPiWrongKey` then has nothing to test
on this route; it needs a real-openrouter-style upstream (TLS to a fake
`openrouter.ai`) or a rewrite around the placeholder rule.

```sh
cd fleet && go test -race -count=1 -run TestRealPi ./agent   # needs pi on PATH
```

## The recorded image fixture still names Pi 1.6.0

`pi-container/test/fixtures/container/image/inspect.json` was recorded from a
1.6.0 image. Fixtures are recorder-owned; after building a 1.7.0 image, run
`pi-container/test/record-fixtures.sh` on the Mac and review `git diff`.

## `PI_TELEMETRY=0` is a no-op on Pi 1.7.0

Pi 1.7.0 removed install telemetry and `PI_TELEMETRY`. `run.sh` and
`fleet/agent/realpi_test.go` still set it (and `enableInstallTelemetry`),
which only matters for an image built with an older `--build-arg PI_VERSION`.
Drop them when older pins no longer need support.

## CI warning: `mlugg/setup-zig` targets Node 20

GitHub runs it on Node 24 and annotates every run with a deprecation warning.
Move the pin when a release targets Node 24.

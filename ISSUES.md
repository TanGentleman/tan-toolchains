# Issues

Known problems, newest first. GitHub issues are off for this repo, so they
live here. `pi-container/UPGRADES.md` still holds planned work; delete an
entry here when it is fixed.

## Kranti agent runs get the GitHub token

Kranti's studio runs `run.sh --scratch` on the `standard` egress profile, so
`pi-proxy` tunnels GitHub and Pi gets `GITHUB_TOKEN`. Kranti agents only need
the Convex site (`PI_EXTRA_TUNNEL`) and the model route; prod runs should not
carry the token. For now the token in use has non-destructive access to one
private repo.

Not fixed. Options:

- A profile at `$PI_CONFIG_DIR/egress/NAME.json` with
  `{"v":1,"tunnel":[],"model_url":"any","github_token":false}`, and
  `KRANTI_PIC_ARGS=--egress NAME` in Kranti's `.env.local`.
- A `run.sh` option that drops the GitHub tunnel and token for one run, which
  Kranti passes.

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

## The recorded image fixture still names Pi 1.6.0

`pi-container/test/fixtures/container/image/inspect.json` was recorded from a
1.6.0 image. Fixtures are recorder-owned; after building a 1.7.0 image, run
`pi-container/test/record-fixtures.sh` on the Mac and review `git diff`.

## CI warning: `mlugg/setup-zig` targets Node 20

GitHub runs it on Node 24 and annotates every run with a deprecation warning.
v2.2.1 is the latest release and its main branch still targets Node 20; move
the pin when a release targets Node 24.

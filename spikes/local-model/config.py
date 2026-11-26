#!/usr/bin/env python3
"""Model configs for the local model server. Stdlib only.

models/<name>.json, "v": 1, every key required but "exclude" and "server_args":
  {"v": 1, "backend": "mlx-lm", "parser": "inkling" | "none",
   "weights": {"repo": "ORG/NAME", "revision": "<40-hex commit>", "exclude": ["GLOB", ...]},
   "server_args": ["--flag", "value", ...]}
server_args go to the backend unchanged, after the flags it owns (model, host,
port). LOCAL_MODEL=<name> picks the model; without it, models/ must hold
exactly one.

  config.py show       the selected model as one JSON object
  config.py exec PORT  replace this process with the backend on 127.0.0.1:PORT

Paths come from $LOCAL_MODEL_HOME (set by lib.sh)."""
import json
import os
import re
import sys

V = 1
NAME = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
REPO = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
REVISION = re.compile(r"^[0-9a-f]{40}$")
PARSERS = ("inkling", "none")


class ConfigError(ValueError):
    pass


class MlxLm:
    """mlx_lm.server from the uv env (pyproject.toml)."""
    platform = "Darwin/arm64"
    owned = ("--model", "--host", "--port")
    upstream_model = "default_model"  # mlx_lm.server's name for the --model it loaded
    env = {"HF_HUB_OFFLINE": "1"}

    @staticmethod
    def argv(venv, model_dir, port, server_args):
        return [os.path.join(venv, "bin", "mlx_lm.server"), "--model", model_dir,
                "--host", "127.0.0.1", "--port", str(port), *server_args]


# A new backend (llama.cpp, vLLM) is another class with the same attributes.
BACKENDS = {"mlx-lm": MlxLm}


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        raise ConfigError(f"{path}: {e}")
    except OSError as e:
        raise ConfigError(f"{path}: {e.strerror}")


def exact_keys(obj, required, optional, where):
    if not isinstance(obj, dict):
        raise ConfigError(f"{where}: not an object")
    extra, missing = set(obj) - required - optional, required - set(obj)
    if extra or missing:
        raise ConfigError(f"{where}: unknown keys {sorted(extra)}, missing {sorted(missing)}")


def load_model(path):
    m = read_json(path)
    exact_keys(m, {"v", "backend", "weights", "parser"}, {"server_args"}, path)
    if m["v"] != V:
        raise ConfigError(f"{path}: v must be {V}, got {m['v']!r}")
    if m["backend"] not in BACKENDS:
        raise ConfigError(f"{path}: backend must be one of {sorted(BACKENDS)}")
    if m["parser"] not in PARSERS:
        raise ConfigError(f"{path}: parser must be one of {list(PARSERS)}")
    w = m["weights"]
    exact_keys(w, {"repo", "revision"}, {"exclude"}, f"{path}: weights")
    if not isinstance(w["repo"], str) or not REPO.match(w["repo"]):
        raise ConfigError(f"{path}: weights.repo must be ORG/NAME")
    if not isinstance(w["revision"], str) or not REVISION.match(w["revision"]):
        raise ConfigError(f"{path}: weights.revision must be a 40-hex commit")
    w.setdefault("exclude", [])
    args = m.setdefault("server_args", [])
    for key, val in (("weights.exclude", w["exclude"]), ("server_args", args)):
        if not isinstance(val, list) or not all(isinstance(x, str) and x for x in val):
            raise ConfigError(f"{path}: {key} must be a list of non-empty strings")
    owned = BACKENDS[m["backend"]].owned
    for a in args:
        if a.split("=", 1)[0] in owned:
            raise ConfigError(f"{path}: server_args must not set {a.split('=', 1)[0]}; the CLI sets {', '.join(owned)}")
    return m


def selected(models_dir, name):
    """Name of the model to serve: name (LOCAL_MODEL), else the only one."""
    if name:
        if not NAME.match(name):
            raise ConfigError(f"LOCAL_MODEL must match {NAME.pattern}")
        if not os.path.isfile(os.path.join(models_dir, name + ".json")):
            raise ConfigError(f"LOCAL_MODEL: no model {name!r} in {models_dir}")
        return name
    names = sorted(f[:-5] for f in os.listdir(models_dir) if f.endswith(".json"))
    if len(names) != 1:
        raise ConfigError(f"{len(names)} models in {models_dir}; pick one with LOCAL_MODEL=<name>")
    return names[0]


def info(here, home, user_home, name=""):
    models = os.path.join(here, "models")
    legacy = os.path.join(user_home, ".config", "local-model", "config.json")
    if os.path.lexists(legacy):
        raise ConfigError(f"{legacy} is no longer read; set LOCAL_MODEL=<name> instead, then delete the file")
    name = selected(models, name)
    m = load_model(os.path.join(models, name + ".json"))
    b = BACKENDS[m["backend"]]
    d = os.path.join(home, "models", name)
    try:
        with open(os.path.join(d, ".complete")) as f:
            installed = f.read().strip() == m["weights"]["revision"]
    except OSError:
        installed = False
    return {"name": name, "backend": m["backend"], "parser": m["parser"], "weights": m["weights"],
            "server_args": m["server_args"], "dir": d, "installed": installed,
            "platform": b.platform, "upstream_model": b.upstream_model}


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    home = os.environ.get("LOCAL_MODEL_HOME")
    usage = "usage: config.py show | config.py exec PORT"
    if not home or len(sys.argv) < 2:
        sys.exit(usage)
    try:
        i = info(here, home, os.environ["HOME"], os.environ.get("LOCAL_MODEL", ""))
    except ConfigError as e:
        sys.exit(f"model: {e}")
    if sys.argv[1:] == ["show"]:
        print(json.dumps(i))
    elif len(sys.argv) == 3 and sys.argv[1] == "exec" and sys.argv[2].isdigit():
        if not i["installed"]:
            sys.exit(f"model: weights for {i['name']} missing; run: model install")
        b = BACKENDS[i["backend"]]
        argv = b.argv(os.path.join(home, "venv"), i["dir"], int(sys.argv[2]), i["server_args"])
        os.execve(argv[0], argv, {**os.environ, **b.env})
    else:
        sys.exit(usage)


if __name__ == "__main__":
    main()

# The three settings that decide what a run is: the image pack, the egress
# profile, and where model calls go. Each comes from a flag, then an env var
# (PI_IMAGE, PI_EGRESS, PI_MODEL_URL), then the default. Sourced, never
# executed; needs jq and lib/validate.sh. Secrets stay in the env file.

pi_config_default_image=full
pi_config_default_egress=standard
pi_config_default_model_url=openrouter

# $PI_CONFIG_DIR/config.json set these until env vars replaced it. A file left
# behind is refused, not ignored: ignoring an offline one would widen egress.
# Prints the env assignments that replace it ("" when it holds none).
pi_config_legacy() { # file
  jq -r 'if type == "object" then [to_entries[] | select(.key == "image" or .key == "egress" or .key == "model_url")
      | "PI_\(.key | ascii_upcase)=\(.value | tostring | @sh)"] | join(" ") else "" end' "$1" 2>/dev/null || true
}

# The effective value and where it came from. Prints "VALUE SOURCE".
pi_config_pick() { # flag-value, env-value, default
  if [ -n "${1:-}" ]; then printf '%s flag\n' "$1"
  elif [ -n "${2:-}" ]; then printf '%s env\n' "$2"
  else printf '%s default\n' "$3"
  fi
}

# Refuse an egress/model_url pair that cannot work. A profile whose model_url
# rule is "private" (offline) sends model calls only to an http model_url on
# gateway or a private IPv4 address. Prints the reason and returns 1.
pi_config_combo_check() { # egress name, its model_url rule, model_url
  local hostport
  [ "$2" = private ] || return 0
  if [ "$3" = openrouter ]; then
    printf 'egress %s needs model_url http://HOST:PORT (a local model server); openrouter is refused %s\n' "$1" "$1"
    return 1
  fi
  hostport=$(pi_model_url_split "$3") || { printf 'bad model_url "%s"\n' "$3"; return 1; }
  case ${hostport% *} in
    gateway) return 0 ;;
  esac
  pi_offline_upstream_valid "${hostport% *}" && return 0
  printf 'egress %s needs model_url on gateway or a private IPv4 address (10/8, 172.16/12, 192.168/16, 169.254/16), not %s\n' "$1" "${hostport% *}"
  return 1
}

# run.sh config --json.
pi_config_json() { # image, image-source, egress, egress-source, model_url, model_url-source, tag, profile file, tunnel csv, model_url rule, github_token
  jq -cn --arg image "$1" --arg is "$2" --arg egress "$3" --arg es "$4" \
    --arg url "$5" --arg us "$6" --arg tag "$7" --arg pf "$8" --arg tunnel "$9" --arg rule "${10}" --arg token "${11}" \
    '{v: 1, image: $image, tag: $tag, egress: $egress, model_url: $url,
      source: {image: $is, egress: $es, model_url: $us},
      egress_profile: {file: $pf, tunnel: ($tunnel | split(",") | map(select(. != ""))), model_url: $rule, github_token: ($token == "true")}}'
}

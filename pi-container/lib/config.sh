# The profile's config file, $PI_CONFIG_DIR/config.json:
#   {"v": 1, "image": "min|full|zig", "egress": "standard|offline|NAME",
#    "model_url": "openrouter" | "http://HOST:PORT"}
# Every key is optional. Sourced, never executed; needs jq and lib/validate.sh.
# Secrets never go here; they stay in the env file.

pi_config_default_image=full
pi_config_default_egress=standard
pi_config_default_model_url=openrouter

# Prints "IMAGE<US>EGRESS<US>MODEL_URL" (US is \x1f), a field empty when its
# key is absent; an absent file has every field empty. On a bad file prints
# the reason and returns 1.
pi_config_read() { # file
  local file=$1 out image egress url
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '\037\037\n'
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'is not a readable file\n'
    return 1
  fi
  if ! out=$(jq -rs '
      def bad($m): "error:" + $m;
      def known: ["v", "image", "egress", "model_url"];
      def text: type == "string" and (explode | all(. >= 32));
      if length != 1 or (.[0] | type) != "object" then bad("must hold one JSON object")
      else .[0]
        | if .v != 1 then bad("needs \"v\": 1, not \(.v | tojson)")
          elif (keys - known) != [] then bad("has unknown key \((keys - known)[0] | tojson)")
          elif [to_entries[] | select(.key != "v") | .value] | any(text | not) then
            bad("image, egress and model_url must be one-line strings")
          else [.image // "", .egress // "", .model_url // ""] | join("\u001f")
          end
      end' "$file" 2>/dev/null); then
    printf 'is not valid JSON\n'
    return 1
  fi
  case $out in
    error:*) printf '%s\n' "${out#error:}"; return 1 ;;
  esac
  IFS=$'\037' read -r image egress url <<<"$out"
  if [ -n "$image" ] && ! pi_pi_pack_valid "$image"; then
    printf 'image must be min, full or zig, not "%s"\n' "$image"
    return 1
  fi
  if [ -n "$egress" ] && ! pi_egress_valid "$egress"; then
    printf 'egress must be a profile name (standard, offline, or NAME for egress/NAME.json), not "%s"\n' "$egress"
    return 1
  fi
  if [ -n "$url" ] && ! pi_model_url_split "$url" >/dev/null; then
    printf 'model_url must be "openrouter" or http://HOST:PORT, not "%s"\n' "$url"
    return 1
  fi
  printf '%s\037%s\037%s\n' "$image" "$egress" "$url"
}

# The effective value and where it came from: flag, then file, then default.
# Prints "VALUE SOURCE".
pi_config_pick() { # flag-value, file-value, default
  if [ -n "${1:-}" ]; then printf '%s flag\n' "$1"
  elif [ -n "${2:-}" ]; then printf '%s file\n' "$2"
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
pi_config_json() { # path, image, image-source, egress, egress-source, model_url, model_url-source, tag, profile file, tunnel csv, model_url rule, github_token
  jq -cn --arg path "$1" --arg image "$2" --arg is "$3" --arg egress "$4" --arg es "$5" \
    --arg url "$6" --arg us "$7" --arg tag "$8" --arg pf "$9" --arg tunnel "${10}" --arg rule "${11}" --arg token "${12}" \
    '{v: 1, config: $path, image: $image, tag: $tag, egress: $egress, model_url: $url,
      source: {image: $is, egress: $es, model_url: $us},
      egress_profile: {file: $pf, tunnel: ($tunnel | split(",") | map(select(. != ""))), model_url: $rule, github_token: ($token == "true")}}'
}

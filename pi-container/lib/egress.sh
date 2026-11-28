# Egress profiles: what pi-proxy lets Pi reach. The built-ins are
# pi-container/egress/standard.json and offline.json; a profile of your own
# is $PI_CONFIG_DIR/egress/NAME.json and cannot reuse a built-in name.
#   {"v": 1, "about": "one line", "tunnel": ["github.com", ...],
#    "model_url": "any" | "private", "github_token": true | false}
# tunnel: exact host names pi-proxy passes through (CONNECT to port 443),
#   never openrouter.ai or its subdomains, which pi-proxy intercepts to add
#   the key. Every other host is refused.
# model_url: "private" requires model_url http://HOST:PORT on gateway or a
#   private IPv4 address, so model calls never leave the Mac's networks.
# github_token: whether Pi gets GITHUB_TOKEN from the env file.
# Sourced, never executed; needs jq.

pi_egress_builtin_names="standard offline"

pi_egress_jq_defs='
  def bad($m): "error:" + $m;
  def host: type == "string" and test("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$");
  def openrouter: . == "openrouter.ai" or endswith(".openrouter.ai");'

# Prints the profile's file. Returns 1 when NAME is neither built in nor in
# the user directory.
pi_egress_file() { # name, builtin-dir, user-dir
  case " $pi_egress_builtin_names " in
    *" $1 "*) printf '%s/%s.json\n' "$2" "$1"; return 0 ;;
  esac
  [ -f "$3/$1.json" ] || return 1
  printf '%s/%s.json\n' "$3" "$1"
}

# Prints "TUNNEL<US>MODEL_URL_RULE<US>GITHUB_TOKEN" (US is \x1f, TUNNEL is
# comma-separated, possibly empty). On a bad file prints the reason and
# returns 1.
pi_egress_read() { # file
  local out
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    printf 'is not a readable file\n'
    return 1
  fi
  if ! out=$(jq -rs '
      '"$pi_egress_jq_defs"'
      def known: ["v", "about", "tunnel", "model_url", "github_token"];
      if length != 1 or (.[0] | type) != "object" then bad("must hold one JSON object")
      else .[0]
        | if .v != 1 then bad("needs \"v\": 1, not \(.v | tojson)")
          elif (keys - known) != [] then bad("has unknown key \((keys - known)[0] | tojson)")
          elif has("about") and ((.about | type) != "string" or (.about | length) > 200 or (.about | explode | any(. < 32))) then
            bad("about must be one line of at most 200 characters")
          elif (.tunnel | type) != "array" or (.tunnel | length) > 64 or (.tunnel | any(host | not)) then
            bad("tunnel must be a list of at most 64 lowercase host names")
          elif .tunnel | any(openrouter) then bad("tunnel cannot list openrouter.ai; pi-proxy intercepts it to add the key")
          elif (.tunnel | unique | length) != (.tunnel | length) then bad("tunnel lists a host twice")
          elif .model_url != "any" and .model_url != "private" then bad("model_url must be \"any\" or \"private\"")
          elif (.github_token | type) != "boolean" then bad("github_token must be true or false")
          else [(.tunnel | join(",")), .model_url, (.github_token | tostring)] | join("\u001f")
          end
      end' "$1" 2>/dev/null); then
    printf 'is not valid JSON\n'
    return 1
  fi
  case $out in
    error:*) printf '%s\n' "${out#error:}"; return 1 ;;
  esac
  printf '%s\n' "$out"
}

# Whether a comma-separated tunnel list has HOST.
pi_egress_tunnels() { # tunnel-csv, host
  case ",$1," in
    *",$2,"*) return 0 ;;
  esac
  return 1
}

# PI_EXTRA_TUNNEL: comma-separated hosts, or https://HOST URLs, added to the
# profile's tunnel for this run (so PI_EXTRA_TUNNEL=$CONVEX_SITE_URL works).
# Prints the merged tunnel csv; a host already listed is kept once. On a bad
# entry prints the reason and returns 1.
pi_egress_extra() { # tunnel-csv, extra
  local out
  out=$(jq -rn --arg base "$1" --arg extra "$2" "$pi_egress_jq_defs"'
      def csv: split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""));
      ($extra | csv) as $raw
      | ($raw | map(if startswith("https://") then .[8:] | sub("/$"; "") else . end)) as $hosts
      | ([range(0; $raw | length) | select($hosts[.] | host | not)] | first) as $i
      | if $i != null then bad("entry \($raw[$i] | tojson) is not a lowercase host name or https://HOST")
        elif $hosts | any(openrouter) then bad("cannot list openrouter.ai; pi-proxy intercepts it to add the key")
        else (reduce (($base | csv) + $hosts)[] as $h ([]; if index([$h]) then . else . + [$h] end)) as $all
          | if ($all | length) > 64 then bad("makes the tunnel longer than 64 hosts")
            else $all | join(",") end
        end') || { printf 'is not a list of host names\n'; return 1; }
  case $out in
    error:*) printf '%s\n' "${out#error:}"; return 1 ;;
  esac
  printf '%s\n' "$out"
}

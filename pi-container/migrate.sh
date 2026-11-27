#!/usr/bin/env bash
# pic migrate: move pi-container's v7 files into ~/.pic (or $PIC_HOME), once.
#
#   run.sh migrate
#
# Asks for each path, defaulting to where v7 kept it. Answer with another path,
# or - to skip it.
#
#   default profile  ~/.config/pi-container       -> $PIC_HOME/config
#   backups          ~/pi-backups                 -> $PIC_HOME/backups, or kept
#   fleet data       ~/.fleet                     -> $PIC_HOME/fleet
#   other profiles   ~/.config/pi-container-NAME  -> $PIC_HOME/profiles/NAME
#
# Another profile's proxy, network and volume names hash its path, so before
# moving one this runs `clear.sh nuke profile` on it: sessions are saved to
# the backups, then its volumes, proxy and network are deleted. Unpushed work
# in its clone volumes is lost. The default profile keeps its names.
#
# Then it writes $PIC_HOME/overrides.env (mode 600): a v1 header with the time
# and commit, the moves as comments, and PI_BACKUP_DIR if the backups stayed.
# It exits early if $PIC_HOME exists, refuses while fleetd or the default
# proxy runs, and moves with mv only on the same filesystem.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/names.sh"
. "$here/lib/paths.sh"
. "$here/lib/inspect.sh"
cli="${CONTAINER_CLI:-container}"
pic=$(pi_pic_home)
h=${HOME%/}

die() { printf 'pic migrate: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

case ${1:-} in
  '') ;;
  -h|--help|help) sed -n '2,22s/^# \{0,1\}//p' "$0"; exit 0 ;;
  *) echo "pic migrate: takes no arguments (try --help)" >&2; exit 2 ;;
esac

[ ! -e "$pic" ] && [ ! -L "$pic" ] || die "$pic already exists, so there is nothing to migrate into. To use another root: PIC_HOME=/path pic migrate, then keep PIC_HOME set"
parent=$(dirname "$pic")
[ -d "$parent" ] || die "$parent does not exist"
if command -v pgrep >/dev/null 2>&1 && pgrep -x fleetd >/dev/null 2>&1; then
  die "fleetd is running; stop pic serve first"
fi
if json=$("$cli" inspect pi-proxy 2>/dev/null); then
  case $(printf '%s\n' "$json" | pi_proxy_state_from_json) in
    stopped) ;;
    *) die "pi-proxy is running (or its state is unknown); quit Pi, then: ${cli##*/} stop pi-proxy" ;;
  esac
fi

# Read a path. Prints "" for "-"; expands a leading ~.
ask_path() { # what, default
  local a
  printf '%s [%s]: ' "$1" "${2:--}" >&2
  IFS= read -r a || a=""
  a=${a:-${2:--}}
  case $a in
    -) a="" ;;
    "~") a=$h ;;
    "~/"*) a=$h/${a#\~/} ;;
  esac
  printf '%s\n' "${a%/}"
}

ask_yes() { # question
  local a
  printf '%s [y/N]: ' "$1" >&2
  IFS= read -r a || a=""
  case $a in y|Y|yes) return 0 ;; esac
  return 1
}

existing() { [ -d "$1" ] && printf '%s\n' "$1" || printf -- '-\n'; }

dev=$(pi_path_dev "$parent")
srcs=() dsts=()
plan() { # src, dst
  [ -n "$1" ] || return 0
  case $1 in /*) ;; *) die "$1 is not an absolute path" ;; esac
  [ -d "$1" ] && [ ! -L "$1" ] || die "$1 is not a directory"
  if pi_path_within "$1" "$pic" || pi_path_within "$pic" "$1"; then die "$1 overlaps $pic"; fi
  [ "$(pi_path_dev "$1")" = "$dev" ] || die "$1 is on another filesystem than $pic; mv would copy it (and its keys). Move it by hand, or set PIC_HOME on that filesystem"
  srcs+=("$1") dsts+=("$2")
}

say "pic migrate: into $pic"
plan "$(ask_path "default profile" "$(existing "$h/.config/pi-container")")" "$pic/config"
backups=$(ask_path "session backups" "$(existing "$h/pi-backups")")
kept=""
if [ -n "$backups" ]; then
  if ask_yes "keep backups in $backups instead of moving them (overrides.env records it)?"; then
    case $backups in /*) ;; *) die "$backups is not an absolute path" ;; esac
    [ -d "$backups" ] || die "$backups is not a directory"
    kept=$backups
  else
    plan "$backups" "$pic/backups"
  fi
fi
plan "$(ask_path "fleet data" "$(existing "$h/.fleet")")" "$pic/fleet"

others=()
for d in "$h"/.config/pi-container-*; do
  [ -d "$d" ] && [ ! -L "$d" ] || continue
  others+=("$d")
done
while :; do
  extra=$(ask_path "another profile to move (- when done)" -)
  [ -n "$extra" ] || break
  others+=("$extra")
done
movers=() names=()
for d in ${others[@]+"${others[@]}"}; do
  name=${d##*/}
  name=${name#pi-container-}
  [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "cannot name a profile after $d; rename it to pi-container-NAME first"
  ask_yes "move profile $d to $pic/profiles/$name? Its volumes, proxy and network are deleted first (sessions saved; unpushed clone work lost)" || continue
  for n in ${names[@]+"${names[@]}"}; do [ "$n" != "$name" ] || die "two profiles are both named $name"; done
  [ -d "$d" ] && [ ! -L "$d" ] || die "$d is not a directory"
  [ "$(pi_path_dev "$d")" = "$dev" ] || die "$d is on another filesystem than $pic"
  movers+=("$d") names+=("$name")
done

[ ${#srcs[@]} -gt 0 ] || [ ${#movers[@]} -gt 0 ] || [ -n "$kept" ] || die "nothing to migrate"
say ""
say "plan:"
for i in ${srcs[@]+"${!srcs[@]}"}; do say "  mv ${srcs[$i]} ${dsts[$i]}"; done
[ -z "$kept" ] || say "  keep $kept (PI_BACKUP_DIR in overrides.env)"
for i in ${movers[@]+"${!movers[@]}"}; do say "  clear.sh nuke profile, then mv ${movers[$i]} $pic/profiles/${names[$i]}"; done
ask_yes "quit every Pi and --manual session first. Go ahead?" || die "aborted; nothing changed"

(umask 077 && mkdir "$pic")
chmod 700 "$pic"
for i in ${srcs[@]+"${!srcs[@]}"}; do
  mv "${srcs[$i]}" "${dsts[$i]}"
  say "moved ${srcs[$i]} -> ${dsts[$i]}"
done
commit=$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)
(
  umask 077
  {
    printf '# pic overrides v1, written %s by pic migrate at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$commit"
    for i in ${srcs[@]+"${!srcs[@]}"}; do printf '# moved %s -> %s\n' "${srcs[$i]}" "${dsts[$i]}"; done
    for i in ${movers[@]+"${!movers[@]}"}; do printf '# moved %s -> %s/profiles/%s\n' "${movers[$i]}" "$pic" "${names[$i]}"; done
    [ -z "$kept" ] || printf 'PI_BACKUP_DIR=%s\n' "$kept"
  } > "$pic/overrides.env"
)
chmod 600 "$pic/overrides.env"
say "wrote $pic/overrides.env"

[ ${#movers[@]} -eq 0 ] || mkdir -m 700 "$pic/profiles"
for i in ${movers[@]+"${!movers[@]}"}; do
  d=${movers[$i]} to="$pic/profiles/${names[$i]}"
  PIC_HOME=$pic PI_CONFIG_DIR=$d "$here/clear.sh" nuke profile --yes ||
    die "nuke profile failed for $d; nothing else moved. Finish by hand: PI_CONFIG_DIR=$d $here/clear.sh nuke profile && mv $d $to"
  mv "$d" "$to"
  say "moved $d -> $to"
done
say "done. Check: $here/clear.sh list"

# Image pack catalog. Sourced by build.sh, run.sh and clear.sh, and
# documented in docs/configuration.md. min, full and zig run Pi; tools and
# editor do not. The config file picks one of the Pi packs (default full).

pi_pack_names="min full zig tools editor"
pi_pi_pack_names="min full zig"

pi_pack_target() { # pack
  case ${1:-} in
    min) printf 'min\n' ;;
    full) printf 'full\n' ;;
    zig) printf 'full-zig\n' ;;
    tools) printf 'tools\n' ;;
    editor) printf 'editor\n' ;;
    *) return 1 ;;
  esac
}

pi_pack_tag() { # pack
  case ${1:-} in
    min|full|zig|tools|editor) printf 'pi-%s:local\n' "$1" ;;
    *) return 1 ;;
  esac
}

# What the pack's Dockerfile stage records in PI_CONTAINER_CAPABILITIES.
pi_pack_caps() { # pack
  case ${1:-} in
    min) printf 'netlock,pi\n' ;;
    full) printf 'enforcer,netlock,pi,gh\n' ;;
    zig) printf 'zig,zigpeek,enforcer,netlock,pi,gh,nvim,zls\n' ;;
    tools) printf 'zig,zigpeek,enforcer,netlock\n' ;;
    editor) printf 'zig,zigpeek,enforcer,netlock,nvim,zls\n' ;;
    *) return 1 ;;
  esac
}

pi_pack_build_hint() { # pack, here
  printf '%s/build.sh %s' "$2" "$1"
}

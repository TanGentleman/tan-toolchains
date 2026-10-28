# Image pack catalog. Sourced by build.sh and documented in
# docs/configuration.md. The default tag is the full image so existing commands
# keep working; other packs are opt-in through PI_IMAGE.

pi_pack_names="tools editor agent agent-gh full"

pi_pack_target() { # pack
  case ${1:-} in
    tools) printf 'tools\n' ;;
    editor) printf 'editor\n' ;;
    agent) printf 'agent\n' ;;
    agent-gh) printf 'agent-gh\n' ;;
    full) printf 'full\n' ;;
    *) return 1 ;;
  esac
}

pi_pack_tag() { # pack
  case ${1:-} in
    tools) printf 'pi-tools:local\n' ;;
    editor) printf 'pi-editor:local\n' ;;
    agent) printf 'pi-agent-lite:local\n' ;;
    agent-gh) printf 'pi-agent-gh:local\n' ;;
    full) printf 'pi-agent:local\n' ;;
    *) return 1 ;;
  esac
}

pi_pack_for_tag() { # tag
  case ${1:-} in
    pi-tools:local) printf 'tools\n' ;;
    pi-editor:local) printf 'editor\n' ;;
    pi-agent-lite:local) printf 'agent\n' ;;
    pi-agent-gh:local) printf 'agent-gh\n' ;;
    pi-agent:local) printf 'full\n' ;;
    *) return 1 ;;
  esac
}

# Rebuild hint for a tag, preserving its pack target when it is in the catalog.
pi_build_hint() { # cli, image, here
  local cli=$1 image=$2 here=$3 pack target
  if pack=$(pi_pack_for_tag "$image"); then
    target=$(pi_pack_target "$pack")
    printf '%s build -t %s --target %s -f %s/Dockerfile %s/..' \
      "$cli" "$image" "$target" "$here" "$here"
  else
    printf '%s build -t %s -f %s/Dockerfile %s/..' "$cli" "$image" "$here" "$here"
  fi
}

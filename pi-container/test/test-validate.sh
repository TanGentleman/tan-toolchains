#!/usr/bin/env bash
# Unit tests for lib/validate.sh. No container runtime required.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
. "$here/../lib/validate.sh"

# Ports: decimal, in range. bash `[ ]` treats leading zeros as decimal.
for p in 1 80 080 8888 65535; do
  rc 0 "port $p should be valid" pi_port_valid "$p"
done
for p in '' 0 65536 -1 abc 80x ' 80' 1.5; do
  rc 1 "port [$p] should be invalid" pi_port_valid "$p"
done

# Repo normalisation strips exactly one .git suffix.
eq "owner/repo" "$(pi_repo_normalize owner/repo.git)" "normalise .git"
eq "owner/repo" "$(pi_repo_normalize owner/repo)" "normalise plain"
eq "owner/repo.git" "$(pi_repo_normalize owner/repo.git.git)" "normalise one suffix"
eq "" "$(pi_repo_normalize '')" "normalise empty"

# Repo validation: one slash, safe owner and repo.
for r in owner/repo Owner-1/repo.name_1-2 a/b.c_d-e; do
  rc 0 "repo [$r] should be valid" pi_repo_valid "$r"
done
for r in '' owner owner/ /repo 'owner//repo' owner/repo/extra owner/. owner/.. owner/-repo 'owner/re po' 'own_er/repo' 'owner/re+po'; do
  rc 1 "repo [$r] should be invalid" pi_repo_valid "$r"
done

# Egress profiles.
for m in standard offline; do
  rc 0 "egress [$m] should be valid" pi_egress_valid "$m"
done
for m in '' normal Offline online 'offline ' none; do
  rc 1 "egress [$m] should be invalid" pi_egress_valid "$m"
done

# Pi packs: the config file and run.sh --image.
for p in min full zig; do
  rc 0 "pack [$p] should be valid" pi_pi_pack_valid "$p"
done
for p in '' agent agent-min tools editor Full; do
  rc 1 "pack [$p] should be invalid" pi_pi_pack_valid "$p"
done

# model_url: openrouter or http://HOST:PORT.
eq "" "$(pi_model_url_split openrouter)" "openrouter has no host"
rc 0 "openrouter is a model_url" pi_model_url_split openrouter
eq "gateway 8090" "$(pi_model_url_split http://gateway:8090)" "gateway split"
eq "192.168.64.1 1" "$(pi_model_url_split http://192.168.64.1:1)" "IPv4 split"
eq "models.lan 65535" "$(pi_model_url_split http://models.lan:65535)" "name split"
for u in '' OpenRouter https://gateway:8090 http://gateway http://gateway: http://:8090 http://gateway:8090/          http://gateway:8090/v1 http://gateway:0 http://gateway:65536 http://gateway:080 'http://gate way:1'          http://-x:1 http://x-:1 'http://user@x:1' 'http://[::1]:8090' gateway:8090; do
  rc 1 "model_url [$u] should be invalid" pi_model_url_split "$u"
done

# Offline upstream: a private IPv4 literal only, never a name.
for h in 192.168.64.1 10.0.0.1 172.16.0.1 172.31.255.254 169.254.1.1; do
  rc 0 "offline upstream [$h] should be valid" pi_offline_upstream_valid "$h"
done
for h in '' openrouter.ai github.com localhost 127.0.0.1 1.1.1.1 100.100.100.100 172.15.0.1 \
         172.32.0.1 192.169.0.1 192.168.64.256 192.168.64 192.168.64.1.5 ' 192.168.64.1' '::1' fd00::1; do
  rc 1 "offline upstream [$h] should be invalid" pi_offline_upstream_valid "$h"
done

finish

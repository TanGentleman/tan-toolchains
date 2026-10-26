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

finish

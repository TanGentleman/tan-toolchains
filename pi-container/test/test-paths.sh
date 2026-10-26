#!/usr/bin/env bash
# Unit tests for lib/paths.sh: the mount guard's path algebra.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$here/lib.sh"
. "$here/../lib/paths.sh"

# pi_path_within: parent or below, case-folded.
rc 0 "same path is within" pi_path_within /a /a
rc 0 "child is within" pi_path_within /a /a/b
rc 0 "root contains everything" pi_path_within / /tmp/x
rc 0 "case-folded parent" pi_path_within /A /a/b
rc 0 "case-folded child" pi_path_within /a /A/B
rc 1 "sibling prefix is not within" pi_path_within /a /ab
rc 1 "parent is not within child" pi_path_within /a/b /a
rc 1 "unrelated path" pi_path_within /a /b

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/real/sub" "$tmp/other"
printf 'x\n' > "$tmp/real/file"
ln -s "$tmp/real" "$tmp/link-dir"
ln -s "$tmp/real/file" "$tmp/link-file"
ln -s "$tmp/missing" "$tmp/dangling"

# physical_dir resolves a symlinked directory to its target.
eq "$(cd "$tmp/real" && pwd -P)" "$(pi_physical_dir "$tmp/link-dir")" "physical_dir resolves symlink"
rc 1 "physical_dir fails on missing path" pi_physical_dir "$tmp/nope"

# physical_path resolves symlinks and leaves missing paths untouched.
eq "$(cd "$tmp/real" && pwd -P)" "$(pi_physical_path "$tmp/link-dir")" "physical_path resolves dir symlink"
eq "$(cd "$tmp/real" && pwd -P)/file" "$(pi_physical_path "$tmp/link-file")" "physical_path resolves file symlink"
# A dangling symlink resolves to its target path even when the target is
# missing; the guard still compares the result textually.
eq "$tmp/missing" "$(pi_physical_path "$tmp/dangling")" "physical_path resolves a dangling link"
eq "$tmp/not-there" "$(pi_physical_path "$tmp/not-there")" "physical_path leaves a missing path"

# file_mode follows symlinks and reports the target's mode.
chmod 600 "$tmp/real/file"
eq 600 "$(pi_file_mode "$tmp/real/file")" "file_mode reads 600"
eq 600 "$(pi_file_mode "$tmp/link-file")" "file_mode follows symlink"
chmod 644 "$tmp/real/file"
eq 644 "$(pi_file_mode "$tmp/real/file")" "file_mode reads 644"

finish

#!/bin/sh
# Used by app-restore-drill.sh: Git's own check of every repository in a restored Forgejo backup. The number found
# must be the number the backup recorded. AI-assisted (Claude Code).
# Usage: check-forgejo-repos.sh RESTORED_DIR
set -eu
root=$1
expected=$(tr -d ' \n' < "$root/manifest.json" | sed -n 's/.*"counts":{[^}]*"repositories":\([0-9][0-9]*\).*/\1/p')
[ -n "$expected" ] || { echo "repository check FAILED: no repository count in the manifest" >&2; exit 1; }
found=0
for repo in "$root"/git/repositories/*/*.git; do
  [ -d "$repo" ] || continue
  g() { git -c safe.directory="$repo" --git-dir "$repo" "$@"; }
  g fsck --full --strict --no-progress
  head=$(g rev-parse HEAD)
  commits=$(g rev-list --all --count)
  echo "repository $(basename "$repo"): git fsck ok, HEAD $head, $commits commits"
  found=$((found + 1))
done
if [ "$found" -ne "$expected" ]; then
  echo "repository check FAILED: the backup recorded $expected repositories, found $found" >&2
  exit 1
fi
echo "repository check ok: $found of $expected"

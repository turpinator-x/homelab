#!/usr/bin/env bash
# Claude Code PostToolUse hook: after Claude edits a YAML file in this repo,
# run scripts/validate.sh. On failure, exit 2 so the output goes back to Claude.
set -uo pipefail

file=$(jq -r '.tool_input.file_path // empty')
case "$file" in
  *.yaml | *.yml) ;;
  *) exit 0 ;;
esac

repo=$(cd "$(dirname "$0")/../.." && pwd)
[[ "$file" == "$repo"/* ]] || exit 0

cd "$repo"
if ! out=$(mise exec -- ./scripts/validate.sh 2>&1); then
  echo "scripts/validate.sh failed after editing $file:" >&2
  echo "$out" >&2
  exit 2
fi

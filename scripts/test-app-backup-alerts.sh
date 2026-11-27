#!/usr/bin/env bash
# Unit-tests the Linkding and Audiobookshelf backup alerts with promtool. Needs promtool and python3 with PyYAML.
set -euo pipefail
_here=${BASH_SOURCE[0]%/*}; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=lib/require-tools.sh
. "$_here/lib/require-tools.sh"
require_tools git mktemp rm cp mkdir promtool python3

cd "$(git rev-parse --show-toplevel)"
dir=apps/staging/app-backup-alerts
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 -c 'import sys, yaml; yaml.safe_dump(yaml.safe_load(open(sys.argv[1]))["spec"], sys.stdout)' \
  "$dir/rules.yaml" > "$tmp/rules.rules.yaml"
promtool check rules "$tmp/rules.rules.yaml"
mkdir "$tmp/tests"
cp "$dir/tests/rules.test.yaml" "$tmp/tests/"
promtool test rules "$tmp/tests/rules.test.yaml"

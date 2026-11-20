#!/usr/bin/env bash
# Usage: ./scripts/test-blockone-alerts.sh
# Unit-tests the BlockOne PrometheusRules with promtool: pulls spec.groups out of each PrometheusRule and runs
# apps/base/blockone-crypto-tax/tests/*.test.yaml against it. Needs promtool (mise.toml pins it) and python3 with PyYAML (the staging isolation check uses it too).
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
dir=apps/base/blockone-crypto-tax
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for cmd in promtool python3; do
  command -v "$cmd" > /dev/null || { echo "$cmd not found" >&2; exit 1; }
done

for rule in app-alerts backup-alerts storage-alerts storage-report-alerts; do
  python3 -c 'import sys, yaml; yaml.safe_dump(yaml.safe_load(open(sys.argv[1]))["spec"], sys.stdout)' \
    "$dir/$rule.yaml" > "$tmp/$rule.rules.yaml"
  promtool check rules "$tmp/$rule.rules.yaml"
done

# The tests name the extracted files as rule_files, relative to their own copy. Run from the repo root so mise's
# shim for promtool still finds mise.toml.
mkdir "$tmp/tests"
cp "$dir"/tests/*.test.yaml "$tmp/tests/"
promtool test rules "$tmp"/tests/*.test.yaml

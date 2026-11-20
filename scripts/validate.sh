#!/usr/bin/env bash
# Usage: ./scripts/validate.sh [--allow-prod-change]   (the flag: a production change beyond the app image is meant;
# CI passes it only for a PR labelled production-change)
# Builds every Flux path and validates the result against Kubernetes and CRD schemas.
set -euo pipefail

# Preflight, before anything else runs: normalise PATH once (a shell without /usr/bin, as a release runner or cron can
# have, used to fail deep inside a test with a confusing "required command 'awk' not found"), check every host tool the
# checks and tests below need, and fail here with one clear message if one is missing. The children inherit the PATH.
_here=${BASH_SOURCE[0]%/*}; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=lib/require-tools.sh
. "$_here/lib/require-tools.sh"
require_tools git kubectl kubeconform promtool python3 mktemp rm cat grep diff awk sed du df stat find sort cut tr wc \
  sha256sum date head tail sleep mv cp tee sh env seq touch dirname basename uniq nice timeout chmod mkdir ln
echo "== Tools (PATH normalised; shellcheck is for the pre-commit hook, not needed here)"
print_tools awk sed du find shellcheck promtool kubectl kubeconform python3
echo "  kustomize    $(command -v kubectl) kustomize (built in)"
# the preflight test runs this far and stops
[ -z "${VALIDATE_PREFLIGHT_ONLY:-}" ] || exit 0

current=start
trap 'echo "validate.sh stopped in section: $current" >&2' ERR
section() { current=$1; echo "== $1"; }

cd "$(git rev-parse --show-toplevel)"

section "Tool preflight (PATH normalising, one clear message for a missing tool)"
./scripts/test-require-tools.sh

schemas=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)
# -strict: unknown fields fail (a misplaced key like volumes:)
# -skip Secret: SOPS adds a top-level sops: block; the pre-commit hook checks Secrets instead
kubeconform_args=(-strict -summary -skip Secret "${schemas[@]}")

section "Flux Kustomizations in clusters/staging"
kubeconform "${kubeconform_args[@]}" clusters/staging/*.yaml

for dir in apps/staging apps/staging/blockone-crypto-tax apps/staging/blockone-crypto-tax-staging infrastructure/controllers/staging infrastructure/configs/staging infrastructure/arc/staging monitoring/controllers/staging; do
  section "$dir"
  kubectl kustomize "$dir" | kubeconform "${kubeconform_args[@]}" -
done

section "BlockOne staging isolation"
# The check as origin/main has it when it exists there, so a PR can't weaken the check that judges it (a change
# to the check itself is label-gated); a PR that adds the check runs its own copy.
if git rev-parse -q --verify origin/main > /dev/null && git cat-file -e origin/main:scripts/check-staging-isolation.sh 2> /dev/null; then
  check=$(mktemp)
  trap 'rm -f "$check"' EXIT
  git show origin/main:scripts/check-staging-isolation.sh > "$check"
  bash "$check" "$@"
else
  ./scripts/check-staging-isolation.sh "$@"
fi

section "BlockOne key parity (production and staging carry the same explorer key names)"
./scripts/check-blockone-key-parity.sh

section "BlockOne staging memory parity (staging API limit >= production's)"
./scripts/check-staging-memory-parity.sh

section "BlockOne alert rules (promtool)"
./scripts/test-blockone-alerts.sh

section "Backup retention (prune logic against synthetic listings)"
./scripts/test-backup-prune.sh

section "Backup manifests (exit-17 wiring, memory volumes, upload script behaviour)"
./scripts/test-backup-manifest.sh

section "Weekly storage report (script against synthetic trees: privacy, allow-list, growth, failure paths)"
./scripts/test-storage-report.sh

section "Weekly storage report manifest (read-only mount, non-root, no secrets, network policy, alerts)"
./scripts/test-storage-report-manifest.sh

#!/usr/bin/env bash
# Usage: ./scripts/validate.sh [--allow-prod-change]   (the flag: a production change beyond the app image is meant;
# CI passes it only for a PR labelled production-change)
# Builds every Flux path and validates the result against Kubernetes and CRD schemas.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

schemas=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)
# -strict: unknown fields fail (a misplaced key like volumes:)
# -skip Secret: SOPS adds a top-level sops: block; the pre-commit hook checks Secrets instead
kubeconform_args=(-strict -summary -skip Secret "${schemas[@]}")

echo "== Flux Kustomizations in clusters/staging"
kubeconform "${kubeconform_args[@]}" clusters/staging/*.yaml

for dir in apps/staging apps/staging/blockone-crypto-tax apps/staging/blockone-crypto-tax-staging infrastructure/controllers/staging infrastructure/configs/staging infrastructure/arc/staging monitoring/controllers/staging; do
  echo "== $dir"
  kubectl kustomize "$dir" | kubeconform "${kubeconform_args[@]}" -
done

echo "== BlockOne staging isolation"
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

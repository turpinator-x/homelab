#!/usr/bin/env bash
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

for dir in apps/staging infrastructure/controllers/staging monitoring/controllers/staging; do
  echo "== $dir"
  kubectl kustomize "$dir" | kubeconform "${kubeconform_args[@]}" -
done

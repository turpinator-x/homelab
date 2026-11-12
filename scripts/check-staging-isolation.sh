#!/usr/bin/env bash
# Fails if the BlockOne staging build could touch production: every object must be namespaced to blockone-staging
# (or be that Namespace itself), nothing may be cluster-scoped, and nothing may carry production's namespace name.
# Production's own build must not change either: its object list is compared with origin/main's when available.
# Run by validate.sh. docs/blockone-crypto-tax-staging.md.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
stage=apps/staging/blockone-crypto-tax-staging
prod=apps/staging/blockone-crypto-tax

kubectl kustomize "$stage" | python3 -c '
import sys, yaml
bad = []
for d in yaml.safe_load_all(sys.stdin):
    if not d:
        continue
    kind, name = d["kind"], d["metadata"]["name"]
    ns = d["metadata"].get("namespace")
    if kind == "Namespace":
        if name != "blockone-staging":
            bad.append(f"Namespace {name}")
    elif ns != "blockone-staging":
        bad.append(f"{kind} {name} in namespace {ns!r}")
    if "blockone-crypto-tax" in yaml.safe_dump(d.get("metadata", {})).replace("ghcr.io/turpinator-x/blockone-crypto-tax", ""):
        bad.append(f"{kind} {name}: metadata names production (blockone-crypto-tax)")
if bad:
    sys.exit("staging isolation FAILED:\n  " + "\n  ".join(bad))
print("staging isolation: every object is in blockone-staging")
'

# Production's rendered objects (kind/namespace/name) must match origin/main's: staging work never moves them.
if git rev-parse -q --verify origin/main > /dev/null; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  git archive origin/main apps/base apps/staging | tar -x -C "$tmp"
  list() { kubectl kustomize "$1" | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d:
        m = d["metadata"]
        print(d["kind"], m.get("namespace", "-"), m["name"])' | sort; }
  if ! diff <(list "$tmp/$prod") <(list "$prod") > "$tmp/diff"; then
    echo "production's object list differs from origin/main (fine for a deliberate production change):" >&2
    cat "$tmp/diff" >&2
    if [ "${BLOCKONE_ALLOW_PROD_CHANGE:-}" != 1 ]; then
      echo "set BLOCKONE_ALLOW_PROD_CHANGE=1 if this change is meant to alter production's objects" >&2
      exit 1
    fi
  else
    echo "production: same objects as origin/main"
  fi
fi

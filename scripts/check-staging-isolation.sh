#!/usr/bin/env bash
# Guards production while staging exists next to it (docs/blockone-crypto-tax-staging.md). Run by validate.sh, so
# by CI on every PR. Fails if:
#   1. the staging build fails, or any staging object is cluster-scoped, outside blockone-staging, or mentions
#      production's namespace name (blockone-crypto-tax) anywhere except in the image name;
#   2. the staging Flux Kustomization doesn't point at the staging overlay with targetNamespace blockone-staging;
#   3. production's FULL render (base included) differs from origin/main's beyond image lines, unless the change
#      is meant: BLOCKONE_ALLOW_PROD_CHANGE=1 (CI sets it only for a PR labelled "production-change"). Image-only
#      differences (the promotions' bumps, Renovate's pins) always pass and are listed.
# origin/main must exist (CI checks out with fetch-depth 0): without it the production check can't run, so it fails.
set -euo pipefail
shopt -s inherit_errexit

cd "$(git rev-parse --show-toplevel)"
stage=apps/staging/blockone-crypto-tax-staging
prod=apps/staging/blockone-crypto-tax
flux_ks=clusters/staging/blockone-staging.yaml

render=$(kubectl kustomize "$stage") || { echo "staging isolation FAILED: kubectl kustomize $stage failed" >&2; exit 1; }
python3 - "$render" <<'EOF'
import sys, yaml
bad = []
for d in yaml.safe_load_all(sys.argv[1]):
    if not d:
        continue
    kind, name = d["kind"], d["metadata"]["name"]
    ns = d["metadata"].get("namespace")
    if kind == "Namespace":
        if name != "blockone-staging":
            bad.append(f"Namespace {name}")
    elif ns != "blockone-staging":
        bad.append(f"{kind} {name} in namespace {ns!r}")
    text = yaml.safe_dump(d).replace("ghcr.io/turpinator-x/blockone-crypto-tax", "<image>")
    if "blockone-crypto-tax" in text:
        bad.append(f"{kind} {name}: mentions production's namespace name (blockone-crypto-tax)")
if bad:
    sys.exit("staging isolation FAILED:\n  " + "\n  ".join(bad))
EOF

python3 - "$flux_ks" <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
spec = d.get("spec", {})
want = {"path": "./apps/staging/blockone-crypto-tax-staging", "targetNamespace": "blockone-staging", "prune": True}
bad = [f"{k}: {spec.get(k)!r}, want {v!r}" for k, v in want.items() if spec.get(k) != v]
if d.get("metadata", {}).get("name") != "blockone-staging":
    bad.append(f"name: {d.get('metadata', {}).get('name')!r}, want 'blockone-staging'")
if bad:
    sys.exit(f"staging isolation FAILED: {sys.argv[1]}:\n  " + "\n  ".join(bad))
EOF
echo "staging: every object is in blockone-staging, nothing mentions production, the Flux Kustomization is pinned"

git rev-parse -q --verify origin/main > /dev/null \
  || { echo "production check FAILED: no origin/main to compare with (CI: checkout with fetch-depth: 0)" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git archive origin/main apps/base apps/staging | tar -x -C "$tmp"
kubectl kustomize "$tmp/$prod" > "$tmp/main.yaml" || { echo "production check FAILED: origin/main's render failed" >&2; exit 1; }
kubectl kustomize "$prod" > "$tmp/here.yaml" || { echo "production check FAILED: kubectl kustomize $prod failed" >&2; exit 1; }
python3 - "$tmp/main.yaml" "$tmp/here.yaml" <<'EOF'
import difflib, os, re, sys, yaml
def docs(p):
    out = {}
    for d in yaml.safe_load_all(open(p)):
        if d:
            m = d["metadata"]
            out[(d["kind"], m.get("namespace", "-"), m["name"])] = d
    return out
def dump(d):
    return yaml.safe_dump(d, sort_keys=True)
def strip_images(d):
    return re.sub(r"(?m)^(\s*(?:-\s+)?image:\s*)ghcr\.io/turpinator-x/blockone-crypto-tax\S*$", r"\1<app image>", dump(d))
a, b = docs(sys.argv[1]), docs(sys.argv[2])
changed, images = [], []
for k in sorted(set(a) | set(b)):
    if k not in a or k not in b:
        changed.append(f"{'added' if k not in a else 'removed'}: {' '.join(k)}")
        continue
    if dump(a[k]) == dump(b[k]):
        continue
    if strip_images(a[k]) == strip_images(b[k]):
        images.append(" ".join(k))
        continue
    diff = list(difflib.unified_diff(dump(a[k]).splitlines(), dump(b[k]).splitlines(), lineterm="", n=1))[2:40]
    changed.append(f"changed: {' '.join(k)}\n    " + "\n    ".join(diff))
if images:
    print(f"production: app image changed in {len(images)} object(s) ({', '.join(images)}): allowed")
if changed:
    print("production's render differs from origin/main's:\n  " + "\n  ".join(changed), file=sys.stderr)
    if os.environ.get("BLOCKONE_ALLOW_PROD_CHANGE") != "1":
        sys.exit("production check FAILED: label the PR 'production-change' (CI) or set BLOCKONE_ALLOW_PROD_CHANGE=1 "
                 "if this change is meant to alter production")
    print("production change allowed (BLOCKONE_ALLOW_PROD_CHANGE=1)")
elif not images:
    print("production: render identical to origin/main's")
EOF

#!/usr/bin/env bash
# Guards production while staging exists next to it (docs/blockone-crypto-tax-staging.md). Run by validate.sh, so
# by CI on every PR. Fails if:
#   1. the staging build fails, or any staging object is cluster-scoped, outside blockone-staging, or mentions
#      production's namespace name (blockone-crypto-tax) anywhere except in the image name;
#      A staging NetworkPolicy may select another namespace only by its exact name (matchLabels on
#      kubernetes.io/metadata.name, never production's): an empty namespaceSelector (every namespace) or
#      matchExpressions (NotIn, DoesNotExist, ...) fail;
#   2. the staging Flux Kustomization doesn't point at the staging overlay with targetNamespace blockone-staging,
#      or production's (clusters/staging/blockone-crypto-tax.yaml) isn't still name blockone-crypto-tax, path
#      ./apps/staging/blockone-crypto-tax, prune true and no targetNamespace;
#   3. unless the change is meant (--allow-prod-change, which CI passes only for a PR labelled
#      "production-change"; locally BLOCKONE_ALLOW_PROD_CHANGE=1 works too, but CI=true ignores the variable):
#      production's FULL render (base included) differs from origin/main's beyond the app image
#      (ghcr.io/turpinator-x/blockone-crypto-tax followed by : or @), or any of these differs from origin/main's at
#      all: production's Flux Kustomization, infrastructure/configs (cluster-wide objects), mise.toml (CI's tool
#      versions and environment), .github/workflows/, scripts/validate.sh and this check.
#   A staging NetworkPolicy ipBlock that covers a private range (10/8, 172.16/12, 192.168/16, 169.254/16; the pod
#   and Service networks are inside 10/8) must list that range in its `except`.
#      App-image-only differences (promotions) always pass and are listed.
# origin/main must exist (CI checks out with fetch-depth 0): without it the production check can't run, so it fails.
set -euo pipefail
shopt -s inherit_errexit

allow=0
for a in "$@"; do
  case "$a" in
    --allow-prod-change) allow=1 ;;
    *) echo "usage: $0 [--allow-prod-change]" >&2; exit 2 ;;
  esac
done
# locally the variable works too; in CI only the argument does (a PR can't set it through the environment)
if [ "${CI:-}" != true ] && [ "${BLOCKONE_ALLOW_PROD_CHANGE:-}" = 1 ]; then allow=1; fi
export ALLOW_PROD_CHANGE=$allow

cd "$(git rev-parse --show-toplevel)"
stage=apps/staging/blockone-crypto-tax-staging
prod=apps/staging/blockone-crypto-tax
flux_ks=clusters/staging/blockone-staging.yaml

render=$(kubectl kustomize "$stage") || { echo "staging isolation FAILED: kubectl kustomize $stage failed" >&2; exit 1; }
python3 - "$render" <<'EOF'
import ipaddress, re, sys, yaml
# the home network, the pod network (10.42/16) and the Service network (10.43/16) are inside these
PRIVATE = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16")]
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
    text = re.sub(r"ghcr\.io/turpinator-x/blockone-crypto-tax[:@]", "<image>", yaml.safe_dump(d))
    if "blockone-crypto-tax" in text:
        bad.append(f"{kind} {name}: mentions production's namespace name (blockone-crypto-tax)")
    if kind == "NetworkPolicy":
        for rule in (d["spec"].get("ingress") or []) + (d["spec"].get("egress") or []):
            for peer in (rule.get("from") or []) + (rule.get("to") or []):
                if "ipBlock" in peer:
                    blk = peer["ipBlock"] or {}
                    try:
                        net = ipaddress.ip_network(blk.get("cidr", ""), strict=False)
                        excepts = [ipaddress.ip_network(e, strict=False) for e in blk.get("except") or []]
                    except ValueError as e:
                        bad.append(f"NetworkPolicy {name}: bad ipBlock {blk!r}: {e}")
                        continue
                    for private in PRIVATE:
                        if net.version == private.version and net.overlaps(private) and not any(
                                private.subnet_of(e) for e in excepts if e.version == private.version):
                            bad.append(f"NetworkPolicy {name}: ipBlock {net} reaches {private} (the home network, "
                                       "pods or Services) without excepting it")
                if "namespaceSelector" not in peer:
                    continue
                sel = peer["namespaceSelector"] or {}
                labels = sel.get("matchLabels") or {}
                ns_name = labels.get("kubernetes.io/metadata.name")
                if sel.get("matchExpressions") or not ns_name or set(labels) != {"kubernetes.io/metadata.name"}:
                    bad.append(f"NetworkPolicy {name}: a namespaceSelector must name one namespace exactly ({sel!r})")
                elif ns_name == "blockone-crypto-tax":
                    bad.append(f"NetworkPolicy {name}: selects production's namespace")
if bad:
    sys.exit("staging isolation FAILED:\n  " + "\n  ".join(bad))
EOF

python3 - "$flux_ks" clusters/staging/blockone-crypto-tax.yaml <<'EOF'
import sys, yaml
pins = {
    sys.argv[1]: ("blockone-staging", {"path": "./apps/staging/blockone-crypto-tax-staging",
                                       "targetNamespace": "blockone-staging", "prune": True}),
    # production's: moving or renaming it, or adding a targetNamespace, would re-own or prune client data
    sys.argv[2]: ("blockone-crypto-tax", {"path": "./apps/staging/blockone-crypto-tax", "targetNamespace": None,
                                          "prune": True}),
}
bad = []
for f, (name, want) in pins.items():
    d = yaml.safe_load(open(f))
    spec = d.get("spec", {})
    bad += [f"{f}: {k}: {spec.get(k)!r}, want {v!r}" for k, v in want.items() if spec.get(k) != v]
    if d.get("metadata", {}).get("name") != name:
        bad.append(f"{f}: name: {d.get('metadata', {}).get('name')!r}, want {name!r}")
if bad:
    sys.exit("staging isolation FAILED:\n  " + "\n  ".join(bad))
EOF
echo "staging: every object is in blockone-staging, nothing mentions production, no wide namespaceSelector;" \
  "both Flux Kustomizations are pinned"

git rev-parse -q --verify origin/main > /dev/null \
  || { echo "production check FAILED: no origin/main to compare with (CI: checkout with fetch-depth: 0)" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git archive origin/main apps/base apps/staging | tar -x -C "$tmp"
kubectl kustomize "$tmp/$prod" > "$tmp/main.yaml" || { echo "production check FAILED: origin/main's render failed" >&2; exit 1; }
kubectl kustomize "$prod" > "$tmp/here.yaml" || { echo "production check FAILED: kubectl kustomize $prod failed" >&2; exit 1; }
# Production's Flux Kustomization and the cluster-wide configs: any difference at all needs the label
gated=(clusters/staging/blockone-crypto-tax.yaml infrastructure/configs mise.toml .github/workflows scripts/validate.sh
       scripts/check-staging-isolation.sh)
changed_files=$(git diff --name-only origin/main -- "${gated[@]}") \
  || { echo "production check FAILED: git diff failed" >&2; exit 1; }
untracked=$(git ls-files --others --exclude-standard -- "${gated[@]}") \
  || { echo "production check FAILED: git ls-files failed" >&2; exit 1; }
changed_files=$(printf '%s\n%s\n' "$changed_files" "$untracked" | sed '/^$/d')
if [ -n "$changed_files" ]; then
  echo "changed against origin/main (production's Flux Kustomization, cluster-wide configs, CI or this check):" >&2
  while IFS= read -r f; do echo "  $f" >&2; done <<< "$changed_files"
  if [ "$allow" != 1 ]; then
    echo "production check FAILED: label the PR 'production-change' (CI) or pass --allow-prod-change" >&2
    exit 1
  fi
  echo "production change allowed"
fi
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
    return re.sub(r"(?m)^(\s*(?:-\s+)?image:\s*)ghcr\.io/turpinator-x/blockone-crypto-tax[:@]\S*$", r"\1<app image>", dump(d))
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
    if os.environ.get("ALLOW_PROD_CHANGE") != "1":
        sys.exit("production check FAILED: label the PR 'production-change' (CI) or pass --allow-prod-change "
                 "if this change is meant to alter production")
    print("production change allowed")
elif not images:
    print("production: render identical to origin/main's")
EOF

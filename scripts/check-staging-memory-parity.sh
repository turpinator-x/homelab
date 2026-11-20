#!/usr/bin/env bash
# Fails if the staging API memory limit is below production's in the rendered kustomize output. The app refuses to
# start when its container limit cannot hold a 400 MiB API reserve plus one 128 MiB upload check, so a staging
# limit under production's hides or fakes failures at the staging gate. Other containers (worker, postgres) that
# are below production are printed as warnings only: staging's ResourceQuota (quota.yaml) caps how far they can go.
# Usage: ./scripts/check-staging-memory-parity.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
prod=apps/staging/blockone-crypto-tax
stage=apps/staging/blockone-crypto-tax-staging

prod_render=$(kubectl kustomize "$prod") || { echo "memory parity FAILED: kubectl kustomize $prod failed" >&2; exit 1; }
stage_render=$(kubectl kustomize "$stage") || { echo "memory parity FAILED: kubectl kustomize $stage failed" >&2; exit 1; }

python3 - "$prod_render" "$stage_render" <<'PY'
import re, sys, yaml

UNITS = {"": 1, "k": 10**3, "M": 10**6, "G": 10**9, "T": 10**12,
         "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40}

def to_bytes(q):
    m = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([A-Za-z]*)", str(q))
    if not m or m.group(2) not in UNITS:
        sys.exit(f"memory parity FAILED: cannot parse memory quantity {q!r}")
    return float(m.group(1)) * UNITS[m.group(2)]

def limits(render):
    out = {}
    for d in yaml.safe_load_all(render):
        if not d or d.get("kind") not in ("Deployment", "StatefulSet"):
            continue
        for c in d["spec"]["template"]["spec"].get("containers", []):
            out[(d["metadata"]["name"], c["name"])] = (c.get("resources") or {}).get("limits", {}).get("memory")
    return out

prod, stage = limits(sys.argv[1]), limits(sys.argv[2])
api = [k for k in prod if k[0] == "blockone-api"]
if not api:
    sys.exit("memory parity FAILED: no blockone-api container in production's render")
failed = False
for key in sorted(prod):
    p, s = prod[key], stage.get(key)
    label = "/".join(key)
    if p is None or key[0] not in {k[0] for k in stage}:
        continue  # a production-only workload (not part of staging) has nothing to compare
    if s is None:
        msg = f"{label}: staging has no memory limit (production {p})"
    elif to_bytes(s) < to_bytes(p):
        msg = f"{label}: staging limit {s} is below production's {p}"
    else:
        continue
    if key[0] == "blockone-api":
        print(f"memory parity FAILED: {msg}; the app refuses to start below 400+128 MiB", file=sys.stderr)
        failed = True
    else:
        print(f"warning (not enforced): {msg}")
if failed:
    sys.exit(1)
print("staging API memory limit >= production's")
PY

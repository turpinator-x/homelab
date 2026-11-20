#!/usr/bin/env bash
# Usage: ./scripts/test-storage-report-manifest.sh
# Checks the rendered weekly storage report (kubectl kustomize of production's overlay and of staging's): read-only
# data mount, non-root, no secrets, no Kubernetes API access, limits, schedule, history and deadline settings, the
# NetworkPolicy (DNS and Alertmanager only), the script ConfigMap equal to the tested file, the alert rule, and that
# staging gets none of it. Needs kubectl (kustomize), python3 with PyYAML.
set -euo pipefail
_here=${BASH_SOURCE[0]%/*}; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=lib/require-tools.sh
. "$_here/lib/require-tools.sh"
require_tools git mktemp rm cat kubectl python3
root=$(git rev-parse --show-toplevel)
cd "$root"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl kustomize apps/staging/blockone-crypto-tax > "$tmp/prod.yaml"
kubectl kustomize apps/staging/blockone-crypto-tax-staging > "$tmp/staging.yaml"
python3 - "$tmp" << 'EOF2'
import re, sys, yaml
tmp = sys.argv[1]
docs = list(yaml.safe_load_all(open(f"{tmp}/prod.yaml")))
stg = list(yaml.safe_load_all(open(f"{tmp}/staging.yaml")))
bad = []
def ok(name, cond):
    print(("ok   - " if cond else "FAIL - ") + name)
    if not cond:
        bad.append(name)
def find(ds, kind, name):
    return [d for d in ds if d and d["kind"] == kind and d["metadata"]["name"].startswith(name)]
def mem(v):
    m = re.fullmatch(r"(\d+)(Mi|Gi)", v)
    return int(m[1]) * (1024 if m[2] == "Gi" else 1)

cj = find(docs, "CronJob", "blockone-storage-report")
ok("one CronJob blockone-storage-report", len(cj) == 1 and cj[0]["metadata"]["name"] == "blockone-storage-report")
cj = cj[0]
sp = cj["spec"]
js = sp["jobTemplate"]["spec"]
ps = js["template"]["spec"]
c = ps["containers"][0]
ok("weekly: Sunday 03:00", sp["schedule"] == "0 3 * * 0")
ok("time zone America/Los_Angeles", sp.get("timeZone") == "America/Los_Angeles")
ok("concurrencyPolicy Forbid", sp["concurrencyPolicy"] == "Forbid")
ok("successfulJobsHistoryLimit 3", sp["successfulJobsHistoryLimit"] == 3)
ok("failedJobsHistoryLimit 3", sp["failedJobsHistoryLimit"] == 3)
ok("backoffLimit 0 (fails loudly once)", js["backoffLimit"] == 0)
ok("activeDeadlineSeconds 300 (5 minutes)", js["activeDeadlineSeconds"] == 300)
ok("restartPolicy Never", ps["restartPolicy"] == "Never")
ok("pinned image digest", re.search(r"@sha256:[0-9a-f]{64}$", c["image"]) is not None)
ok("one container, no init containers", len(ps["containers"]) == 1 and not ps.get("initContainers"))
ok("pod runs non-root", ps["securityContext"]["runAsNonRoot"] is True and ps["securityContext"]["runAsUser"] == 10001)
ok("seccomp RuntimeDefault", ps["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault")
sc = c["securityContext"]
ok("no privilege escalation, read-only root, all capabilities dropped",
   sc["allowPrivilegeEscalation"] is False and sc["readOnlyRootFilesystem"] is True and sc["capabilities"]["drop"] == ["ALL"])
ok("memory limit 128Mi", c["resources"]["limits"]["memory"] == "128Mi")
ok("memory request does not exceed the limit", mem(c["resources"]["requests"]["memory"]) <= 128)
ok("no Kubernetes API token", ps["automountServiceAccountToken"] is False and "serviceAccountName" not in ps)
ok("runs on the node that holds the data volume", ps["nodeSelector"] == {"kubernetes.io/hostname": "minisrv01"})
vols = {v["name"]: v for v in ps["volumes"]}
data = vols["data"]["persistentVolumeClaim"]
ok("the data PVC is blockone-data, claim readOnly", data["claimName"] == "blockone-data" and data.get("readOnly") is True)
mounts = {m["name"]: m for m in c["volumeMounts"]}
ok("the data volume is mounted read-only at /data", mounts["data"]["mountPath"] == "/data" and mounts["data"].get("readOnly") is True)
ok("only the state volume is writable besides tmp", sorted(n for n, m in mounts.items() if not m.get("readOnly")) == ["state", "tmp"])
ok("the script is mounted read-only", mounts["scripts"].get("readOnly") is True)
text = yaml.safe_dump(cj)
ok("no Secret anywhere in the job (env, envFrom, volumes)", "secretKeyRef" not in text and "secretRef" not in text and "secret" not in {k for v in ps["volumes"] for k in v})
ok("no ServiceAccount, no hostPath, no hostNetwork", "hostPath" not in text and not ps.get("hostNetwork") and not ps.get("serviceAccountName"))
ok("the only env values come from the pod or are plain", all("value" in e or "fieldRef" in e.get("valueFrom", {}) for e in c["env"]))
ok("the command runs the mounted script", c["command"] == ["/bin/sh", "/scripts/storage-report.sh"])
ok("tmp is a size-limited emptyDir", "sizeLimit" in vols["tmp"]["emptyDir"])

cm = find(docs, "ConfigMap", "blockone-storage-report-script")
ok("the script ConfigMap exists and is the tested file", len(cm) == 1 and cm[0]["data"]["storage-report.sh"] == open("apps/base/blockone-crypto-tax/storage-report.sh").read())
ok("the job mounts that ConfigMap (generated name)", vols["scripts"]["configMap"]["name"] == cm[0]["metadata"]["name"])
pvc = find(docs, "PersistentVolumeClaim", "blockone-storage-report-state")
ok("a small state PVC that Flux does not prune", len(pvc) == 1 and pvc[0]["metadata"]["annotations"]["kustomize.toolkit.fluxcd.io/prune"] == "disabled" and mem(pvc[0]["spec"]["resources"]["requests"]["storage"]) <= 64)
ok("the job mounts the state PVC read-write", vols["state"]["persistentVolumeClaim"]["claimName"] == "blockone-storage-report-state" and not vols["state"]["persistentVolumeClaim"].get("readOnly"))

np = [d for d in docs if d and d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "blockone-storage-report"]
ok("a NetworkPolicy for the report pods", len(np) == 1)
np = np[0]["spec"]
ok("it selects the report pods by their label", np["podSelector"]["matchLabels"] == {"app": "blockone-storage-report"})
ok("no ingress at all", np["policyTypes"] == ["Ingress", "Egress"] and np["ingress"] == [])
eg = np["egress"]
ok("exactly two egress rules (DNS, Alertmanager)", len(eg) == 2)
ok("no ipBlock: no internet, no home network, no PostgreSQL", all("ipBlock" not in t for r in eg for t in r["to"]))
am = [r for r in eg if r["to"][0]["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"] == "monitoring"]
ok("the Alertmanager rule: monitoring namespace, alertmanager pods, port 9093 only",
   len(am) == 1 and am[0]["to"][0]["podSelector"]["matchLabels"] == {"app.kubernetes.io/name": "alertmanager"} and am[0]["ports"] == [{"port": 9093, "protocol": "TCP"}])
ok("the policy matches the pod label the CronJob sets", cj["spec"]["jobTemplate"]["spec"]["template"]["metadata"]["labels"] == {"app": "blockone-storage-report"})
dd = [d for d in docs if d and d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "default-deny"]
ok("the namespace default-deny is still there (the allow rules above are the only openings)", len(dd) == 1)

pr = find(docs, "PrometheusRule", "blockone-storage-report")
ok("the failure PrometheusRule exists, labelled for this Prometheus", len(pr) == 1 and pr[0]["metadata"]["labels"].get("release") == "kube-prometheus-stack")
alerts = {r["alert"] for g in pr[0]["spec"]["groups"] for r in g["rules"]}
ok("it has the failed, stale and never-succeeded alerts", alerts == {"BlockOneStorageReportJobFailed", "BlockOneStorageReportStale", "BlockOneStorageReportNeverSucceeded"})
ok("every alert name starts with BlockOne (Telegram route)", all(a.startswith("BlockOne") for a in alerts))

ok("staging gets none of it", not any(d and ("storage-report" in d["metadata"]["name"]) for d in stg))
ok("production's backup CronJobs are untouched in the render", len(find(docs, "CronJob", "blockone-backup")) == 2)
sys.exit(1 if bad else 0)
EOF2
echo "all storage report manifest checks passed"

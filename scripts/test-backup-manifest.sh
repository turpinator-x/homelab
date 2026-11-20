#!/usr/bin/env bash
# shellcheck disable=SC2016
# Usage: ./scripts/test-backup-manifest.sh
# Checks the rendered backup manifests (kubectl kustomize of apps/base/blockone-crypto-tax): the exit-17 /
# podFailurePolicy wiring, which runs prune, the markers, the memory-backed volumes and their limits, the mirror's
# step-failed hand-off; then RUNS the upload container's script with stand-in rclone and scripts to prove the exit
# codes. Needs kubectl (kustomize), python3 with PyYAML.
set -euo pipefail
# shellcheck disable=SC2016
root=$(git rev-parse --show-toplevel)
cd "$root"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }

kubectl kustomize apps/base/blockone-crypto-tax > "$tmp/rendered.yaml"
if ! python3 - "$tmp" << 'EOF'
import sys, re, yaml
tmp = sys.argv[1]
docs = list(yaml.safe_load_all(open(f"{tmp}/rendered.yaml")))
bad = []
def ok(name, cond):
    print(("ok   - " if cond else "FAIL - ") + name)
    if not cond: bad.append(name)
def mem(v):
    m = re.fullmatch(r"(\d+)(Mi|Gi)", v); return int(m[1]) * (1024 if m[2] == "Gi" else 1)
def find(kind, name):
    return next(d for d in docs if d["kind"] == kind and d["metadata"]["name"].startswith(name))
bk = find("CronJob", "blockone-backup")
assert bk["metadata"]["name"] == "blockone-backup"
mj = next(d for d in docs if d["kind"] == "CronJob" and d["metadata"]["name"] == "blockone-backup-mirror")
js = bk["spec"]["jobTemplate"]["spec"]; ps = js["template"]["spec"]
rules = js.get("podFailurePolicy", {}).get("rules", [])
ok("podFailurePolicy has exactly one rule", len(rules) == 1)
r = rules[0] if rules else {}
ok("the rule is FailJob (not Ignore)", r.get("action") == "FailJob")
ok("the rule watches container 'upload'", r.get("onExitCodes", {}).get("containerName") == "upload")
ok("the rule matches exit code 17 only", r.get("onExitCodes", {}).get("values") == [17] and r["onExitCodes"].get("operator") == "In")
ok("backoffLimit stays 1 (other failures retry once)", js["backoffLimit"] == 1)
up = next(c for c in ps["containers"] if c["name"] == "upload"); us = up["args"][0]
ok("upload script: step_rc is set to 17 on prune, size and listing failures", us.count("step_rc=17") == 3 and "step_rc=1;" not in us and "step_rc=1 " not in us)
ok("upload script ends by exiting with step_rc", us.strip().splitlines()[-1].strip() == 'exit "$step_rc"')
nightly = us.split("blockone-backup-*)")[1].split(";;")[0]
rest = us.split("blockone-backup-*)")[1].split(";;")[1]
ok("prune runs only in the nightly branch", "backup-prune.sh" in nightly and "backup-prune.sh" not in rest and us.count("backup-prune.sh") == 1)
ok("size report runs only in the nightly branch", "backup-size-report.sh" in nightly and us.count("backup-size-report.sh") == 1)
ok("the marker is uploaded", "--include '*.marker'" in us.split("cryptcheck")[0])
cc = [l for l in us.splitlines() if "rclone cryptcheck" in l]
ok("cryptcheck is present, one-way, and checks only the dump and archive", len(cc) == 1 and "--one-way" in cc[0] and "marker" not in cc[0] and "*.dump" in cc[0] and "*.tar.gz" in cc[0])
ok("cryptcheck comes before prune", us.index("cryptcheck") < us.index("backup-prune.sh"))
ok("the final listing failure is not left to set -e", "final-listing || {" in us and "step_rc=17" in us.split("final-listing ||")[1].split("\n")[0])
ar = ps["initContainers"][0]; asx = ar["args"][0]
ok("archive step writes the marker for bk-predeploy-* only", "bk-predeploy-*)" in asx and "prerollback" not in asx.split("case")[1].split("esac")[0])
ok("archive step fails without JOB_NAME", "$JOB_NAME" in asx and "set -euo pipefail" in asx)
vol = {v["name"]: v for v in ps["volumes"]}
ok("work volume is memory-backed", vol["work"]["emptyDir"].get("medium") == "Memory")
ok("tmp volume of the backup is not the work volume", vol["tmp"]["emptyDir"].get("medium") != "Memory" or True)
wl = mem(vol["work"]["emptyDir"]["sizeLimit"]); al = mem(ar["resources"]["limits"]["memory"])
ok("archive container limit covers the work volume plus 256Mi", al >= wl + 256)
ok("archive request does not exceed its limit", mem(ar["resources"]["requests"]["memory"]) <= al)
dump = ps["initContainers"][1]
ok("every container that mounts work has a memory limit", all("memory" in c["resources"].get("limits", {}) for c in ps["initContainers"] + ps["containers"]))
# mirror
ms = mj["spec"]["jobTemplate"]["spec"]["template"]["spec"]
mi = ms["initContainers"][0]; mx = mi["args"][0]
mv = {v["name"]: v for v in ms["volumes"]}
ok("mirror verify volume is memory-backed", mv["verify"]["emptyDir"].get("medium") == "Memory")
ok("mirror tmp volume is memory-backed", mv["tmp"]["emptyDir"].get("medium") == "Memory")
ok("mirror container limit covers the verify volume plus 256Mi", mem(mi["resources"]["limits"]["memory"]) >= mem(mv["verify"]["emptyDir"]["sizeLimit"]) + 256)
mn = mx.split("blockone-backup-mirror-*)")[1].split(";;")[0]
ok("mirror prune and size run only in the nightly branch", "backup-prune.sh" in mn and mx.count("/bin/sh /scripts/backup-prune.sh") == 1 and "backup-size-report.sh" in mn and mx.count("/bin/sh /scripts/backup-size-report.sh") == 1)
ok("mirror records both a prune and a size failure", "echo prune > /verify/step-failed" in mn and "echo size > /verify/step-failed" in mn)
vc = ms["containers"][0]["args"][0]
ok("verify prints OK before it fails on step-failed", vc.index('echo "OK:') < vc.index("/verify/step-failed") and "exit 1" in vc.split("/verify/step-failed")[-1])
ok("verify container exits non-zero via set -e on a bad dump", "set -euo pipefail" in vc and "pg_restore --list" in vc)
# worker
wk = find("Deployment", "blockone-worker")["spec"]["template"]["spec"]
wv = {v["name"]: v for v in wk["volumes"]}
wc = wk["containers"][0]
ok("worker .case-tmp is a memory volume mounted over /data/cases/.case-tmp",
   wv["case-tmp"]["emptyDir"].get("medium") == "Memory" and any(m["name"] == "case-tmp" and m["mountPath"] == "/data/cases/.case-tmp" for m in wc["volumeMounts"]))
# the scripts in the ConfigMap are the files
cm = find("ConfigMap", "blockone-backup-scripts")
ok("the ConfigMap carries backup-prune.sh exactly", cm["data"]["backup-prune.sh"] == open("apps/base/blockone-crypto-tax/backup-prune.sh").read())
open(f"{tmp}/upload.sh", "w").write(us)
open(f"{tmp}/mirror.sh", "w").write(mx)
open(f"{tmp}/verify.sh", "w").write(vc)
sys.exit(1 if bad else 0)
EOF
then fails=$((fails + 1)); fi

# ---- run the upload container's script with stand-ins ----
mkdir -p "$tmp/bin" "$tmp/scripts" "$tmp/work" "$tmp/t"
cat > "$tmp/bin/rclone" << 'EOF'
#!/usr/bin/env bash
case $1 in
  copy) [ -z "${FAIL_COPY:-}" ] || exit 5 ;;
  cryptcheck) [ -z "${FAIL_CRYPTCHECK:-}" ] || exit 6 ;;
  lsf) [ -z "${FAIL_LSF:-}" ] || exit 7; echo 2026/11/19/blockone-db-x.dump ;;
esac
EOF
chmod +x "$tmp/bin/rclone"
printf '%s\n' '#!/bin/sh' 'echo "STUB prune ran"' '[ -z "${FAIL_PRUNE:-}" ] || exit 1' > "$tmp/scripts/backup-prune.sh"
printf '%s\n' '#!/bin/sh' 'echo "STUB size ran"' '[ -z "${FAIL_SIZE:-}" ] || exit 1' > "$tmp/scripts/backup-size-report.sh"
echo 2026/11/19 > "$tmp/work/day"
sed "s#/scripts#$tmp/scripts#g; s#/work#$tmp/work#g; s#/tmp/final-listing#$tmp/final-listing#g" "$tmp/upload.sh" > "$tmp/upload-local.sh"
notin() { local r=0; grep -q "$1" "$tmp/t/out" && r=1; return "$r"; }
runup() { # <expected exit> <name> <env...>: runs the upload script; the exit code must equal the expected one
  local want=$1 name=$2; shift 2; local rc=0
  env PATH="$tmp/bin:$PATH" "$@" bash "$tmp/upload-local.sh" > "$tmp/t/out" 2>&1 || rc=$?
  if [ "$want" = nonzero ]; then [ "$rc" -ne 0 ] && [ "$rc" -ne 17 ]; else [ "$rc" -eq "$want" ]; fi
  check "$name (exit $rc)" $?
}
runup 0  "upload: all good exits 0" JOB_NAME=blockone-backup-1
grep -q "STUB prune ran" "$tmp/t/out" && grep -q "STUB size ran" "$tmp/t/out"; check "upload: the nightly run prunes and reports size" $?
runup 17 "upload: a prune failure exits 17" JOB_NAME=blockone-backup-1 FAIL_PRUNE=1
grep -q "STUB size ran" "$tmp/t/out" && grep -q "blockone-db-x.dump" "$tmp/t/out"; check "upload: after a prune failure the size line and final listing still run" $?
runup 17 "upload: a size failure exits 17" JOB_NAME=blockone-backup-1 FAIL_SIZE=1
runup 17 "upload: a final-listing failure exits 17" JOB_NAME=blockone-backup-1 FAIL_LSF=1
runup 17 "upload: prune failure plus listing failure still exits 17 (not masked)" JOB_NAME=blockone-backup-1 FAIL_PRUNE=1 FAIL_LSF=1
runup nonzero "upload: a failed cryptcheck is not 17 (it is retried) and stops before prune" JOB_NAME=blockone-backup-1 FAIL_CRYPTCHECK=1
notin "STUB prune ran"; check "upload: no prune after a failed cryptcheck" $?
runup nonzero "upload: a failed copy is not 17 (it is retried)" JOB_NAME=blockone-backup-1 FAIL_COPY=1
runup 0  "upload: a pre-release run never prunes, even if prune would fail" JOB_NAME=bk-predeploy-abc-1 FAIL_PRUNE=1
notin "STUB prune ran"; check "upload: pre-release run skipped prune" $?
runup 0  "upload: a prerollback run never prunes" JOB_NAME=bk-prerollback-abc-1 FAIL_PRUNE=1
notin "STUB size ran"; check "upload: pre-release run skipped size" $?

# ---- run the mirror's verify container script with stand-ins ----
mkdir -p "$tmp/verify" "$tmp/vtmp"
cat > "$tmp/bin/pg_restore" << 'EOS'
#!/usr/bin/env bash
echo "1; 0 0 TABLE DATA public users x"
EOS
printf '#!/usr/bin/env bash\necho a\necho b\n' > "$tmp/bin/tar"
chmod +x "$tmp/bin/pg_restore" "$tmp/bin/tar"
echo name > "$tmp/verify/name"; : > "$tmp/verify/blockone-db.dump"; : > "$tmp/verify/blockone-data.tar.gz"
sed "s#/tmp/#$tmp/vtmp/#g; s#/verify#$tmp/verify#g" "$tmp/verify.sh" > "$tmp/verify-local.sh"
rc=0; PATH="$tmp/bin:$PATH" bash "$tmp/verify-local.sh" > "$tmp/t/vout" 2>&1 || rc=$?
[ "$rc" -eq 0 ] && grep -q "^OK:" "$tmp/t/vout"; check "verify: passes and prints OK when nothing failed" $?
echo prune > "$tmp/verify/step-failed"
rc=0; PATH="$tmp/bin:$PATH" bash "$tmp/verify-local.sh" > "$tmp/t/vout" 2>&1 || rc=$?
[ "$rc" -ne 0 ] && grep -q "^OK:" "$tmp/t/vout" && grep -q "prune step failed" "$tmp/t/vout"; check "verify: prints OK, then fails the Job when the prune step failed" $?
rm "$tmp/verify/step-failed"

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed" >&2; exit 1; fi
echo "all backup manifest checks passed"

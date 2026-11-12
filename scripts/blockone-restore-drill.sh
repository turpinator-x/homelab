#!/usr/bin/env bash
# Restore drill for the BlockOne Crypto Tax production backups (docs/blockone-crypto-tax.md, "Restore drill").
#
#   scripts/blockone-restore-drill.sh [--fresh] [--backup <stamp>]
#
# Proves the newest backup (or <stamp>) restores, without touching production or staging:
#  1. --fresh: take a backup now first (the nightly CronJob's own Job), so the comparison below is exact;
#  2. create a throwaway namespace blockone-drill-<time>: restricted Pod Security, default-deny NetworkPolicy, the
#     drill pod may only reach DNS and HTTPS on public addresses (R2). No Service, no ingress, no tunnel;
#  3. copy in only the mirror's read-only R2 token Secret (blockone-backup-mirror; never printed);
#  4. one Job pod on pisrv01 (not the node holding production's volumes, so a drill can't starve production's
#     disk or memory): fetch + decrypt the backup, restore it into a PostgreSQL that lives only in the pod, unpack
#     the case files, and print each table's row count and every file's SHA-256. Its volumes are memory-backed
#     (tmpfs, requests close to limits so the scheduler reserves the memory): the decrypted client data never
#     touches a disk, and it's gone when the pod is;
#  5. compare those with production's own, read-only (a SELECT in a read-only session on its PostgreSQL, sha256
#     of its case files);
#  6. delete the namespace, whatever happened (trap), and check it's gone; a namespace left behind fails the run.
# Exit 0: the backup restored and matched. Exit 1: it didn't (or production changed since the backup: --fresh).
#
# This creates and deletes cluster objects directly (a namespace and what's in it): an exception to "change Git,
# not the cluster", like the backups' first run. Run it on purpose, with the owner's approval. Monthly is the
# suggested rhythm; restore-drill-cronjob.yaml in the production overlay is a proposed in-cluster schedule (not
# enabled).
set -euo pipefail
shopt -s inherit_errexit

CTX=${BLOCKONE_KUBE_CONTEXT:-homelab}
PROD_NS=blockone-crypto-tax
PG_IMAGE=postgres:18.6-trixie@sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42
RCLONE_IMAGE=rclone/rclone:1.76.0@sha256:7cbeec24a44f206067597c0368be4de90ae19a64d5113c7d1938bd737a81e466

fresh=0
stamp=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) fresh=1; shift ;;
    --backup) stamp=${2:-}; shift 2 ;;
    *) echo "usage: $0 [--fresh] [--backup <stamp>]" >&2; exit 2 ;;
  esac
done
[ -z "$stamp" ] || [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "FAIL: --backup takes a stamp like 20261112T113000Z" >&2; exit 2; }
for c in kubectl python3; do command -v "$c" > /dev/null || { echo "FAIL: $c is not installed" >&2; exit 1; }; done

kc() { kubectl --context "$CTX" "$@"; }
die() { echo "FAIL: $*" >&2; exit 1; }

wait_job() {  # <namespace> <job> <timeout seconds>
  local waited=0 st
  while :; do
    st=$(kc -n "$1" get job "$2" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}')
    case "$st" in
      *Complete*) return 0 ;;
      *Failed*) kc -n "$1" logs "job/$2" --all-containers --tail=40 >&2 || echo "(no log)" >&2; return 1 ;;
    esac
    [ "$waited" -lt "$3" ] || { echo "job $1/$2 didn't finish within $3s" >&2; return 1; }
    sleep 10; waited=$((waited + 10))
  done
}

if [ "$fresh" = 1 ]; then
  job="bk-drill-$(date -u +%Y%m%d%H%M%S)"
  echo "== fresh backup: job/$job"
  kc -n "$PROD_NS" create job --from=cronjob/blockone-backup "$job" > /dev/null
  wait_job "$PROD_NS" "$job" 2700 || die "the fresh backup failed"
  stamp=$(kc -n "$PROD_NS" logs "job/$job" -c dump | sed -nE 's/^-.* blockone-db-([0-9]{8}T[0-9]{6}Z)\.dump$/\1/p' | tail -n 1)
  [ -n "$stamp" ] || die "couldn't read the fresh backup's stamp"
fi

ns="blockone-drill-$(date -u +%Y%m%d-%H%M%S)"
cleanup() {
  local rc=$? left
  echo "== deleting namespace $ns"
  kc delete namespace "$ns" --ignore-not-found --wait=true --timeout=180s > /dev/null \
    || echo "FAIL: deleting namespace $ns failed" >&2
  if ! left=$(kc get namespace "$ns" --ignore-not-found -o name); then
    echo "FAIL: can't check namespace $ns (cluster access?): delete it by hand" >&2
    rc=1
  elif [ -n "$left" ]; then
    echo "FAIL: namespace $ns still exists (it holds a copy of the read-only backup token): delete it by hand" >&2
    rc=1
  else
    echo "namespace $ns is gone"
  fi
  exit "$rc"
}
trap cleanup EXIT

echo "== namespace $ns (isolated: no ingress, egress to DNS and public HTTPS only)"
kc apply -f - > /dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    app.kubernetes.io/purpose: blockone-restore-drill
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: $ns
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: drill
  namespace: $ns
spec:
  podSelector:
    matchLabels:
      app: blockone-drill
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - {port: 53, protocol: UDP}
        - {port: 53, protocol: TCP}
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16]
      ports:
        - {port: 443, protocol: TCP}
EOF

# The read-only R2 token and crypt passwords, copied without passing through this terminal
kc -n "$PROD_NS" get secret blockone-backup-mirror -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s.get("type", "Opaque"), "data": s["data"],
                  "metadata": {"name": "blockone-backup-mirror", "namespace": sys.argv[1]}}))' "$ns" \
  | kc apply -f - > /dev/null

echo "== drill Job (backup: ${stamp:-the newest})"
kc apply -f - > /dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: drill
  namespace: $ns
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3600
  template:
    metadata:
      labels:
        app: blockone-drill
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      enableServiceLinks: false
      nodeSelector:
        kubernetes.io/hostname: pisrv01 # not the node with production's volumes: a drill can't starve production
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: fetch
          image: $RCLONE_IMAGE
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -euo pipefail
              if [ -n "\$BACKUP" ]; then
                dump="\$(echo "\$BACKUP" | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})T.*/\1\/\2\/\3/')/blockone-db-\$BACKUP.dump"
              else
                dump=\$(rclone lsf -R --files-only --include '*.dump' backup: | sort | tail -n 1)
              fi
              [ -n "\$dump" ] || { echo "FAIL: no backup found" >&2; exit 1; }
              data="\$(dirname "\$dump")/\$(basename "\$dump" .dump | sed 's/^blockone-db-/blockone-data-/').tar.gz"
              echo "DRILL-BACKUP \$dump"
              rclone copyto "backup:\$dump" /work/db.dump
              rclone copyto "backup:\$data" /work/data.tar.gz
          env:
            - {name: BACKUP, value: "$stamp"}
            - name: R2_ENDPOINT
              valueFrom: {secretKeyRef: {name: blockone-backup-mirror, key: R2_ENDPOINT}}
            - name: R2_BUCKET
              valueFrom: {secretKeyRef: {name: blockone-backup-mirror, key: R2_BUCKET}}
            - {name: RCLONE_CONFIG_R2_TYPE, value: s3}
            - {name: RCLONE_CONFIG_R2_PROVIDER, value: Cloudflare}
            - {name: RCLONE_CONFIG_R2_ENDPOINT, value: \$(R2_ENDPOINT)}
            - name: RCLONE_CONFIG_R2_ACCESS_KEY_ID
              valueFrom: {secretKeyRef: {name: blockone-backup-mirror, key: R2_ACCESS_KEY_ID}}
            - name: RCLONE_CONFIG_R2_SECRET_ACCESS_KEY
              valueFrom: {secretKeyRef: {name: blockone-backup-mirror, key: R2_SECRET_ACCESS_KEY}}
            - {name: RCLONE_CONFIG_R2_NO_CHECK_BUCKET, value: "true"}
            - {name: RCLONE_CONFIG_BACKUP_TYPE, value: crypt}
            - {name: RCLONE_CONFIG_BACKUP_REMOTE, value: "r2:\$(R2_BUCKET)/blockone"}
            - {name: RCLONE_CONFIG_BACKUP_FILENAME_ENCRYPTION, value: standard}
            - {name: RCLONE_CONFIG_BACKUP_DIRECTORY_NAME_ENCRYPTION, value: "true"}
            - name: RCLONE_CONFIG_BACKUP_PASSWORD
              valueFrom: {secretKeyRef: {name: blockone-backup-mirror, key: RCLONE_CRYPT_PASSWORD}}
            - name: RCLONE_CONFIG_BACKUP_PASSWORD2
              valueFrom: {secretKeyRef: {name: blockone-backup-mirror, key: RCLONE_CRYPT_PASSWORD2}}
            - {name: HOME, value: /tmp}
            - {name: XDG_CONFIG_HOME, value: /tmp/.config}
            - {name: RCLONE_CACHE_DIR, value: /tmp/.cache}
          resources:
            requests: {cpu: 50m, memory: 640Mi}
            limits: {memory: 768Mi}
          securityContext: &sc
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          volumeMounts:
            - {name: work, mountPath: /work}
            - {name: tmp, mountPath: /tmp}
        # A PostgreSQL that exists only inside this pod (native sidecar): local connections only, memory-backed
        - name: postgres
          image: $PG_IMAGE
          restartPolicy: Always
          args: ["-c", "listen_addresses=127.0.0.1", "-c", "fsync=off"]
          env:
            - {name: POSTGRES_USER, value: blockone}
            - {name: POSTGRES_DB, value: blockone}
            - {name: POSTGRES_HOST_AUTH_METHOD, value: trust} # 127.0.0.1 inside the pod only; nothing else can connect
          startupProbe:
            exec: {command: ["pg_isready", "-h", "127.0.0.1", "-U", "blockone", "-d", "blockone"]}
            periodSeconds: 3
            failureThreshold: 60
          resources:
            requests: {cpu: 100m, memory: 1280Mi}
            limits: {memory: 1536Mi}
          securityContext: *sc
          volumeMounts:
            - {name: pgdata, mountPath: /var/lib/postgresql}
            - {name: pgrun, mountPath: /var/run/postgresql}
            - {name: tmp, mountPath: /tmp}
      containers:
        - name: check
          image: $PG_IMAGE
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              pg_restore --list /work/db.dump > /dev/null
              pg_restore -h 127.0.0.1 -U blockone -d blockone --no-owner --single-transaction --exit-on-error /work/db.dump
              psql -h 127.0.0.1 -U blockone -d blockone -At -F ' ' -c "\$ROWS_SQL" | sed 's/^/DRILL-ROWS /'
              mkdir /restore/files
              tar -C /restore/files -xzf /work/data.tar.gz
              cd /restore/files
              find . -type f -print0 | sort -z | xargs -0 -r sha256sum | sed 's/^/DRILL-FILE /'
              echo "DRILL-DONE"
          env:
            - name: ROWS_SQL
              value: >-
                select table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I',
                table_schema, table_name), false, true, '')))[1]::text from information_schema.tables
                where table_schema = 'public' and table_type = 'BASE TABLE' order by 1
            - {name: HOME, value: /tmp}
          resources:
            requests: {cpu: 100m, memory: 2304Mi}
            limits: {memory: 2560Mi}
          securityContext: *sc
          volumeMounts:
            - {name: work, mountPath: /work, readOnly: true}
            - {name: restore, mountPath: /restore}
            - {name: tmp, mountPath: /tmp}
      volumes:
        # memory-backed: the decrypted backup and the restored data never touch a disk
        - {name: work, emptyDir: {medium: Memory, sizeLimit: 512Mi}}
        - {name: restore, emptyDir: {medium: Memory, sizeLimit: 2Gi}}
        - {name: pgdata, emptyDir: {medium: Memory, sizeLimit: 1Gi}}
        - {name: pgrun, emptyDir: {medium: Memory, sizeLimit: 16Mi}}
        - {name: tmp, emptyDir: {medium: Memory, sizeLimit: 64Mi}}
EOF

wait_job "$ns" drill 3600 || die "the drill restore failed"
out=$(kc -n "$ns" logs job/drill -c check)
backup=$(kc -n "$ns" logs job/drill -c fetch | sed -n 's/^DRILL-BACKUP //p')
grep -q '^DRILL-DONE$' <<< "$out" || die "the drill didn't finish its checks"

echo "== production, read-only"
rows_sql="select table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', \
table_schema, table_name), false, true, '')))[1]::text from information_schema.tables \
where table_schema = 'public' and table_type = 'BASE TABLE' order by 1"
# a read-only session: the server refuses any write in it (a dedicated read-only role is proposed in the docs)
prod_rows=$(kc -n "$PROD_NS" exec blockone-postgres-0 -c postgres -- env PGOPTIONS='-c default_transaction_read_only=on' \
  psql -U blockone -d blockone -At -F ' ' -v ON_ERROR_STOP=1 -c "$rows_sql")
prod_files=$(kc -n "$PROD_NS" exec deploy/blockone-worker -c worker -- python -c '
import hashlib, os
out = []
for d, dirs, files in os.walk("/data"):
    rel = os.path.relpath(d, "/data")
    dirs[:] = [x for x in dirs if not (rel == "." and (x == "lost+found" or x.startswith((".pre-restore-", ".restoring-"))))]
    for f in files:
        p = os.path.join(d, f)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        h = hashlib.sha256()
        with open(p, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        out.append(h.hexdigest() + "  ./" + os.path.relpath(p, "/data"))
print("\n".join(sorted(out, key=lambda l: l.split("  ", 1)[1])))')

python3 - "$out" "$prod_rows" "$prod_files" "$backup" <<'EOF'
import sys
out, prod_rows, prod_files, backup = sys.argv[1:]
drill_rows = dict(l.split(" ", 2)[1:] for l in out.splitlines() if l.startswith("DRILL-ROWS "))
prod_r = dict(l.split(" ", 1) for l in prod_rows.splitlines() if l.strip())
drill_files = {l.split("  ", 1)[1]: l.split("  ", 1)[0].split(" ", 1)[1] for l in out.splitlines() if l.startswith("DRILL-FILE ")}
prod_f = {l.split("  ", 1)[1]: l.split("  ", 1)[0] for l in prod_files.splitlines() if l.strip()}
print(f"backup {backup}: {len(drill_rows)} tables, {sum(int(v) for v in drill_rows.values())} rows, {len(drill_files)} files")
print(f"production now: {len(prod_r)} tables, {sum(int(v) for v in prod_r.values())} rows, {len(prod_f)} files")
bad = []
for t in sorted(set(drill_rows) | set(prod_r)):
    if drill_rows.get(t) != prod_r.get(t):
        bad.append(f"rows {t}: backup {drill_rows.get(t)}, production {prod_r.get(t)}")
for p in sorted(set(drill_files) | set(prod_f)):
    if drill_files.get(p) != prod_f.get(p):
        what = "missing in backup" if p not in drill_files else "not in production" if p not in prod_f else "different content"
        bad.append(f"file {p}: {what}")
if bad:
    print(f"MISMATCH ({len(bad)}): " + "\n  ".join(bad[:50]) + ("\n  ..." if len(bad) > 50 else ""))
    print("If production changed after the backup was taken, run again with --fresh.")
    sys.exit(1)
print("DRILL PASSED: every table's row count and every case file's SHA-256 match production")
EOF

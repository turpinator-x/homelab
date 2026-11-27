#!/usr/bin/env bash
# Usage: ./scripts/app-restore-drill.sh linkding|audiobookshelf|forgejo [--from-pi] [--keep]
# --from-pi restores from the copy on pisrv01 (and runs there, in namespace app-backup-mirror) instead of from R2.
# Restores the newest backup into a temporary pod, checks it against the backup's manifest,
# and starts a second copy of the app on the restored data. The live app and its volumes are not mounted or changed.
# The pod has its own label (no Service sends it traffic), accepts no connections and is deleted at the end unless
# --keep is given. restic runs with --no-lock, so the drill writes nothing to the repository. AI-assisted.
set -euo pipefail

app=${1:-}
[ $# -eq 0 ] || shift
keep='' from=r2
for option in "$@"; do
  case $option in
    --keep) keep=--keep ;;
    --from-pi) from=pi ;;
    *) echo "unknown option: $option" >&2; exit 2 ;;
  esac
done
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
case $app in
  linkding)
    uid=33 port=9090 data=/etc/linkding/data health=/health
    image=$(grep -m1 -oE 'sissbruecker/linkding:[0-9.]+' apps/base/linkding/deployment.yaml) ;;
  audiobookshelf)
    uid=1000 port=3005 data='' health=/healthcheck
    image=$(grep -m1 -oE 'ghcr.io/advplyr/audiobookshelf:[0-9.]+' apps/base/audiobookshelf/deployment.yaml) ;;
  forgejo)
    uid=1000 port=3000 data=/var/lib/gitea health=/api/healthz
    image=$(grep -m1 -oE 'codeberg.org/forgejo/forgejo:[^ ]+' apps/base/forgejo/deployment.yaml) ;;
  *) echo "usage: $0 linkding|audiobookshelf|forgejo [--from-pi] [--keep]" >&2; exit 2 ;;
esac
python=$(grep -m1 -oE 'sissbruecker/linkding:[0-9.]+' apps/staging/linkding/backup.yaml)
restic=$(grep -m1 -oE 'restic/restic:[0-9.]+@sha256:[0-9a-f]+' "apps/staging/$app/backup.yaml")

if [ "$from" = pi ]; then
  namespace=app-backup-mirror cronjob=app-backup-mirror pod=$app-restore-drill-pi
  node='nodeSelector: {kubernetes.io/hostname: pisrv01}'
  restore_env='[{name: TMPDIR, value: /tmp}, {name: RESTIC_REPOSITORY, value: /mirror/repo}, {name: RESTIC_PASSWORD, valueFrom: {secretKeyRef: {name: app-backup-mirror, key: RESTIC_PASSWORD}}}]'
  restore_secret='[]'
  extra_mount=', {name: mirror, mountPath: /mirror, readOnly: true}'
  extra_volume='- {name: mirror, persistentVolumeClaim: {claimName: app-backup-mirror, readOnly: true}}
    - {name: staging, emptyDir: {sizeLimit: 2Gi}}'
  # The copy's files belong to the user the mirror job runs as (1000) and only that user can read them. So restore as
  # that user into a staging volume, then copy as the app's user, which must own the files it will use.
  restore_user='runAsUser: 1000, '
  # restic makes the restore folder private to its own user: let the handover step (the app's user) read it. The
  # staging volume belongs to this pod alone.
  restore_run="command: [sh, -c, 'restic --no-cache --no-lock restore latest --host $app --target /restored/snapshot && chmod -R a+rX /restored/snapshot']"
  restore_volume=staging
  handover="- name: handover
      image: $python
      command: [cp, -r, /staging/snapshot, /restored/]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [\"ALL\"]}}
      volumeMounts: [{name: staging, mountPath: /staging, readOnly: true}, {name: restored, mountPath: /restored}]"
else
  namespace=$app cronjob=$app-backup pod=$app-restore-drill
  node=''
  restore_env='[{name: TMPDIR, value: /tmp}]'
  restore_secret="[{secretRef: {name: $app-backup}}]"
  extra_mount='' extra_volume=''
  restore_user='' restore_volume=restored handover=''
  restore_run="args: [--no-cache, --no-lock, restore, latest, --host, $app, --target, /restored/snapshot]"
fi
k() { kubectl --context homelab -n "$namespace" "$@"; }
# The scripts ConfigMap the live CronJob uses (its name carries a content hash).
scripts=$(k get cronjob "$cronjob" -o json |
  jq -r '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name=="code") | .configMap.name')
[ -z "$(k get pod "$pod" --ignore-not-found -o name)" ] || { echo "pod $pod already exists; delete it first" >&2; exit 1; }

if [ "$app" != audiobookshelf ]; then
  mounts="[{name: restored, mountPath: $data, subPath: snapshot}]"
  env='[]'
else
  mounts='[{name: restored, mountPath: /config, subPath: snapshot/config}, {name: restored, mountPath: /metadata, subPath: snapshot/metadata}]'
  env="[{name: PORT, value: \"$port\"}]"
fi

cleanup() {
  if [ "$keep" = --keep ]; then
    echo "Kept. Look with: kubectl --context homelab -n $namespace port-forward pod/$pod 8099:$port"
    echo "Delete with:     kubectl --context homelab -n $namespace delete pod $pod && kubectl --context homelab -n $namespace delete netpol $pod"
  else
    k delete pod "$pod" --ignore-not-found --wait=true
    k delete networkpolicy "$pod" --ignore-not-found
  fi
}
trap cleanup EXIT

secure='{allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}'
k create -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: $pod}
spec:
  podSelector: {matchLabels: {app: $pod}}
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
    - to:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
          podSelector: {matchLabels: {k8s-app: kube-dns}}
      ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]
    - to: [{ipBlock: {cidr: 0.0.0.0/0, except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16]}}]
      ports: [{port: 443, protocol: TCP}]
---
apiVersion: v1
kind: Pod
metadata: {name: $pod, labels: {app: $pod}}
spec:
  restartPolicy: Never
  $node
  activeDeadlineSeconds: 3600
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext: {runAsNonRoot: true, runAsUser: $uid, runAsGroup: $uid, fsGroup: $uid, seccompProfile: {type: RuntimeDefault}}
  initContainers:
    - name: restore
      image: $restic
      # The backup was made from inside the snapshot folder, so its files are at the top of the restore.
      $restore_run
      envFrom: $restore_secret
      env: $restore_env
      securityContext: {${restore_user}allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
      volumeMounts: [{name: $restore_volume, mountPath: /restored}, {name: tmp, mountPath: /tmp}$extra_mount]
    $handover
    - name: verify
      image: $python
      command: [python, /code/verify.py, /code/$app.json, /restored/snapshot]
      env: [{name: PYTHONDONTWRITEBYTECODE, value: "1"}]
      securityContext: $secure
      volumeMounts: [{name: restored, mountPath: /restored, readOnly: true}, {name: code, mountPath: /code, readOnly: true}]
  containers:
    - name: app
      image: $image
      env: $env
      readinessProbe: {httpGet: {path: $health, port: $port}, periodSeconds: 3, failureThreshold: 60}
      securityContext: $secure
      volumeMounts: $mounts
  volumes:
    - {name: restored, emptyDir: {sizeLimit: 2Gi}}
    - {name: tmp, emptyDir: {sizeLimit: 1Gi}}
    - {name: code, configMap: {name: $scripts}}
    $extra_volume
YAML

if ! k wait --for=condition=Ready "pod/$pod" --timeout=420s; then
  k get pod "$pod"
  for c in restore handover verify app; do echo "--- $c"; k logs "$pod" -c "$c" --tail=30 || true; done # best effort: show why
  echo "DRILL FAILED: $app" >&2
  exit 1
fi
k logs "$pod" -c restore --tail=3
k logs "$pod" -c verify
echo "DRILL PASSED ($from): $app started on the restored data and answers $health"

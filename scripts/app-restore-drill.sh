#!/usr/bin/env bash
# Usage: ./scripts/app-restore-drill.sh linkding|audiobookshelf [--keep]
# Restores the newest R2 backup into a temporary pod in the app's namespace, checks it against the backup's manifest,
# and starts a second copy of the app on the restored data. The live app and its volumes are not mounted or changed.
# The pod has its own label (no Service sends it traffic), accepts no connections and is deleted at the end unless
# --keep is given. restic runs with --no-lock, so the drill writes nothing to the repository. AI-assisted.
set -euo pipefail

app=${1:-}
keep=${2:-}
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
case $app in
  linkding)
    uid=33 port=9090 data=/etc/linkding/data health=/health
    image=$(grep -m1 -oE 'sissbruecker/linkding:[0-9.]+' apps/base/linkding/deployment.yaml) ;;
  audiobookshelf)
    uid=1000 port=3005 data='' health=/healthcheck
    image=$(grep -m1 -oE 'ghcr.io/advplyr/audiobookshelf:[0-9.]+' apps/base/audiobookshelf/deployment.yaml) ;;
  *) echo "usage: $0 linkding|audiobookshelf [--keep]" >&2; exit 2 ;;
esac
python=$(grep -m1 -oE 'sissbruecker/linkding:[0-9.]+' apps/staging/linkding/backup.yaml)
restic=$(grep -m1 -oE 'restic/restic:[0-9.]+@sha256:[0-9a-f]+' "apps/staging/$app/backup.yaml")

k() { kubectl --context homelab -n "$app" "$@"; }
pod=$app-restore-drill
# The scripts ConfigMap the live CronJob uses (its name carries a content hash).
scripts=$(k get cronjob "$app-backup" -o json |
  jq -r '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name=="code") | .configMap.name')
[ -z "$(k get pod "$pod" --ignore-not-found -o name)" ] || { echo "pod $pod already exists; delete it first" >&2; exit 1; }

if [ "$app" = linkding ]; then
  mounts="[{name: restored, mountPath: $data, subPath: snapshot}]"
  env='[]'
else
  mounts='[{name: restored, mountPath: /config, subPath: snapshot/config}, {name: restored, mountPath: /metadata, subPath: snapshot/metadata}]'
  env="[{name: PORT, value: \"$port\"}]"
fi

cleanup() {
  if [ "$keep" = --keep ]; then
    echo "Kept. Look with: kubectl --context homelab -n $app port-forward pod/$pod 8099:$port"
    echo "Delete with:     kubectl --context homelab -n $app delete pod $pod && kubectl --context homelab -n $app delete netpol $pod"
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
  activeDeadlineSeconds: 3600
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext: {runAsNonRoot: true, runAsUser: $uid, runAsGroup: $uid, fsGroup: $uid, seccompProfile: {type: RuntimeDefault}}
  initContainers:
    - name: restore
      image: $restic
      # The backup was made from inside the snapshot folder, so its files are at the top of the restore.
      args: [--no-cache, --no-lock, restore, latest, --host, $app, --target, /restored/snapshot]
      envFrom: [{secretRef: {name: $app-backup}}]
      env: [{name: TMPDIR, value: /tmp}]
      securityContext: $secure
      volumeMounts: [{name: restored, mountPath: /restored}, {name: tmp, mountPath: /tmp}]
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
YAML

if ! k wait --for=condition=Ready "pod/$pod" --timeout=300s; then
  k get pod "$pod"
  for c in restore verify app; do echo "--- $c"; k logs "$pod" -c "$c" --tail=30 || true; done # best effort: show why
  echo "DRILL FAILED: $app" >&2
  exit 1
fi
k logs "$pod" -c restore --tail=3
k logs "$pod" -c verify
echo "DRILL PASSED: $app started on the restored data and answers $health"

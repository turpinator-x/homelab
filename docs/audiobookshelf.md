# Capstone: Audiobookshelf

The capstone project of the KubeCraft Kubernetes Homelab course: deploy [Audiobookshelf](https://github.com/advplyr/audiobookshelf) (a self-hosted audiobook and podcast server) entirely through GitOps, in three stages. Audiobookshelf publishes only a `Dockerfile` and a `docker-compose.yml`, so the job was to translate those into Kubernetes manifests.

Public at `https://audiobooks.jarrodturpin.dev` (2026-10-21).

| Stage | Requirement | Commit |
|---|---|---|
| 1 | Port 3005 set through a ConfigMap, ClusterIP Service on 3005, reach it with a port-forward and upload an audio file | `d6aaf03` |
| 2 | Persistent volumes for every volume the docs suggest; library and settings survive a pod restart | `e09643f` |
| 3 | Run as the non-root `node` user; public through a Cloudflare Tunnel whose credentials are SOPS-encrypted and deployed by Flux | `9bf1b28` |

## Layout

```
apps/base/audiobookshelf/
├── kustomization.yaml   # also generates audiobookshelf-configmap (PORT=3005)
├── namespace.yaml
├── deployment.yaml
├── service.yaml         # ClusterIP 3005
└── storage.yaml         # 4 PVCs, protected from pruning
apps/staging/audiobookshelf/
├── kustomization.yaml   # namespace: audiobookshelf
├── cloudflare.yaml      # cloudflared Deployment + tunnel config
└── cloudflare-secret.yaml   # tunnel credentials, SOPS-encrypted
```

The existing `apps` Flux Kustomization picks the folder up automatically.

## Compose to Kubernetes

| In `docker-compose.yml` / `Dockerfile` | In Kubernetes |
|---|---|
| `image: ...:latest` | `ghcr.io/advplyr/audiobookshelf:2.37.1`, pinned so Renovate can track it |
| `ENV PORT=80` | `configMapGenerator` with `PORT=3005`, read with `envFrom` |
| `ports: - 13378:80` | `containerPort: 3005` and a ClusterIP Service; port-forward or the tunnel replaces the host port |
| `./audiobooks:/audiobooks`, `./podcasts`, `./metadata`, `./config` | one `volumeMount` and one PVC each |
| "config needs to be on the same physical machine" | `nodeSelector: srv1`, local-path storage on srv1's NVMe |
| `# user: 1000:1000` | pod `securityContext`: `runAsUser`, `runAsGroup`, `fsGroup` 1000, `runAsNonRoot` |
| `restart: unless-stopped` | built into a Deployment; a liveness probe also restarts a hung app |
| `/healthcheck` route in the server | readiness and liveness probes |

## Decisions beyond the exercise

- **Non-root from the first deploy.** k3s's local-path volumes are host directories, and `fsGroup` doesn't change ownership on them. If the app had run as root first (as the course solution does until stage 3), its database would be owned by root and the switch to UID 1000 would fail with permission errors. Stage 1 used `emptyDir` volumes with the same security context; stage 2 swapped them for PVCs.
- **Hardened container:** `allowPrivilegeEscalation: false`, all Linux capabilities dropped, `seccompProfile: RuntimeDefault`.
- **`strategy: Recreate`.** The database is SQLite in `/config`; a rolling update would briefly run two pods against it.
- **Four volumes, not three.** The official compose file lists podcasts too. Sizes (1/5/50/20 Gi) are labels; local-path doesn't enforce them.
- **PVCs carry `kustomize.toolkit.fluxcd.io/prune: disabled`,** so removing the app from Git can't delete the library. Deleting the data is a deliberate `kubectl delete pvc`.
- **One tunnel per app** (`audiobookshelf`), created with `cloudflared tunnel create` and `cloudflared tunnel route dns` (the CNAME is created from the CLI, not the dashboard). The cloudflared Deployment is a copy of Linkding's: pinned image, non-root, `/ready` liveness probe.
- **Admin account set over port-forward** in stage 2, before the app was public, so the root account couldn't be claimed by someone else. Audiobookshelf has no open sign-up.

## Verify

```bash
kubectl -n audiobookshelf get pods,pvc -o wide
kubectl -n audiobookshelf exec deploy/audiobookshelf -- sh -c 'id; ls -ln /config'   # uid=1000(node), files owned by 1000
kubectl -n audiobookshelf logs deploy/cloudflared | grep "Registered tunnel connection"
curl -sI https://audiobooks.jarrodturpin.dev/healthcheck | head -1                   # HTTP/2 200
```

Result: four PVCs bound on srv1, the uploaded audiobook still present after `kubectl rollout restart`, the app running as `uid=1000(node)` with every file owned by 1000, two cloudflared pods (one per node) with four tunnel connections each, and `HTTP/2 200` from the internet.

## What went wrong (and what caught it)

- **Tabs in pasted YAML** (`found a tab character that violates indentation`): `grep -nP '\t' file` finds them.
- **`volumes:` at column 0:** the YAML parsed, Kustomize built it, but the field sat on the Deployment instead of the pod. `kubectl kustomize` doesn't validate fields; `kubectl apply --dry-run=server -k` (or `kubectl diff -k`) sends the result to the API server, which does. Now part of the pre-push check.
- **A typo in a `resources:` filename** (`cloudfalre-secret.yaml`): caught by the local build before pushing.
- **Port-forward to a terminating pod** right after a restart: `port-forward svc/...` picks one pod when it starts; wait for the old pod to go.

# Self-hosted GitHub Actions runners

Status: **live** since 2026-11-10 (#28, with fixes in #29 and #30). The manifests are in `infrastructure/arc/` and `clusters/staging/arc.yaml`. `claims-app` and `blockone-devops-ai-journey` run CI on these runners (checked 2026-11-19); other private repos switch one at a time.

AI-assisted: designed and written with Claude Code; I set the requirements (no conflicts with the model platform or other projects, private repos only, no cost) and review and run each step.

## Why

My private repositories used 1,970 GitHub Actions minutes in the first 10 days of November 2026, against 2,000 a month on the Free plan (3,000 on Pro). Most of it is the curriculum's lesson tests, Crypto Lighthouse CI and the DevOps study app. Running those jobs on minisrv01 costs nothing per minute. Public repositories (this one, `lab`, the dashboard) keep GitHub's runners: their minutes are free, and a self-hosted runner on a public repo would let anyone's pull request run code on my server.

## How it works

[Actions Runner Controller](https://github.com/actions/actions-runner-controller) (ARC), GitHub's own Kubernetes operator, chart version 0.15.1, deployed by Flux.

```mermaid
flowchart LR
  GH[GitHub: a job asks for runs-on homelab-claims-app] -->|long poll| L[ARC listener in arc-systems]
  L --> C[ARC controller]
  C -->|creates| P[Ephemeral runner pod on minisrv01]
  P -->|runs the job, reports back| GH
  P -->|deleted when the job ends| X[Gone]
```

- **One scale set per repository.** A personal GitHub account can only register runners per repository (runner groups are for organizations), so each repo gets its own: `homelab-claims-app`, `homelab-blockone-devops-ai-journey`, `homelab-devops-study-app`.
- **Ephemeral:** zero runners when idle, one pod per job, deleted afterwards. Nothing carries over between jobs.
- **Two namespaces.** `arc-runners` (Pod Security baseline) for jobs that need no Docker. `arc-runners-dind` (privileged, needed for Docker-in-Docker) for the curriculum tests, which start privileged test containers, and the study app's image builds and k3d tests. Only my own private repos use it.
- **Capped so CI can't starve anything else.** Every container gets default limits from a LimitRange (3 CPU, 6 GiB), and a ResourceQuota caps each namespace (4 CPU / 8 GiB and 8 CPU / 14 GiB). One job per repo at a time. minisrv01 has 16 cores and 24 GB, and the model platform keeps its share.
- **Its own Flux Kustomization** (`arc`), so a runner problem can't hold up Renovate or the other infrastructure.
- **Pinned to minisrv01** (amd64). The curriculum builds amd64 containers, and the Pi is too small for CI.

## Credentials: a dedicated GitHub App

ARC authenticates with a GitHub App, not a personal token, scoped to only these three repos.

1. GitHub, Settings, Developer settings, GitHub Apps, **New GitHub App**.
2. Name `homelab-actions-runners`, homepage `https://github.com/turpinator-x/homelab`, untick **Webhook: Active**.
3. Repository permissions: **Administration: Read and write** (registers repository runners) and **Metadata: Read-only**. Nothing else.
4. **Only on this account**, then Create. Note the **App ID**.
5. **Generate a private key** (downloads a `.pem`).
6. **Install App**, Only select repositories: `claims-app`, `blockone-devops-ai-journey`, `devops-study-app`. The installation ID is the number at the end of the installation page's URL.
7. A SOPS-encrypted Secret `arc-github-app` (keys `github_app_id`, `github_app_installation_id`, `github_app_private_key`) goes into both runner namespaces in `infrastructure/arc/staging/`, and the `.pem` is deleted from Downloads.

## Switching a repo over

In the repo's workflow, change `runs-on: ubuntu-26.04` to `runs-on: homelab-<repo>` for the jobs to move. One repo at a time, watching the first run. The runner image (`ghcr.io/actions/actions-runner`) is much smaller than GitHub's hosted image, so a job that relies on a preinstalled tool needs a setup step (most already use `mise` or `setup-node`).

Order: the curriculum's `lesson-tests` first (the most minutes), then Crypto Lighthouse CI, then the study app. Each switch waits until that repo isn't being worked on, so it doesn't collide with other changes in flight.

## Checks after it's live

- `flux get kustomizations arc` Ready; `kubectl -n arc-systems get pods` shows the controller and three listeners.
- The repo's Settings, Actions, Runners page lists the scale set as online.
- A `workflow_dispatch` run on `homelab-<repo>` creates a pod in the runner namespace, passes, and the pod is gone afterwards.
- Failure path: with the Secret missing, the listener reports an authentication error and no job is picked up; jobs on `ubuntu-26.04` are unaffected.

## Docker-in-Docker and the network's packet size (MTU)

The first real job on a dind runner (2026-11-10) hung at `apt-get update`. The pod network carries packets of at most 1450 bytes (flannel's VXLAN takes 50 bytes for its own header), but Docker inside the pod gave its bridge the default 1500. Small requests worked, but large replies were dropped without an error, so downloads stalled.

The dind scale sets therefore write the pod template out in full instead of using `containerMode: dind`. Their dind sidecar is pinned and starts dockerd with the pod's own MTU. It also adds a TCP MSS clamp, so containers nested one level deeper (Docker inside a job's container, as the curriculum's Stage 3 does) don't hit the same drop. To check a running pod: `docker network inspect bridge` inside the dind container should show MTU 1450.

## Docker-in-Docker and file permissions (umask)

The same first test run also failed the curriculum's permissions lesson: new files came out as `-rw-rw-rw-`. Since Docker 29.6.0, commands started with `docker exec` inside Docker-in-Docker get a umask of 0000 instead of 0022. Plain `docker run` and Docker on a normal host are not affected. Tested 2026-11-10: 28.5.2, 29.4.0 and 29.5.2 give 0022; 29.6.0 to 29.9.2 give 0000. The dind sidecar is held at 29.5.2 (a Renovate rule keeps it below 29.6). To re-test a newer release: start `docker:<version>-dind` privileged, run a container inside it, and check that `docker exec <container> sh -c umask` prints 0022.

## blockone-crypto-tax (draft design, 2026-11-24)

The test shards of the private `blockone-crypto-tax` repo move to `homelab-blockone-crypto-tax`. PR code runs there and the app's production database is on the same node, so this scale set is stricter than the others (`infrastructure/arc/base/crypto-tax.yaml`):

- Own namespace `arc-runners-crypto-tax`, **no Docker, no privileged pod** (Pod Security baseline). The `migrations-postgres` job needs Docker (service container, `docker exec`), so it stays on GitHub's runners.
- Ephemeral, one job per pod, `maxRunners: 2`. The runner pod mounts no service account token.
- Default-deny NetworkPolicy. The CNI is k3s's default (flannel with kube-router policy, checked 2026-11-24): IP and port rules only, no host names. So runner pods may reach only DNS and an **egress proxy** (squid, `egress-proxy`, same namespace), and only the proxy reaches the internet. Its allowlist: `.github.com`, `.githubusercontent.com`, `.githubapp.com`, GitHub's results blob accounts (`productionresultssa*.blob.core.windows.net`), `pypi.org`, `files.pythonhosted.org`, `archive.ubuntu.com`, `security.ubuntu.com`, on ports 80/443. Runner pods set `http_proxy`/`https_proxy`; the workflow's apt step passes the proxy explicitly. Gaps: the proxy filters on the host name in CONNECT (no TLS inspection), so an allowed host such as github.com could still receive data the job writes there; DNS is open to kube-dns. The allowlist is a first guess: the first run will show denied hosts in the proxy log (`kubectl -n arc-runners-crypto-tax logs deploy/egress-proxy`), add them one at a time.
- PriorityClass `ci-runner` (-200, never preempts), runner request 1 CPU / 512 Mi and limit 3 CPU / 2.5 Gi, quota 6.5 CPU / 5.5 Gi limits, 4 pods. Squid image pinned by digest.
- Pinned to minisrv01 (amd64); the Pi is arm64 and the backup mirror.
- Secrets: the runner pod gets only the job's `GITHUB_TOKEN`. The `arc-github-app` Secret sits in the namespace for the listener, not in the pod.

Owner steps before merge: create a second GitHub App, `homelab-runner-crypto-tax`, installed on this repo only (Repository permissions Administration: Read and write, Metadata: Read-only; nothing else, no webhook), and add its SOPS Secret `arc-github-app` for this namespace as `infrastructure/arc/staging/arc-github-app-crypto-tax-secret.yaml`, listed in that kustomization, as a commit on this PR. The shared `homelab-actions-runners` App no longer covers this repo. Note: ARC's listener and its copy of the App key run in `arc-systems`, which has no NetworkPolicy (see gaps below). Tightening later (production releases) is config: a dedicated tainted node (`nodeSelector` plus `tolerations`), gVisor/Kata `runtimeClassName`, TLS-inspecting egress.

### Capacity, re-measured 2026-11-26 (kubectl, read-only)

minisrv01 after the graphics memory cut to 512M: 16 CPU, 30,863 Mi (30.1 Gi) allocatable, which equals capacity (no `system-reserved`/`kube-reserved`, so the OS and k3s are not set aside). Kernel pinned to 7.0.0-38 (7.0.0-44 broke container signals through AppArmor). Live: 0.9 CPU and 8.1 Gi in use (one dind job running); pod requests 2.2 CPU / 4.2 Gi; pod limits 7 CPU / 18.7 Gi, of which 4 CPU / 7 Gi is that dind runner. Outside the runner namespaces: requests 1.4 CPU / 2.7 Gi, limits 3 CPU / 11.7 Gi, plus 26 containers with no memory limit (monitoring, ARC controller and listeners, kube-system, linkding, audiobookshelf, renovate).

Worst case, every runner namespace at its ResourceQuota at the same moment (this PR: 2 runners at 3 CPU / 2.5 Gi plus the proxy at 0.5 CPU / 256 Mi, quota 6.5 CPU / 5.5 Gi):

| | CPU limits | Memory limits | Memory requests |
|---|---|---|---|
| Not CI (live) | 3 | 11.7 Gi | 2.7 Gi |
| `arc-runners` quota (4 CPU / 8 Gi) | 4 | 8 Gi | 1 Gi |
| `arc-runners-dind` quota (8 CPU / 14 Gi) | 8 | 14 Gi | 3 Gi |
| `arc-runners-crypto-tax` quota (this PR) | 6.5 | 5.5 Gi | 1.1 Gi |
| **Total vs allocatable** | **21.5 / 16 (134%)** | **39.2 / 30.1 Gi (130%)** | **7.8 Gi (26%)** |
| Without this PR | 15 / 16 (94%) | 33.7 Gi (112%) | 6.7 Gi (22%) |

CPU over 100% only throttles. Memory over 100% is the real risk, and it already exists without this PR (112%, mostly the dind quota). It needs all three scale sets busy and every job at its limit at once; one shard measured 517 MiB on one process, about 1.2 Gi with `-n 2`. Protection is ordering, not hardware: the runners have priority -200 (production 0, staging -100) and a low memory request (512 Mi), so the kubelet evicts them first under memory pressure. A kernel OOM that beats the kubelet (a fast spike) ranks by OOM score, where production's small requests (blockone-postgres-0: 128 Mi) score high too, so production is not guaranteed safe in that case. Recommended follow-ups, cluster changes for the owner, not in this PR: `system-reserved`/`kube-reserved` and a soft eviction threshold on minisrv01, and either lower the `arc-runners-dind` quota or raise the production Postgres memory request, so the sum of limits fits allocatable.

Wall time estimate (unverified until a run): 6 shards in 3 waves of 2, about 3 to 4 minutes each with setup, so 9 to 12 minutes against about 5 on GitHub's runners.

### Verified before deploy, and what only a deploy can show

Verified 2026-11-26 without touching the cluster: `scripts/validate.sh` passes; the scale-set chart (0.15.1) rendered with `helm template` using this HelmRelease's values passes kubeconform (runner pod: service account with no permissions, `automountServiceAccountToken: false`, no volumes, no privileged container); `squid -k parse` on the ConfigMap passes with the pinned image; that squid run locally with the same config tunnels github.com, api.github.com, pypi.org, files.pythonhosted.org, `productionresultssa0.blob.core.windows.net` and archive.ubuntu.com, and refuses example.com, `evil.github.com.attacker.net`, github.com:22 and 169.254.169.254 (403).

Only a deploy can show: that kube-router enforces the policies (runner pods reach DNS and the proxy and nothing else; the proxy cannot reach private ranges), that the listener authenticates with the new App, that GitHub's job hosts are all on the allowlist, and wall time. After merge (read-only, owner or agent):

```sh
flux get kustomizations arc                                        # Ready=True
kubectl -n arc-runners-crypto-tax get pods,netpol,quota            # egress-proxy Running; 3 policies; quota used
kubectl -n arc-systems get pods | grep crypto-tax                  # listener Running
kubectl -n arc-systems logs -l app.kubernetes.io/component=runner-scale-set-listener --tail=50 | grep -i -E 'error|crypto-tax'
# Policy checks from a throwaway pod with the runner's labels (deleted afterwards; expect: proxy OK, others time out)
kubectl -n arc-runners-crypto-tax run np-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 \
  --overrides='{"spec":{"automountServiceAccountToken":false}}' -- sh -c '
  curl -s -o /dev/null -w "proxy github %{http_code}\n" -x http://egress-proxy:3128 https://github.com;
  curl -s -m 5 -o /dev/null https://github.com && echo "FAIL direct internet" || echo "ok direct blocked";
  curl -sk -m 5 -o /dev/null https://kubernetes.default.svc && echo "FAIL Service network" || echo "ok Service network blocked";
  curl -s -m 5 -o /dev/null -x http://egress-proxy:3128 https://example.com && echo "FAIL allowlist" || echo "ok allowlist"'
kubectl -n arc-runners-crypto-tax logs deploy/egress-proxy | grep TCP_DENIED   # after the first job: hosts to add
```

Then in blockone-crypto-tax set the repo variable `CI_RUNNER=homelab` and run the test workflow by hand (`gh workflow run test.yaml --ref main`).

Failure and rollback: any job problem, delete the repo variable `CI_RUNNER` (shards go back to GitHub's runners at once, no merge). A cluster problem: revert this PR (`git revert -m 1 <merge sha>`, PR, merge); Flux prunes the namespace, proxy and scale set. In an emergency before the revert lands: `flux suspend kustomization arc` then `kubectl -n arc-runners-crypto-tax scale deploy/egress-proxy --replicas=0` and `kubectl -n arc-runners-crypto-tax patch autoscalingrunnerset homelab-blockone-crypto-tax --type merge -p '{"spec":{"maxRunners":0}}'`, and resume after the revert. A secret problem: revoke the App's private key in GitHub (App settings, Private keys, Delete), which stops the listener at once.

### Gaps in the existing scale sets (not changed here)

- `arc-runners` and `arc-runners-dind` have no NetworkPolicy: a job in them can reach the pod network, Services and the LAN. Dind pods are privileged. Recommend the same default-deny plus proxy pattern for `arc-runners` first (no Docker), then `arc-runners-dind` with the private-range exclusions; both only run my own private repos' code, so this is defense in depth.
- The GitHub App has Administration read/write on three repos (needed to register repository runners on a personal account; there is no narrower permission) and its key is in both runner namespaces. Runner pods don't mount it, but a leaked key could administer all three repos. Recommend one App per repo (this PR's design) so each key reaches one repo, and `automountServiceAccountToken: false` plus no Secret mounts in the other scale sets' templates.

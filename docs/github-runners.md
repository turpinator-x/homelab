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
- PriorityClass `ci-runner` (-200, never preempts), runner limit 3 CPU / 2.5 Gi, quota 6.5 CPU / 5.5 Gi limits, 4 pods.
- Pinned to minisrv01 (amd64); the Pi is arm64 and the backup mirror.
- Secrets: the runner pod gets only the job's `GITHUB_TOKEN`. The `arc-github-app` Secret sits in the namespace for the listener, not in the pod.

Owner steps before merge: create a second GitHub App for this repo only (see below) and add its SOPS Secret `arc-github-app` for this namespace. Tightening later (production releases) is config: a dedicated tainted node (`nodeSelector` plus `tolerations`), gVisor/Kata `runtimeClassName`, an egress proxy.

### Capacity, measured 2026-11-24 (kubectl, read-only)

minisrv01: 16 CPU, 25.3 Gi allocatable, no taints; using 0.9 CPU (5%) and 5.9 Gi (23%); requests 2.2 CPU / 4.3 Gi, limits already 18.2 Gi (one dind runner idle-ish at 0.4 Gi). pisrv01 (arm64, 8 GB) is not a candidate (arch mismatch, backup mirror). One shard measured locally on one process: 517 MiB peak, 183 CPU-seconds, 193 s wall; with `-n 2` expect about 1.2 Gi, hence the 2.5 Gi limit. Two runners plus the proxy: at most 6.5 CPU and 5.5 Gi of limits, about 2.5 Gi real. **Worst case** if every ARC namespace hit its limits at once: 8 + 14 + 5.5 = 27.5 Gi against 25.3 Gi allocatable. That needs three scale sets to use every byte they may; measured use is a fraction of that, and the runners (priority -200, Burstable) are first in the kubelet's eviction order, so production pods (blockone-postgres-0: request 128 Mi, usage far below) are not the ones that go. There is no spare node, so this relies on priority and quotas, not isolation of hardware. Wall time estimate (unverified, no cluster run yet): 6 shards in 3 waves of 2, about 3 to 4 minutes each with setup, so 9 to 12 minutes against about 5 on GitHub's runners; `actions/setup-python` pip caching uses GitHub's cache service and works on self-hosted runners, so the second run onward should skip most of the downloads.

### Gaps in the existing scale sets (not changed here)

- `arc-runners` and `arc-runners-dind` have no NetworkPolicy: a job in them can reach the pod network, Services and the LAN. Dind pods are privileged. Recommend the same default-deny plus proxy pattern for `arc-runners` first (no Docker), then `arc-runners-dind` with the private-range exclusions; both only run my own private repos' code, so this is defense in depth.
- The GitHub App has Administration read/write on three repos (needed to register repository runners on a personal account; there is no narrower permission) and its key is in both runner namespaces. Runner pods don't mount it, but a leaked key could administer all three repos. Recommend one App per repo (this PR's design) so each key reaches one repo, and `automountServiceAccountToken: false` plus no Secret mounts in the other scale sets' templates.

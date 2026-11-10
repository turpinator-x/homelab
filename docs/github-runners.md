# Self-hosted GitHub Actions runners

Status: **built, not yet live** (2026-11-10). The manifests are in `infrastructure/arc/` and `clusters/staging/arc.yaml`. They go live once the GitHub App credentials are added and the pull request is merged.

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

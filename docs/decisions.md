# Decisions

Short records of why things are the way they are. Newest first. Each entry: the decision, why, and what was rejected.

## 2026-10-22 — Renovate auto-merges small updates

Patch, digest and pin updates (plus GitHub Actions minors and the dashboard image) merge automatically after CI passes and a 3-day release age. Majors and other minors wait for a Monday review. **Why:** weekly PR review was mostly rubber-stamping patches. **Rejected:** an AI agent merging on its own verdict (ignores CI, open to prompt injection from PR text).

## 2026-10-22 — Target: 3 control planes + a disposable test cluster

Single control plane is fine for now; the rebuild goes to 3 control planes (never 2: etcd quorum), with risky changes (Talos, Cilium, Kubernetes minors) tried on a throwaway cluster first. **Why:** one node failure shouldn't take down the cluster, and upgrades need somewhere safe to fail. Open: Talos vs k3s, Pis vs minis for control planes.

## 2026-10-21 — Renovate under `infrastructure/controllers/`

Matches Flux's official example layout: apps the cluster runs vs tools that run the cluster. **Why:** clearer ordering (infrastructure reconciles before apps) and matches the course.

## 2026-10-21 — Renovate as a GitHub App, not a PAT

An init container mints a one-hour installation token on each run. **Why:** no long-lived token to leak or rotate every 90 days.

## 2026-10-21 — CI validation, not required

GitHub Actions runs kubeconform on every push and PR. It is not a required status check. **Why:** requiring it would block direct pushes to main. **Rejected for now:** self-hosted Forgejo.

## 2026-10-19 — Secrets in Git with SOPS + age

Only `data`/`stringData` are encrypted, so manifests stay readable in review. A pre-commit hook blocks unencrypted Secrets and runs gitleaks. **Why:** everything Flux needs lives in Git, and the repo is public.

## Cloudflare Tunnel for public apps

Outbound-only tunnels, one per app, two replicas each. **Why:** no router ports open and the home IP stays out of DNS.

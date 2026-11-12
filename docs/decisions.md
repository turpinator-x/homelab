# Decisions

Short records of why things are the way they are. Newest first. Each entry: the decision, why, and what was rejected.

## 2026-11-11 — BlockOne Crypto Tax backups: rclone crypt to R2, copied to the other node, checked nightly

PostgreSQL (`pg_dump -Fc`) and the case-files volume (tar) are backed up nightly by a CronJob, encrypted client-side with rclone's `crypt` remote and uploaded to a Cloudflare R2 bucket; a second CronJob on pisrv01 copies the ciphertext onto its own volume and decrypts and checks last night's dump and archive. 35 days in both places; alerts on a missed or failed run; restores run as a Job through Git. **Why:** the data lived on one disk; R2 is off site with no egress fees, client-side encryption means neither R2 nor the Pi ever holds readable client data, and a check that decrypts and reads the backup every night proves more than "the upload succeeded". rclone is one multi-arch binary configured by environment variables, so no config file holds keys. **Choices inside it:** `copy --immutable` to pisrv01, not `sync`, so an emptied or tampered bucket can't wipe or overwrite the second copy; separate read-and-write and read-only R2 tokens; retention by `rclone delete --min-age` rather than an R2 lifecycle rule, so backups don't age out while new ones fail. **Rejected for now:** CloudNativePG or pgBackRest with WAL archiving (point-in-time restore; worth it with real client data, more to run for two testers), Velero or volume snapshots (local-path has no snapshots), restic/kopia (deduplication isn't needed at this size; one more format to restore from). Full write-up: [blockone-crypto-tax.md](blockone-crypto-tax.md), "Backups and restore".

## 2026-11-11 — BlockOne Crypto Tax tester app: own PostgreSQL, own Kustomization, Cloudflare Access

The tester app gets a single-replica PostgreSQL StatefulSet in its namespace, migrations as an initContainer, its own Flux Kustomization and its own tunnel, with Cloudflare Access (two emails, one-time PIN) in front and the app checking Access's token again. **Why:** the cluster has no shared database or operator, and two testers don't justify one yet; an initContainer is idempotent and avoids re-creating an immutable Job on every image change; a separate Kustomization means missing Secrets or a bad manifest here can't stop the other apps reconciling. **Rejected for now:** CloudNativePG (revisit before real client data, for backups), a migration Job (immutable under Flux), adding it to `apps` (one failure blocks every app). NetworkPolicy limits egress by port and private range only; hostname allowlisting needs an egress proxy or Cilium. Full write-up: [blockone-crypto-tax.md](blockone-crypto-tax.md).

## 2026-11-08 — agentgateway in front of the model, not LiteLLM

The model platform's gateway (keys, token rate limits, failover, time-to-first-token metrics) will be agentgateway, run standalone from a SOPS-encrypted config. **Why:** one container with no database or Redis, foundation-run, Apache-2.0, amd64 + arm64. **Rejected:** LiteLLM (its PyPI packages were compromised in March 2026, and its PyPI packages and official images in October 2026), Envoy AI Gateway (a second ingress controller plus Redis on two nodes), Bifrost (company-owned, failover leans on the paid tier). Full record: [llm-gateway-decision.md](llm-gateway-decision.md).

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

## 2026-11-10: self-hosted runners with ARC, and a privileged namespace for Docker-in-Docker

- **Decision:** run my private repos' GitHub Actions jobs on the cluster with Actions Runner Controller (ephemeral pods, one scale set per repo), not a long-lived runner service on minisrv01.
- **Why:** private-repo minutes ran out (1,970 of 2,000 in ten days). Ephemeral pods start clean for every job, are deployed and capped through Git like everything else, and need no SSH access to the host.
- **Exception to the non-root rule:** `arc-runners-dind` allows privileged pods because Docker-in-Docker needs them (the curriculum tests start privileged test containers, the study app builds images and runs k3d). Limited to my own private repos, capped by a ResourceQuota, and kept apart from `arc-runners` (baseline), which serves jobs that need no Docker. Public repos never use self-hosted runners.
- **Revisit:** if a rootless builder (BuildKit rootless, Kaniko) can replace Docker-in-Docker for these jobs.

# Status

Working notes on what's running, what's next, and what's known to be broken. Updated after each change; the README holds the polished summary.

_Last updated: 2026-11-27_

## Running

| Component | Path | Notes |
|---|---|---|
| k3s v1.36.5 | minisrv01, pisrv01 | both nodes Ready |
| Flux v2.9 | `clusters/staging` | read-only SSH deploy key, 1 min interval, prune on |
| Linkding | `apps/*/linkding` | public via Cloudflare Tunnel; `linkding-tasks` sidecar runs background jobs |
| Audiobookshelf | `apps/*/audiobookshelf` | public, own tunnel, pinned to minisrv01 (local-path volumes) |
| Dashboard | `apps/*/dashboard` | image from `homelab-dashboard` repo (GHCR), NetworkPolicy, no SA token |
| Model platform | `apps/*/llm` | llama.cpp on CPU on both nodes behind an agentgateway gateway: API keys, per-key limits, failover, metrics including time to first token, alerts. Phases 1 and 2 of 4 |
| BlockOne Crypto Tax | `apps/*/blockone-crypto-tax` | tester app (API, worker, PostgreSQL) behind its own tunnel and Cloudflare Access; own `blockone-crypto-tax` Kustomization; deployed 2026-11-11 (PR #32). Backups on a branch (Next) |
| BlockOne staging | `apps/staging/blockone-crypto-tax-staging` | **deployed** (namespace `blockone-staging`, own Flux Kustomization; running, checked 2026-11-19): own namespace, Kustomization, PostgreSQL, tunnel and Access app, synthetic data only, priority below production (PriorityClass `blockone-staging`) |
| Homepage | `apps/*/homepage` | LAN only, Ingress-annotation discovery, read-only ClusterRole |
| Claim watch | `apps/*/claim-watch` | read-only CronJob every 15 min: Telegram reminders for DeFi claims and Flare restakes, no keys (`docs/claim-watch.md`); image from private `defi-claim-watch` repo |
| Renovate | `infrastructure/controllers/*/renovate` | hourly CronJob, 15 repos (the `args` in `cronjob.yaml`), GitHub App token minted per run |
| kube-prometheus-stack | `monitoring/controllers` | Grafana on `*.home.arpa` with self-signed TLS |
| Forgejo (trial) | `apps/*/forgejo` | self-hosted Git on the home network only, backed up nightly like the other apps; two-week trial being set up (`docs/forgejo.md`) |
| CI | `.github/workflows/validate.yaml` | kubeconform on push/PR; not a required check |
| Secret scan | `.github/workflows/secret-scan.yaml` | gitleaks over the full history; not a required check |
| Repo baseline | `.pre-commit-config.yaml` | since 2026-11-04: Commitizen, secret checks and shellcheck through pre-commit |
| Ruleset | `protect-main` | active on GitHub |

## Next

0. **Running (since 2026-11-27):** backups for Linkding, Audiobookshelf and Forgejo to R2 with a copy on pisrv01, Telegram alerts and a monthly restore check; each restored from each place and started as a separate copy ([backups.md](backups.md)). To check: the first scheduled runs. Not rehearsed: replacing live data.
0. **In progress (PR, label `production-change`):** BlockOne weekly read-only storage report (`blockone-storage-report`, Sundays 03:00): per-folder sizes with no private names, growth since last week, digest to Telegram through Alertmanager (critical with a `GROWTH:` prefix past 20 percent / 500 MiB / 250 MiB per folder), failure alerts. Built because the nightly case-files archive grew 76 to 430 MiB in four steps with the cause unknown. See `docs/blockone-crypto-tax.md`, "Weekly storage report". First live run is the check after merge.
0. **In progress (PR, label `production-change`):** BlockOne app monitoring: the API's `/metrics` scraped by Prometheus (ServiceMonitor, NetworkPolicy from `monitoring`, port 9464 internal only), 12 alert rules (`app-alerts.yaml`, promtool-tested) and a Telegram route for `BlockOne*` warning and critical alerts. Design: app repo `reports/40_error_capture_resilience`. After merge: check the target is up and the rules loaded (`docs/blockone-crypto-tax.md`, "App metrics and alerts").
0. **Running (checked 2026-11-27):** nightly encrypted backups for the BlockOne Crypto Tax app: the latest `blockone-backup` and `blockone-backup-mirror` runs completed, and the mirror's check of the newest set passed. See `docs/blockone-crypto-tax.md`, "Backups and restore" (restore drills and open gaps are listed there).
0. **Done 2026-11-10:** self-hosted GitHub Actions runners (ARC 0.15.1, `infrastructure/arc/`, own `arc` Kustomization), used by `claims-app` and `blockone-devops-ai-journey`. Other private repos switch one at a time. See `docs/github-runners.md`.
0. **Waiting on the owner (branch `feat/blockproof-hostnames`):** BlockProof hostnames `app.blockproof.tax`, `staging.blockproof.tax` and a private holding page on `blockproof.tax`, next to the old `jarrodturpin.dev` hostnames. Needs the `production-change` label, then DNS records and the new hostnames on the two existing Access applications (`docs/blockone-crypto-tax.md`, "blockproof.tax hostnames").
0. **Waiting on the owner:** BlockOne staging is deployed (owner steps done); next, the release flow in the app repo (`scripts/release/stage.sh`, `promote.sh`, `rollback.sh`). First restore drill on the homelab: `scripts/blockone-restore-drill.sh --fresh`. Backup gaps to decide: `docs/blockone-crypto-tax.md`, "Backup security review" (the Alertmanager receiver is done: Telegram, `docs/monitoring.md`). Create the `production-change` PR label (rollback PRs need it). Review the production restore Job change (whole-schema restore).
1. LAN DNS + trusted certs: cert-manager with Let's Encrypt DNS-01 via Cloudflare.
2. Stage 0 hardening: Pi SSD, system-upgrade-controller, External DNS, `docs/maintenance.md`.
3. Self-hosted model platform (`docs/llm.md`): phase 3, an SLO on time to first token with a streaming load test. Phase 2 (gateway) deployed 2026-11-08.
4. Later: test cluster (Talos) and 3-control-plane rebuild. See `decisions.md`.

## Known issues

- One Renovate Job from 2026-11-04 is still listed as Failed, with an error on `chain-explorer`. It stays in the Job history. The latest run on 2026-11-06 completed and reached all 14 repos with no errors.
- Linkding web container logs a supervisord "can't drop privilege" error once at start (expected; background tasks run in the sidecar).

## Don't repeat

- Staging next to production: add a new overlay and a new Flux Kustomization; never re-path or rename production's (`prune: true` would delete its PostgreSQL and volumes). `scripts/check-staging-isolation.sh` guards the staging build.

- `npx renovate-config-validator` without a version pulls a stale cached v37 that rejects `managerFilePatterns`. Pin `renovate@<cluster version>`.
- Moving a resource between Flux Kustomizations: `flux suspend` the old one first, or its prune deletes the resource.
- Deleting a PVC that a CronJob's finished pods mounted: it stays `Terminating` (`pvc-protection`) until those Jobs are deleted.
- Proton VPN's browser proxy breaks `*.home.arpa` hostnames; test LAN hosts with it off.
- A new pod's NetworkPolicy allow rules take a few seconds to apply (kube-router): until then connections are refused. Pods that connect at start-up (backup dumps, migrations) must wait and retry, not fail on the first attempt.

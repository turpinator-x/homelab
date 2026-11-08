# Status

Working notes on what's running, what's next, and what's known to be broken. Updated after each change; the README holds the polished summary.

_Last updated: 2026-11-07_

## Running

| Component | Path | Notes |
|---|---|---|
| k3s v1.36.5 | minisrv01, pisrv01 | both nodes Ready |
| Flux v2.9 | `clusters/staging` | read-only SSH deploy key, 1 min interval, prune on |
| Linkding | `apps/*/linkding` | public via Cloudflare Tunnel; `linkding-tasks` sidecar runs background jobs |
| Audiobookshelf | `apps/*/audiobookshelf` | public, own tunnel, pinned to minisrv01 (local-path volumes) |
| Dashboard | `apps/*/dashboard` | image from `homelab-dashboard` repo (GHCR), NetworkPolicy, no SA token |
| Model platform | `apps/*/llm` | llama.cpp on CPU on both nodes behind an agentgateway gateway: API keys, per-key limits, failover, metrics including time to first token, alerts. Phases 1 and 2 of 4 |
| Homepage | `apps/*/homepage` | LAN only, Ingress-annotation discovery, read-only ClusterRole |
| Renovate | `infrastructure/controllers/*/renovate` | hourly CronJob, 14 repos (the `args` in `cronjob.yaml`), GitHub App token minted per run |
| kube-prometheus-stack | `monitoring/controllers` | Grafana on `*.home.arpa` with self-signed TLS |
| CI | `.github/workflows/validate.yaml` | kubeconform on push/PR; not a required check |
| Secret scan | `.github/workflows/secret-scan.yaml` | gitleaks over the full history; not a required check |
| Repo baseline | `.pre-commit-config.yaml` | since 2026-11-04: Commitizen, secret checks and shellcheck through pre-commit |
| Ruleset | `protect-main` | active on GitHub |

## Next

1. LAN DNS + trusted certs: cert-manager with Let's Encrypt DNS-01 via Cloudflare.
2. Stage 0 hardening: Alertmanager receivers, Pi SSD, system-upgrade-controller, External DNS, `docs/maintenance.md`.
3. Self-hosted model platform (`docs/llm.md`): phase 3, an SLO on time to first token with a streaming load test. Phase 2 (gateway) deployed 2026-11-08.
4. Later: test cluster (Talos) and 3-control-plane rebuild. See `decisions.md`.

## Known issues

- One Renovate Job from 2026-11-04 is still listed as Failed, with an error on `chain-explorer`. It stays in the Job history. The latest run on 2026-11-06 completed and reached all 14 repos with no errors.
- Linkding web container logs a supervisord "can't drop privilege" error once at start (expected; background tasks run in the sidecar).

## Don't repeat

- `npx renovate-config-validator` without a version pulls a stale cached v37 that rejects `managerFilePatterns`. Pin `renovate@<cluster version>`.
- Moving a resource between Flux Kustomizations: `flux suspend` the old one first, or its prune deletes the resource.
- Proton VPN's browser proxy breaks `*.home.arpa` hostnames; test LAN hosts with it off.

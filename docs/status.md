# Status

Working notes on what's running, what's next, and what's known to be broken. Updated after each change; the README holds the polished summary.

_Last updated: 2026-10-26_

## Running

| Component | Path | Notes |
|---|---|---|
| Flux v2.9 | `clusters/staging` | read-only SSH deploy key, 1 min interval, prune on |
| Linkding | `apps/*/linkding` | public via Cloudflare Tunnel; `linkding-tasks` sidecar runs background jobs |
| Audiobookshelf | `apps/*/audiobookshelf` | public, own tunnel, pinned to minisrv01 (local-path volumes) |
| Dashboard | `apps/*/dashboard` | image from `homelab-dashboard` repo (GHCR), NetworkPolicy, no SA token |
| Homepage | `apps/*/homepage` | LAN only, Ingress-annotation discovery, read-only ClusterRole |
| Renovate | `infrastructure/controllers/*/renovate` | hourly CronJob, GitHub App token minted per run |
| kube-prometheus-stack | `monitoring/controllers` | Grafana on `*.home.arpa` with self-signed TLS |
| CI | `.github/workflows/validate.yaml` | kubeconform on push/PR; not a required check |

## Next

1. LAN DNS + trusted certs: cert-manager with Let's Encrypt DNS-01 via Cloudflare.
2. Stage 0 hardening: Alertmanager receivers, Pi SSD, system-upgrade-controller, External DNS, `docs/maintenance.md`.
3. PDF Q&A AI stack as a cluster platform service.
4. Later: test cluster (Talos) and 3-control-plane rebuild — see `decisions.md`.

## Known issues

- Linkding web container logs a supervisord "can't drop privilege" error once at start (expected; background tasks run in the sidecar).

## Don't repeat

- `npx renovate-config-validator` without a version pulls a stale cached v37 that rejects `managerFilePatterns`. Pin `renovate@<cluster version>`.
- Moving a resource between Flux Kustomizations: `flux suspend` the old one first, or its prune deletes the resource.
- Proton VPN's browser proxy breaks `*.home.arpa` hostnames; test LAN hosts with it off.

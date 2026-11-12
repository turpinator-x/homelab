# Homelab Platform

[![validate](https://github.com/turpinator-x/homelab/actions/workflows/validate.yaml/badge.svg)](https://github.com/turpinator-x/homelab/actions/workflows/validate.yaml)
[![secret-scan](https://github.com/turpinator-x/homelab/actions/workflows/secret-scan.yaml/badge.svg)](https://github.com/turpinator-x/homelab/actions/workflows/secret-scan.yaml)

A self-hosted, multi-node Kubernetes platform run entirely from Git: public apps, encrypted secrets, monitoring, automated updates and CI.

I'm Jarrod Turpin, a DevOps and Platform Engineer with 20+ years in enterprise IT at Microsoft, Amazon, and Boeing. This repo is the live configuration of the cluster, plus how it was built, what broke, and what's next.

**See it running:** [dashboard.jarrodturpin.dev](https://dashboard.jarrodturpin.dev) shows live numbers from this cluster.

## At a Glance

| Area | What's in place |
|---|---|
| Cluster | Two-node k3s (v1.36): a mini PC control plane and a Raspberry Pi 5 worker, mixed amd64 and arm64 |
| GitOps | FluxCD reconciles [`clusters/staging`](clusters/staging) every minute over a read-only deploy key; Kustomize base and overlays in [`apps/`](apps) |
| Public apps | [Linkding](https://github.com/sissbruecker/linkding), [Audiobookshelf](https://github.com/advplyr/audiobookshelf) and the AI-assisted dashboard, through Cloudflare Tunnels with no inbound ports open. A private tester app (FastAPI, worker, PostgreSQL) behind Cloudflare Access, in a namespace that enforces the restricted Pod Security level with default-deny NetworkPolicies, with nightly encrypted backups to Cloudflare R2 and the other node, checked every night and restore-drilled in a throwaway cluster ([write-up](docs/blockone-crypto-tax.md)); a separate staging deployment with synthetic data, its own namespace, tunnel and Access app, and a CI check that it can't touch production ([staging](docs/blockone-crypto-tax-staging.md)) |
| AI platform | A small language model served on CPU by llama.cpp on both nodes, behind an agentgateway gateway (AI-assisted, in progress): API keys, per-key request and token limits, failover between nodes, model file pinned by SHA-256, locked-down pods and NetworkPolicy, Prometheus metrics including time to first token, a Grafana dashboard and alerts. Gateway chosen over LiteLLM after its 2026 supply-chain compromises ([decision record](docs/llm-gateway-decision.md)). See [docs/llm.md](docs/llm.md) |
| LAN apps | [Homepage](https://gethomepage.dev) start page with Ingress auto-discovery and read-only RBAC; Traefik Ingress for LAN hostnames |
| Secrets | SOPS and age, decrypted by Flux; a pre-commit hook blocks commits with an unencrypted Secret or a leaked credential |
| Monitoring | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) as a Flux HelmRelease from an OCI registry |
| Updates | Self-hosted Renovate runs hourly on a GitHub App and covers 14 repos; low-risk updates merge on their own, usually after a 3-day wait, and majors wait for a Monday review |
| CI | GitHub Actions: kubeconform on every Flux path (strict schemas, SHA-pinned actions) and a full-history gitleaks scan. These report problems; they are not required checks |
| Workload security | App containers run as non-root; the public dashboard pod has no API token, a restricted-level security context and a NetworkPolicy; `main` is protected from force pushes and deletion |

```
NAME        STATUS   ROLES           VERSION        OS-IMAGE             KERNEL-VERSION             CONTAINER-RUNTIME
minisrv01   Ready    control-plane   v1.36.5+k3s1   Ubuntu 26.04.1 LTS   7.0.0-38-generic (amd64)   containerd://2.3.4-k3s1.36
pisrv01     Ready    <none>          v1.36.5+k3s1   Ubuntu 24.04.5 LTS   6.8.0-1065-raspi (arm64)   containerd://2.3.4-k3s1.36
```

**AI assistance:** Claude Code wrote the dashboard's application code and the helper scripts in this repo. I set the requirements, then reviewed and ran them.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md): the layout
- [docs/k3s-cluster.md](docs/k3s-cluster.md): how the cluster was built
- [docs/flux-bootstrap.md](docs/flux-bootstrap.md): how Flux was installed
- [docs/gitops-apps.md](docs/gitops-apps.md): how apps are deployed and kept up to date
- [docs/monitoring.md](docs/monitoring.md): monitoring
- [docs/audiobookshelf.md](docs/audiobookshelf.md): translating a Docker Compose app into Kubernetes manifests
- [docs/dashboard.md](docs/dashboard.md): the public dashboard
- [docs/llm.md](docs/llm.md): a self-hosted model platform, in progress (AI-assisted)
- [docs/homepage.md](docs/homepage.md): the LAN start page
- [docs/blockone-crypto-tax.md](docs/blockone-crypto-tax.md): a private tester app behind Cloudflare Access, with its own PostgreSQL and encrypted, verified backups (AI-assisted)
- [docs/blockone-crypto-tax-staging.md](docs/blockone-crypto-tax-staging.md): its staging deployment, isolated from production, where clients try features before release (AI-assisted)
- [docs/decisions.md](docs/decisions.md): design choices and their reasons
- [docs/status.md](docs/status.md): current work and known issues

## What's Next

- [ ] Trusted LAN certificates: cert-manager with Let's Encrypt (DNS-01 through Cloudflare)
- [ ] Alertmanager receivers and an automated node upgrade process
- [ ] A self-hosted model platform: a small model on CPU with a pinned, checked model file, metrics, a dashboard and alerts (phase 1) and a gateway with keys, limits and failover (phase 2) are running. Next: an SLO on time to first token, then a failure drill. See [docs/llm.md](docs/llm.md)
- [ ] A Talos test cluster, then a three-control-plane rebuild
- [ ] CKA certification

## Current Setup

| Device | Hostname | Hardware | OS | Role |
|--------|----------|----------|----|------|
| Mini PC | minisrv01 | KAMRUI AM21: AMD Ryzen 7 8745HS (8 cores), 24 GB RAM, 1 TB NVMe, wired | Ubuntu Server 26.04 LTS | k3s server (control plane) |
| Raspberry Pi 5 | pisrv01 | Raspberry Pi 5, 8 GB RAM, wired | Ubuntu Server 24.04 LTS | k3s agent (worker) |
| Main laptop | Stealth | MSI Stealth 17 Studio (i9-13900H, hybrid NVIDIA GPU, 2x 990 PRO) | Omarchy (Arch Linux) | Primary workstation, cluster management, local Kubernetes via Rancher Desktop |
| Travel laptop | odin | Lenovo ThinkPad T480 | Omarchy (Arch Linux) | Second workstation |

All four machines share a TESmart 4-port HDMI KVM switch and a Dell S2725QS monitor. A future expansion plan (a 10-inch mini rack of thin clients plus a NAS) is in the works.

## What's Built

### Kubernetes on Azure (AKS)
A production-style AKS platform built in the KubeCraft Kubernetes in the Cloud course (private repo, `azure-aks-terraform`, archived). Terraform provisions the infrastructure, with one reusable module that onboards a customer end to end across staging and production clusters. On top of that: Flux GitOps, Azure Key Vault secret sync, Traefik and cert-manager, CloudNativePG databases with backups and point-in-time restores to Azure Blob Storage, Entra ID cluster access, separate node pools with upgrade and maintenance windows, Pod Security Standards with network policies, and kube-prometheus-stack with Grafana alerts.

### CI/CD and GitOps Pipeline
A release pipeline built in the KubeCraft DevOps Masterclass (private repos `devops-study-app` and `devops-study-app-gitops`). The small study tracker app and its tests come from the course. Pull requests run Ruff, pytest with an 80% coverage floor, a Trivy image scan and an end-to-end test on a k3d cluster. release-please creates releases from Conventional Commits, images go to GHCR, and CI updates the GitOps repo. Flux deploys dev, and the prod tag goes through a pull request.

### Engineering Standards
All my active repositories follow one baseline, applied and checked by a small `repo-baseline` tool (AI-assisted): Conventional Commits enforced by Commitizen, a pre-commit secret check, `shellcheck` on every shell script, gitleaks over the full history in CI, and Renovate for dependency updates. Public repos add GitHub secret scanning, push protection, Dependabot alerts and a protected `main`.

### Kubernetes Homelab (k3s)
A two-node k3s cluster: the mini PC as the control plane and the Raspberry Pi 5 as a worker, so workloads run across both amd64 and arm64. Host firewalls (ufw) only open the ports the nodes need between each other, and the Kubernetes API is reachable from the LAN only. The workstation keeps separate `kubectl` contexts for the homelab and the local Rancher Desktop cluster. The cluster is managed with GitOps: FluxCD pulls this repo over a read-only SSH deploy key and reconciles the cluster to match it, so changes go in through Git commits rather than `kubectl apply`.

### Local AI: PDF Question Answering (RAG)
A local, CPU-only document Q&A service from the KubeCraft Python, Docker & AI course: Phi-3.5-mini served by LocalAI, a sentence-transformers embeddings API, Qdrant vector search, a FastAPI backend that streams answers, and a web UI with source citations. It runs entirely on my laptop with Docker Compose. The code is in a private repo because it builds on paid course material.

### Arch Linux from Scratch
Manual install from the KubeCraft Linux Advanced course: GPT partitioning, LVM on LUKS full-disk encryption, mkinitcpio hooks, systemd-boot, systemd-networkd/resolved with iwd, a default-deny ufw firewall scoped to the LAN, and a Hyprland desktop.

### Kubernetes Fundamentals
Local cluster on Rancher Desktop. Deployments with rolling updates, Namespaces, ClusterIP/NodePort/LoadBalancer Services, Ingress, PersistentVolumeClaims (Mealie), Helm releases (Homarr), and the kube-prometheus-stack with Grafana. The Deployment, Mealie, Helm and monitoring files are in the [lab repo](https://github.com/turpinator-x/lab).

### Networking (containerlab)
Six hands-on lessons: Docker networking first, then Nokia SR Linux routers in containerlab. Topics run from Linux network namespaces and Docker bridges to IP addressing, static routing, eBGP with export policies, and a spine-leaf BGP fabric with ECMP. Each lesson ends with break/fix exercises (missing routes, black holes, routing loops, wrong ASNs, a spine failure, a route leak). Write-ups are in the [lab repo](https://github.com/turpinator-x/lab/tree/main/networking).

### Dotfiles and Config Management (AI-assisted)
All four machines are configured from one private chezmoi repo, with templates that give the laptops a full desktop profile and the servers a lean server profile (shell, Git, vim, and SSH config). On the laptops, mise installs the CLI tools, and the editor is Neovim with LazyVim. A new laptop gets my shell, prompt, editor, and tools from a single `chezmoi init --apply`.

### Workstation Automation (AI-assisted)
A private deploy and backup repo (`15m-workstation`) built with Claude Code as a pair programmer. I set the requirements, review the changes, and run it across both laptops:
- Fresh-deploy script that rebuilds an Omarchy workstation from the repo
- System snapshots (firewall, sshd, fstab, VM definitions) committed to GitHub per host
- Backups to a LUKS-encrypted USB drive and end-to-end encrypted Proton Drive, with deletions mirrored safely to the cloud copy
- Restore script for new hardware

See [SCRIPTS_OVERVIEW.md](SCRIPTS_OVERVIEW.md) for details.

### Hardening and Tuning (AI-assisted)
- UEFI Secure Boot with custom keys (sbctl) and automatic kernel signing
- SSH key-only auth and an sshd hardening drop-in on every machine; the servers' ufw only accepts SSH from the two laptops, which have DHCP reservations
- linux-lts fallback kernel, TCP BBR congestion control
- fstrim and pacman cache cleanup systemd timers, firmware updates through fwupd

## Troubleshooting Log

Problems I hit and how they were solved. Several were diagnosed with Claude Code as a pair; I ran and verified each fix.

- **Embedding model never loaded (503 forever):** a FastAPI embeddings container kept failing its health check. The real error was buried in the logs: `Operation not permitted` reading the Hugging Face cache. Rancher Desktop shares folders into its VM over reverse-sshfs, which can't follow symlinks that point up a directory, and the Hugging Face cache is built from them. Moving the cache to a named Docker volume fixed it.
- **Browser refused the web UI (`ERR_UNSAFE_PORT`):** the front end had been moved to host port 10080 to avoid a clash, but browsers block that port. Moved it to 18090 and updated the API's CORS origins to match.
- **Broken WiFi blacklist on the server:** every `apt upgrade` printed `libkmod` errors. A config line had been pasted as the text of the command instead of the setting, so the WiFi driver was never blocked. Fixed the file and removed WiFi from netplan, so the k3s node runs on its wired link only.
- **Worker node lost for three hours:** the Pi went `NotReady` because its WiFi stopped passing traffic without ever reporting a disconnect. Kubernetes moved its pods to the mini PC and the public apps stayed up. A power cycle brought it back, and the lasting fix was moving the Pi to Ethernet with WiFi switched off.
- **Boot loop on the T480:** pulled logs from a live USB instead of guessing, and traced it to a faulty TPM. Disabling the TPM in BIOS fixed it.
- **Backup sync deleted data:** the first sync run from the second laptop pushed a deletion of backed-up files, because the script assumed single-machine state. Fixed by skipping that step when the local source is missing.
- **NVIDIA GPU hang after resume:** traced a black screen after suspend to a dGPU flip timeout in the kernel journal.

## Certification Goals

Kubernetes, hardest first, toward Kubestronaut:
- [ ] CKA (Certified Kubernetes Administrator)
- [ ] CKS (Certified Kubernetes Security Specialist)
- [ ] CKAD (Certified Kubernetes Application Developer)
- [ ] KCNA and KCSA

Platform engineering and other:
- [ ] Prometheus Certified Associate (PCA)
- [ ] CNPA / CNPE (Cloud Native Platform Engineering)
- [ ] LPIC-1 / CompTIA Linux+
- [ ] Azure Administrator (AZ-104)

## Related Repos

- [homelab-dashboard](https://github.com/turpinator-x/homelab-dashboard) (AI-assisted): source, tests, Dockerfile and CI for the public dashboard
- [lab](https://github.com/turpinator-x/lab): course exercises (Bash, Docker, Kubernetes YAML, containerlab networking write-ups, a Cilium sandbox)
- `azure-aks-terraform` (private, archived): Terraform and GitOps for the AKS platform
- `devops-study-app` and `devops-study-app-gitops` (private): the DevOps Masterclass pipeline and its GitOps repo
- `dotfiles` (private): chezmoi-managed configuration for all four machines
- `python-docker-ai` (private, archived): the local AI PDF Q&A stack
- `15m-workstation` (private): deploy and backup automation
- `claims-app` (private, AI-assisted): [Crypto Lighthouse](https://cryptolighthouse.io), a live non-custodial crypto site built with Claude Code
- Obsidian knowledge base (private): 380+ technical notes

## Connect

- **LinkedIn:** [linkedin.com/in/jarrod-turpin](https://linkedin.com/in/jarrod-turpin)
- **GitHub:** [github.com/turpinator-x](https://github.com/turpinator-x)

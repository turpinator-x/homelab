# Homelab Build Log

A self-hosted, multi-node Kubernetes platform run with GitOps, built while moving from enterprise IT into Platform and Cloud Engineering.

I'm Jarrod Turpin, with 20+ years in enterprise IT at Microsoft, Amazon, and Boeing. This repo documents the homelab I'm building: the cluster, how it's deployed, what broke along the way, and what's next. Hands-on coursework (Bash, Docker, Kubernetes manifests, container networking labs) lives in my [lab repo](https://github.com/turpinator-x/lab).

## Current Status

**A two-node k3s cluster is running** on a mini PC and a Raspberry Pi 5, **managed with GitOps by FluxCD** from this repository. Flux watches [`clusters/staging`](clusters/staging) and applies whatever is committed there. Next up: deploying apps and infrastructure through Flux.

```
NAME          STATUS   ROLES           VERSION        OS-IMAGE             KERNEL-VERSION             CONTAINER-RUNTIME
srv1          Ready    control-plane   v1.36.5+k3s1   Ubuntu 26.04.1 LTS   7.0.0-38-generic (amd64)   containerd://2.3.4-k3s1.36
ubuntusrvpi   Ready    <none>          v1.36.5+k3s1   Ubuntu 24.04.5 LTS   6.8.0-1065-raspi (arm64)   containerd://2.3.4-k3s1.36
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the layout, [docs/k3s-cluster.md](docs/k3s-cluster.md) for how the cluster was built, and [docs/flux-bootstrap.md](docs/flux-bootstrap.md) for how Flux was installed.

## Roadmap

- [x] Arch Linux built from scratch (LUKS + LVM, systemd, ufw)
- [x] Kubernetes Fundamentals (Deployments, Services, Ingress, PVCs, Helm, Prometheus/Grafana)
- [x] Networking fundamentals, container networking, and BGP (containerlab)
- [x] Dev Containers, Neovim (LazyVim), and config management with chezmoi and mise
- [x] Local LLM services on Docker with Python: a RAG-based PDF question-answering app (LocalAI, embeddings, Qdrant, FastAPI, web UI)
- [x] Multi-node k3s cluster (mixed amd64 and arm64)
- [x] GitOps with FluxCD: Flux bootstrapped and managing itself from this repo
- [ ] Apps and infrastructure deployed through Flux (Kustomize, HelmReleases)
- [ ] Storage, secrets management, monitoring, and Traefik ingress on the cluster
- [ ] Apps exposed securely through Cloudflare Tunnel on `jarrodturpin.dev`
- [ ] Automated image updates and a capstone project
- [ ] Run the PDF Q&A AI stack on the cluster as a platform service (Helm chart, metrics, model comparison)
- [ ] CKA certification

## Current Setup

| Device | Hostname | Hardware | OS | Role |
|--------|----------|----------|----|------|
| Mini PC | srv1 | KAMRUI AM21: AMD Ryzen 7 8745HS (8 cores), 24 GB RAM, 1 TB NVMe, wired | Ubuntu Server 26.04 LTS | k3s server (control plane) |
| Raspberry Pi 5 | ubuntusrvpi | Raspberry Pi 5, 8 GB RAM | Ubuntu Server 24.04 LTS | k3s agent (worker) |
| Main laptop | Stealth | MSI Stealth 17 Studio (i9-13900H, hybrid NVIDIA GPU, 2x 990 PRO) | Omarchy (Arch Linux) | Primary workstation, cluster management, local Kubernetes via Rancher Desktop |
| Travel laptop | odin | Lenovo ThinkPad T480 | Omarchy (Arch Linux) | Second workstation |

All four machines share a TESmart 4-port HDMI KVM switch and a Dell S2725QS monitor. A future expansion plan (a 10-inch mini rack of thin clients plus a NAS) is in the works.

## What's Built

### Kubernetes Homelab (k3s)
A two-node k3s cluster: the mini PC as the control plane and the Raspberry Pi 5 as a worker, so workloads run across both amd64 and arm64. Host firewalls (ufw) only open the ports the nodes need between each other, and the Kubernetes API is reachable from the LAN only. The workstation keeps separate `kubectl` contexts for the homelab and the local Rancher Desktop cluster. Following the KubeCraft Kubernetes Homelab course, the cluster is managed with GitOps: FluxCD pulls this repo over a read-only SSH deploy key and reconciles the cluster to match it, so changes go in through Git commits rather than `kubectl apply`.

### Local AI: PDF Question Answering (RAG)
A local, CPU-only document Q&A service from the KubeCraft Python, Docker & AI course: Phi-3.5-mini served by LocalAI, a sentence-transformers embeddings API, Qdrant vector search, a FastAPI backend that streams answers, and a web UI with source citations. It runs entirely on my laptop with Docker Compose. The code is in a private repo because it builds on paid course material.

### Arch Linux from Scratch
Manual install from the KubeCraft Linux Advanced course: GPT partitioning, LVM on LUKS full-disk encryption, mkinitcpio hooks, systemd-boot, systemd-networkd/resolved with iwd, a default-deny ufw firewall scoped to the LAN, and a Hyprland desktop.

### Kubernetes Fundamentals
Local cluster on Rancher Desktop. Deployments with rolling updates, Namespaces, ClusterIP/NodePort/LoadBalancer Services, Ingress, PersistentVolumeClaims (Mealie), Helm releases (Homarr), and the kube-prometheus-stack with Grafana. Manifests are in the [lab repo](https://github.com/turpinator-x/lab).

### Networking (containerlab)
Six hands-on lessons on Nokia SR Linux in containerlab: Linux network namespaces and Docker bridges, IP addressing, static routing, eBGP with export policies, and a spine-leaf BGP fabric with ECMP. Each lesson ends with break/fix exercises (missing routes, black holes, routing loops, wrong ASNs, a spine failure, a route leak). Write-ups are in the [lab repo](https://github.com/turpinator-x/lab/tree/main/networking).

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

- [lab](https://github.com/turpinator-x/lab): course exercises (Bash, Docker, Kubernetes YAML, containerlab networking write-ups)
- `dotfiles` (private): chezmoi-managed configuration for all four machines
- `python-docker-ai` (private): the local AI PDF Q&A stack
- `15m-workstation` (private): deploy and backup automation
- Obsidian knowledge base (private): 240+ technical notes from the KubeCraft courses

## Connect

- **LinkedIn:** [linkedin.com/in/jarrod-turpin](https://linkedin.com/in/jarrod-turpin)
- **GitHub:** [github.com/turpinator-x](https://github.com/turpinator-x)

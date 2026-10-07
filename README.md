# Homelab Build Log

Turning DevOps coursework into a self-hosted Kubernetes platform, with local AI workloads next.

I'm Jarrod Turpin, moving into Platform and Cloud Engineering after 20+ years in enterprise IT at Microsoft, Amazon, and Boeing. This repo tracks what I've built at home, what broke along the way, and what's next. Hands-on coursework (Bash, Docker, Kubernetes manifests) lives in my [lab repo](https://github.com/turpinator-x/lab).

## Roadmap

- [x] Arch Linux built from scratch (LUKS + LVM, systemd, ufw)
- [x] Kubernetes Fundamentals (Helm, PersistentVolumeClaims, Prometheus/Grafana)
- [x] Networking fundamentals, container networking, and BGP (containerlab, all six lessons released so far)
- [ ] Dev Containers, Neovim, and config management (in progress: Dev Containers, DevPod, and Chezmoi done; Mise next)
- [ ] Local LLM services on Docker with Python
- [ ] Multi-node Kubernetes homelab on srv1 and srv2
- [ ] CKA certification

## Current Setup

| Device | Hostname | Hardware | OS | Role |
|--------|----------|----------|----|------|
| Main laptop | Stealth | MSI Stealth 17 Studio (i9-13900H, hybrid NVIDIA GPU, 2x 990 PRO) | Omarchy (Arch Linux) | Primary workstation, local Kubernetes via Rancher Desktop, KVM/libvirt VMs |
| Travel laptop | odin | Lenovo ThinkPad T480 | Omarchy (Arch Linux) | Second workstation, SSH remote access |
| Mini PC | srv1 | KAMRUI AM21 | Ubuntu Server 26.04 | Planned Kubernetes node |
| Raspberry Pi 5 | ubuntusrvpi | Raspberry Pi 5 (8 GB) | Ubuntu Server 24.04 | Planned edge and monitoring node |

All four machines share a TESmart 4-port HDMI KVM switch and a Dell S2725QS monitor.

## What's Built

### Arch Linux from Scratch
Manual install from the KubeCraft Linux Advanced course: GPT partitioning, LVM on LUKS full-disk encryption, mkinitcpio hooks, systemd-boot, systemd-networkd/resolved with iwd, a default-deny ufw firewall scoped to the LAN, and a Hyprland desktop.

### Kubernetes Fundamentals
Local cluster on Rancher Desktop. Deployments with rolling updates, Namespaces, ClusterIP/NodePort/LoadBalancer Services, Ingress, PersistentVolumeClaims (Mealie), Helm releases (Homarr), and the kube-prometheus-stack with Grafana. Manifests are in the [lab repo](https://github.com/turpinator-x/lab).

### Networking (containerlab)
Six hands-on lessons on Nokia SR Linux in containerlab: Linux network namespaces and Docker bridges, IP addressing, static routing, eBGP with export policies, and a spine-leaf BGP fabric with ECMP. Each lesson ends with break/fix exercises (missing routes, black holes, routing loops, wrong ASNs, a spine failure, a route leak). Write-ups are in the [lab repo](https://github.com/turpinator-x/lab/tree/main/networking).

### Workstation Automation (AI-assisted)
Built with Claude Code as a pair programmer. I set the requirements, review the changes, and run it across all four machines:
- Dotfiles managed with chezmoi in a private repo: one source for both laptops and both servers, with templates for per-machine differences (monitor layout, SSH aliases, desktop vs. server shell profile)
- Fresh-deploy script (`15m-workstation`) that rebuilds an Omarchy workstation and applies the dotfiles
- Config and system snapshots to GitHub, plus rsync backups to a LUKS-encrypted USB drive and end-to-end encrypted Proton Drive
- Restore script for new hardware

See [SCRIPTS_OVERVIEW.md](SCRIPTS_OVERVIEW.md) for details.

### Hardening and Tuning (AI-assisted)
- UEFI Secure Boot with custom keys (sbctl) and automatic kernel signing
- SSH key-only auth and an sshd hardening drop-in; the servers' ufw only accepts SSH from the two laptops, which have DHCP reservations
- linux-lts fallback kernel, TCP BBR congestion control
- fstrim and pacman cache cleanup systemd timers, firmware updates through fwupd

## Troubleshooting Log

- **Boot loop on the T480:** pulled logs from a live USB instead of guessing, and traced it to a faulty TPM. Disabling the TPM in BIOS fixed it.
- **Backup sync deleted data:** the first sync run from the second laptop pushed a deletion of backed-up files, because the script assumed single-machine state. Fixed by skipping that step when the local source is missing.
- **NVIDIA GPU hang after resume:** traced a black screen after suspend to a dGPU flip timeout in the kernel journal.

## Certification Goals

- [ ] CKA (Certified Kubernetes Administrator)
- [ ] CKAD (Certified Kubernetes Application Developer)
- [ ] CKS (Certified Kubernetes Security Specialist)
- [ ] LPIC-1 / CompTIA Linux+
- [ ] Azure Administrator (AZ-104)

## Related Repos

- [lab](https://github.com/turpinator-x/lab): course exercises (Bash, Docker, Kubernetes YAML)
- `dotfiles` (private): chezmoi-managed config for all four machines
- `15m-workstation` (private): deploy, backup, and sync automation
- Obsidian knowledge base (private): 240+ technical notes from the KubeCraft courses

## Connect

- **LinkedIn:** [linkedin.com/in/jarrod-turpin](https://linkedin.com/in/jarrod-turpin)
- **GitHub:** [github.com/turpinator-x](https://github.com/turpinator-x)

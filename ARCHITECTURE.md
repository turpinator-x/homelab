# Homelab Architecture Overview

## Infrastructure Layout

- **Stealth (primary laptop):** daily workstation on Omarchy (Arch Linux). Runs local Kubernetes through Rancher Desktop and KVM/libvirt VMs.
- **odin (ThinkPad T480):** second Omarchy workstation, reached over SSH with key-only auth.
- **srv1 (KAMRUI AM21 mini PC):** planned Kubernetes node.
- **ubuntusrvpi (Raspberry Pi 5):** planned edge and monitoring node.

## Sync Strategy

- Dotfiles: chezmoi, one private repo applied to every machine (desktop profile on the laptops, server profile on srv1 and the Pi)
- System snapshots (fstab, firewall, sshd, VM definitions): GitHub, per host
- Course work: public `lab` repo on GitHub
- Obsidian vault: private Git repo, plus backups to Proton Drive
- Personal files: rsync to a LUKS-encrypted USB drive and Proton Drive

## Tools Used

- Arch Linux (Omarchy), systemd, ufw
- Bash, Git, and chezmoi
- Docker, Kubernetes, Helm, Prometheus, Grafana
- Claude Code for AI-assisted scripting

## Privacy & Security

- Full-disk encryption (LUKS) and UEFI Secure Boot on the laptops
- SSH key-only authentication with a hardened sshd config
- Secrets and API keys are never stored in public repos

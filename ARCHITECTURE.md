# Homelab Architecture Overview

## Infrastructure Layout

- **Laptop (Primary)**: Development, Obsidian vault sync, Git operations
- **MiniPC (Compute Node)**: Git server, Docker containers, CI/CD runners
- **Raspberry Pi 5 (Edge)**: Monitoring, lightweight workloads, persistent services

## Sync Strategy

- Dotfiles → GitHub → Auto-deploy on new hardware
- Obsidian vault → GitHub sync (encrypted)
- System backups → External + remote storage

## Tools Used

- Bash scripting for automation
- Git for version control
- Docker for containerization (learning)
- Linux (Ubuntu/Debian family)

## Privacy & Security

- Production-sensitive configs remain in private repositories
- API keys & secrets never stored in public repos
- SSH keys encrypted with GPG where necessary

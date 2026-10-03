# Scripts & Automation Overview

These workflows live in private repositories. They were built with Claude Code as a pair programmer: I define what each script needs to do, review the changes, and run and maintain them on my machines.

## Workstation Deploy and Backup (`15m-workstation`)

The goal is a working workstation on new hardware in about 15 minutes.

- **Fresh deploy:** installs packages and links dotfiles to rebuild an Omarchy (Arch Linux) workstation
- **syncgit:** gathers configs (Hyprland, Omarchy, ufw rules, sshd hardening) and pushes them to GitHub
- **master_backup_and_harvest:** rsync of documents, pictures, and lab work to a LUKS-encrypted USB drive and to end-to-end encrypted Proton Drive
- **restore_from_backup:** restores from those backups onto a fresh install
- **push_to_odin:** LAN rsync from the main laptop to the second laptop over SSH

## Notes Vault Backup

- Obsidian vault versioned in Git and synced across machines
- inotify-based watcher triggers a debounced backup to Proton Drive whenever notes change

## Conventions

- Scripts are kept without `.sh` extensions and called by name from `PATH`
- Shared helpers live in a common library (for example, finding the backup drive mount)
- Secrets and API keys are never committed

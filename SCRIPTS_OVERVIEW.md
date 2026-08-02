# Scripts & Automation Overview

This document describes the automation workflows implemented in private repositories.

## Backup Scripts (`15m-workstation`)

- Full system snapshot every 15 minutes
- Incremental backups to reduce bandwidth/storage
- Recovery time objective: < 15 minutes

## Mining Configuration (`rpi-miner`, `kamrui-am21-miner`)

- Multi-hardware mining across heterogeneous devices
- CPU frequency tuning and memory paging optimization
- Thermal monitoring and throttling protection
- Shut down when electricity cost exceeds revenue

## Obsidian Vault Sync (`turps-brain-dump`)

- Version-controlled knowledge base
- Encrypted sync across multiple devices
- Conflict resolution via Git merge strategy

---

**Note:** Source code for these scripts is kept private for security reasons.

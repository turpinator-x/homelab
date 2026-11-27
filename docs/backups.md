# App backups: Linkding and Audiobookshelf

AI-assisted (planned and written with Claude Code). **Status:** the Linkding nightly job is defined in `apps/staging/linkding/backup.yaml`. **Linkding is backed up to R2** (first real run 2026-11-27). Nothing has been restored from R2 yet, there is no second copy on pisrv01 and no backup alert. Audiobookshelf is not covered yet.

The BlockOne Crypto Tax app has its own backups ([blockone-crypto-tax.md](blockone-crypto-tax.md), "Backups and restore"); this plan doesn't change them.

## Goal

Get Linkding and Audiobookshelf back after losing all the equipment at home, losing at most one day of changes while the nightly jobs work.

```mermaid
flowchart LR
  A[Linkding and Audiobookshelf<br>minisrv01] -->|nightly: safe snapshot,<br>restic, encrypted| R2[(Cloudflare R2<br>off site)]
  R2 -->|pisrv01 pulls<br>with a read-only key| PI[(second encrypted copy<br>pisrv01)]
```

## Decisions

| Area | Decision |
|---|---|
| Tool | restic 0.20.0, image pinned by digest (amd64 and arm64) |
| History | Nightly, 35 days in each place, each cleaned up on its own. The window counts back from the newest backup, so old ones stay if new ones stop |
| Access | Its own R2 bucket, with one read-and-write key and one read-only key |
| Downtime | None: SQLite databases are copied with SQLite's online backup API |
| Alerts | Telegram through Alertmanager: a failed job, or no success in 26 hours |
| Secrets | SOPS-encrypted in Git; the restic password and the SOPS age key are also kept in a password manager |
| Deletion protection | The copy on pisrv01. No R2 bucket lock yet, so someone with the write key could delete the R2 copy |

**Not covered:** audio and podcast files (the library was empty on 2026-11-27: revisit before adding any), the k3s datastore, monitoring history, staging data, model files and claim-watch state. Rebuilding the cluster from Git is a separate test; restoring these apps doesn't prove it.

## Build order

- [x] 1. Record the plan
- [x] 2. Linkding backup and restore with test storage and sample data
- [x] 3. Create the R2 bucket, keys and password; start real Linkding backups
- [ ] 4. Add Audiobookshelf
- [ ] 5. Copy to pisrv01
- [ ] 6. Alerts, triggered with safe test failures
- [ ] 7. Restore drill from R2 and from pisrv01
- [ ] 8. Monthly restore check, restore instructions, update the other docs

## Done means

- Both apps start from restored copies, kept apart from the live apps.
- Restores work from R2 and from pisrv01.
- Bookmarks and users match what the backup saved.
- A deliberately failed or damaged backup is reported as a failure.
- The test alerts arrive.
- The restore instructions say where to get the keys and the password.
- What was and wasn't tested is written down.

## How the scripts work

| File (`apps/base/app-backup/`) | What it does |
|---|---|
| `linkding.json` | What to save (database, folders, secret key), what must exist, and which row counts to record |
| `snapshot.py` | Copies the database safely, checks its integrity, copies the files and writes `manifest.json` (checksums and counts). Refuses a database with no users, so a freshly emptied app isn't saved as a good backup |
| `backup.sh` | `restic backup`, then `forget --keep-within 35d --prune`, then `check --read-data`. Never creates the repository itself |
| `verify.py` | Checks restored data against the manifest |

Linkding's task queue (`tasks.sqlite3`) is left out. Files are copied after the database, one at a time, so a file the app deletes during the snapshot can be missing from it, or can make the snapshot fail.

`check --read-data` downloads the whole repository every night. That suits a few megabytes; revisit it if the data grows.

## The nightly job (Linkding)

CronJob `linkding-backup` in namespace `linkding`, 02:30 America/Los_Angeles. An init container (Linkding's image) takes the snapshot into a temporary volume; then restic uploads it, applies retention and reads the repository back. It runs as Linkding's user with a read-only root filesystem, all capabilities dropped and no service account token. Its network policy allows only DNS and HTTPS to public addresses. The local-path volume keeps the pod on Linkding's node. A new Linkding image needs the same tag here.

## One-time setup (done 2026-11-27)

1. R2 bucket `homelab-app-backups`: Standard storage, public access off, no lock rule.
2. An account API token with **Object Read & Write** on that bucket only.
3. `./scripts/setup-app-backup-r2.sh` in the owner's own terminal. It asks for the endpoint and the two keys, makes the restic password and waits until the password manager's copy matches, creates the repository, and writes `apps/staging/linkding/linkding-backup-secret.yaml`.

Restoring after losing the cluster needs the restic password and R2 access: from the password manager and the Cloudflare account (a new token can be made there), or from that Secret with the SOPS age key.

## Test

`./scripts/test-app-backup.sh` needs Docker. It runs the real Linkding image with sample data and a throwaway restic repository on local disk. It is not part of `validate.sh` or CI.

Run on 2026-11-27, all 19 checks passed:

- A snapshot taken while bookmarks were being added; backup, restore and manifest check.
- A second Linkding started from the restored data: sign-in with the saved password works, a saved bookmark is shown, the bookmark count matches, bookmarks added after the backup are absent, and a sample asset file is back.
- Retention: 40 and 60 day old backups removed, a 30 day old one kept; old backups survive when none are newer.
- Reported as failures: non-empty destination, missing secret key, empty database, broken database, unfinished snapshot, changed file, missing file, wrong row count, wrong password, damaged backup file, missing repository.

Also on 2026-11-27:

- The CronJob in a temporary kind cluster, with a fresh Linkding and a restic repository on a temporary volume instead of R2: it completed with the security settings above. A first attempt that started before Linkding had created its database failed with `database not found`, and the retry succeeded. The network policy's effect was not checked there.
- The setup script with fake keys and a fake Docker and clipboard: bad input, password mismatch, rejected keys and an existing Secret stop it without writing a file. Its real run created and read back the repository in R2.

First run on the homelab cluster, 2026-11-27 (a Job created by hand from the CronJob): completed in 14 s. The snapshot held 705 files with 748 bookmarks and 1 user, the same counts as the live database just before; 1.3 MiB, 759 KiB stored. `check --read-data` found no errors, and Linkding's public health page answered 200 afterwards.

**Not tested yet:** a scheduled (not hand-started) run, whether the network policy blocks other traffic, a restore from R2, the arm64 run on pisrv01, alerts. Audiobookshelf has no spec file yet.

#!/bin/sh
# Upload one snapshot with restic, apply retention, then read the whole repository back. AI-assisted (Claude Code).
# Needs: RESTIC_REPOSITORY, RESTIC_PASSWORD (or RESTIC_PASSWORD_FILE), BACKUP_APP, SNAPSHOT_DIR.
# The repository must already exist: creating it here would hide a wrong bucket or path behind a new, empty one.
set -eu

: "${BACKUP_APP:?set BACKUP_APP}"
: "${SNAPSHOT_DIR:?set SNAPSHOT_DIR}"
if [ ! -s "$SNAPSHOT_DIR/manifest.json" ]; then
  echo "backup FAILED: no manifest in $SNAPSHOT_DIR, the snapshot did not finish" >&2
  exit 1
fi

cd "$SNAPSHOT_DIR"
restic --no-cache backup . --host "$BACKUP_APP" --tag nightly
# keep-within counts back from the newest snapshot, so old backups don't age out while new ones fail.
restic --no-cache forget --host "$BACKUP_APP" --tag nightly --group-by host,tags --keep-within 35d --prune
restic --no-cache check --read-data
echo "backup ok: $BACKUP_APP"

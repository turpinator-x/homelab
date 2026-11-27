#!/bin/sh
# Pull the app backups from R2 into a second restic repository on pisrv01, then restore the newest of each app for
# verify.py to check. R2 is read with a read-only key and --no-lock, so nothing is ever written there. The two copies
# are cleaned up separately: what is deleted in R2 is not deleted here. AI-assisted (Claude Code).
# Needs: RESTIC_REPOSITORY (the local copy), RESTIC_PASSWORD, SOURCE_REPOSITORY, APPS, RESTORE_DIR.
set -eu

: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}"
: "${SOURCE_REPOSITORY:?set SOURCE_REPOSITORY}"
: "${APPS:?set APPS}"
: "${RESTORE_DIR:?set RESTORE_DIR}"
export RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"

if [ ! -f "$RESTIC_REPOSITORY/config" ]; then
  echo "NOTICE: no local copy yet, creating one. If this is not the first run, the earlier copy was lost."
  # Same chunker settings as the source, so copied data is stored only once.
  restic --no-cache --no-lock init --from-repo "$SOURCE_REPOSITORY" --copy-chunker-params
fi
restic --no-cache --no-lock copy --from-repo "$SOURCE_REPOSITORY"
restic --no-cache forget --group-by host,tags --keep-within 35d --prune
restic --no-cache check --read-data
for app in $APPS; do
  restic --no-cache restore latest --host "$app" --target "$RESTORE_DIR/$app"
done
echo "mirror ok: $APPS"

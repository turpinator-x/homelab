#!/usr/bin/env bash
# One-time owner setup for the copy on pisrv01 (docs/backups.md, step 5). Run it in your own terminal.
# It asks only for the READ-ONLY R2 token's two keys (the address and restic password come from the encrypted
# Linkding Secret, using your SOPS key), checks that they can read the backups and CANNOT write, and writes the
# SOPS-encrypted Secret. No secret is printed, passed as an argument or written unencrypted. AI-assisted.
set -euo pipefail
umask 077

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
source_secret=apps/staging/linkding/linkding-backup-secret.yaml
secret=apps/staging/app-backup-mirror/app-backup-mirror-secret.yaml
restic_image=restic/restic:0.20.0@sha256:93999df80d4ac6cb148e82d2ef1fe6a81996f17ff535e772723538211b31555a
history=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/clipboard-history.json

die() { echo "STOPPED: $*" >&2; exit 1; }
for tool in docker sops jq wl-copy; do command -v "$tool" > /dev/null || die "$tool is not installed"; done
[ ! -e "$secret" ] || die "$secret already exists. Nothing was changed."
docker info > /dev/null 2>&1 || die "Docker is not running. Start Rancher Desktop, then run this again."

tmp=$(mktemp)
key_id='' key_secret=''
finish() {
  rm -f "$tmp"
  wl-copy --clear > /dev/null 2>&1 || echo "WARNING: could not clear the clipboard" >&2
  if [ -f "$history" ]; then
    local clean
    clean=$(mktemp)
    if A=$key_id B=$key_secret jq \
      'map(select(([.. | strings | . as $s | (env.A, env.B) | select(length > 0) | . as $x | $s | contains($x)] | any) | not))' \
      "$history" > "$clean"; then cat "$clean" > "$history"; else
      echo "WARNING: could not clean the clipboard history; delete the copied keys from it yourself." >&2
    fi
    rm -f "$clean"
  fi
}
trap finish EXIT

echo "Paste the two keys from the NEW READ-ONLY Cloudflare token. They stay invisible."
read -r -s -p "1) Access Key ID: " key_id; echo
read -r -s -p "2) Secret Access Key: " key_secret; echo
for value in "$key_id" "$key_secret"; do
  [[ $value =~ ^[A-Za-z0-9]{20,}$ ]] || die "a key looks incomplete (letters and numbers only, 20 or more)"
done
[ "$key_id" != "$key_secret" ] || die "the same value was pasted for both keys"

source_json=$(sops --decrypt --output-type json "$source_secret")
repository=$(jq -er .stringData.RESTIC_REPOSITORY <<< "$source_json")
password=$(jq -er .stringData.RESTIC_PASSWORD <<< "$source_json")
rw_id=$(jq -er .stringData.AWS_ACCESS_KEY_ID <<< "$source_json")
source_json=''
[ "$key_id" != "$rw_id" ] || die "that is the read-and-write key. Create a separate read-only token."

export RESTIC_REPOSITORY="$repository" RESTIC_PASSWORD="$password"
export AWS_ACCESS_KEY_ID="$key_id" AWS_SECRET_ACCESS_KEY="$key_secret" AWS_DEFAULT_REGION=auto
restic() {
  docker run --rm -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    -e AWS_DEFAULT_REGION "$restic_image" --no-cache "$@"
}
echo "Checking that these keys can read the backups..."
restic --no-lock snapshots > /dev/null || die "the keys cannot read the backups (message above). Nothing was written."
echo "Checking that they cannot write (an error here is the good result)..."
if restic backup /etc/hostname --host readonly-test --tag readonly-test > /dev/null 2>&1; then
  die "these keys CAN write. Delete that token in Cloudflare and create one with 'Object Read only'.
A small test backup named readonly-test is now in the repository; tell Claude."
fi

printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: app-backup-mirror\n  namespace: app-backup-mirror\ntype: Opaque\nstringData:\n  SOURCE_REPOSITORY: "%s"\n  RESTIC_PASSWORD: "%s"\n  AWS_ACCESS_KEY_ID: "%s"\n  AWS_SECRET_ACCESS_KEY: "%s"\n  AWS_DEFAULT_REGION: "auto"\n' \
  "$repository" "$password" "$key_id" "$key_secret" |
  sops --encrypt --filename-override "$secret" --input-type yaml --output-type yaml /dev/stdin > "$tmp"
for value in "$password" "$key_id" "$key_secret"; do
  if grep -qF -f <(printf '%s\n' "$value") "$tmp"; then die "the encrypted file still shows a secret value"; fi
done
cp "$tmp" "$secret"
chmod 644 "$secret"
echo
echo "DONE. The read-only keys work, cannot write, and are saved encrypted in $secret."
echo "You can close the Cloudflare token page."

#!/usr/bin/env bash
# One-time owner setup for the app backups (docs/backups.md, step 3). Run it in your own terminal.
# It asks for the R2 read-and-write token, makes the restic password and waits until the password manager's copy
# matches, creates the restic repository in R2, and writes the SOPS-encrypted Secret. No secret is printed, passed
# as a command argument or written to disk unencrypted. AI-assisted (Claude Code).
set -euo pipefail
umask 077

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
secret=apps/staging/linkding/linkding-backup-secret.yaml
bucket=homelab-app-backups
restic_image=restic/restic:0.20.0@sha256:93999df80d4ac6cb148e82d2ef1fe6a81996f17ff535e772723538211b31555a
history=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/clipboard-history.json

die() { echo "STOPPED: $*" >&2; exit 1; }
for tool in docker sops openssl jq wl-copy wl-paste; do
  command -v "$tool" > /dev/null || die "$tool is not installed"
done
[ ! -e "$secret" ] || die "$secret already exists. Nothing was changed."
docker info > /dev/null 2>&1 || die "Docker is not running. Start Rancher Desktop, then run this again."

tmp=$(mktemp)
key_id='' key_secret='' password=''
# Remove anything secret that the clipboard history kept (copies made in a browser are not marked sensitive).
scrub_history() {
  [ -f "$history" ] || return 0
  local clean
  clean=$(mktemp)
  if A=$key_id B=$key_secret C=$password jq \
    'map(select(([.. | strings | . as $s | (env.A, env.B, env.C) | select(length > 0) | . as $x | $s | contains($x)] | any) | not))' \
    "$history" > "$clean"; then
    cat "$clean" > "$history" # in place: the clipboard panel watches this file
  else
    echo "WARNING: could not clean the clipboard history; delete the copied keys from it yourself." >&2
  fi
  rm -f "$clean"
}
finish() {
  rm -f "$tmp"
  wl-copy --clear > /dev/null 2>&1 || echo "WARNING: could not clear the clipboard" >&2
  scrub_history
}
trap finish EXIT

echo
echo "Part A: paste three values from the Cloudflare token page. The keys stay invisible as you paste."
read -r -p "1) S3 endpoint (starts with https://): " endpoint
endpoint=${endpoint%/}
endpoint=${endpoint%"/$bucket"} # the bucket settings page shows the link with the bucket name on the end
[[ $endpoint =~ ^https://[0-9a-f]{32}(\.eu)?\.r2\.cloudflarestorage\.com$ ]] ||
  die "that is not an R2 endpoint (expected https://<account id>.r2.cloudflarestorage.com, nothing after it)"
read -r -s -p "2) Access Key ID: " key_id; echo
read -r -s -p "3) Secret Access Key: " key_secret; echo
for value in "$key_id" "$key_secret"; do
  [[ $value =~ ^[A-Za-z0-9]{20,}$ ]] || die "a key looks incomplete (letters and numbers only, 20 or more)"
done
[ "$key_id" != "$key_secret" ] || die "the same value was pasted for both keys"

echo
echo "Part B: save the new backup password in Proton Pass."
password=$(openssl rand -base64 33 | tr -d '\n')
printf '%s' "$password" | wl-copy --sensitive > /dev/null 2>&1
echo "The password is on your clipboard. In Proton Pass, create a Login or Note named:"
echo "    Homelab app backups: restic password"
echo "Paste it (Ctrl+V) and SAVE."
read -r -p "When it is saved, press Enter here: " _
wl-copy --clear > /dev/null 2>&1
echo "Now copy the password back FROM Proton Pass."
while true; do
  read -r -p "After copying it, press Enter here (or type q to stop): " answer
  [ "$answer" != q ] || die "stopped. Nothing was created. Delete that Proton Pass entry."
  copied=$(wl-paste --no-newline 2> /dev/null) || copied=''
  [ "$copied" != "$password" ] || break
  echo "That does not match. Copy only the password from the saved entry, then press Enter."
done
copied=''
echo "MATCH: Proton Pass has the password."
wl-copy --clear > /dev/null 2>&1

export RESTIC_REPOSITORY="s3:$endpoint/$bucket/restic" RESTIC_PASSWORD="$password"
export AWS_ACCESS_KEY_ID="$key_id" AWS_SECRET_ACCESS_KEY="$key_secret" AWS_DEFAULT_REGION=auto

echo
echo "Part C: encrypting the keys, then creating the backup repository in R2."
# printf is a shell builtin, so the values never appear in a process list.
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: linkding-backup\n  namespace: linkding\ntype: Opaque\nstringData:\n  RESTIC_REPOSITORY: "%s"\n  RESTIC_PASSWORD: "%s"\n  AWS_ACCESS_KEY_ID: "%s"\n  AWS_SECRET_ACCESS_KEY: "%s"\n  AWS_DEFAULT_REGION: "auto"\n' \
  "$RESTIC_REPOSITORY" "$password" "$key_id" "$key_secret" |
  sops --encrypt --filename-override "$secret" --input-type yaml --output-type yaml /dev/stdin > "$tmp"
for value in "$password" "$key_id" "$key_secret" "${endpoint#https://}"; do
  if grep -qF -f <(printf '%s\n' "$value") "$tmp"; then die "the encrypted file still shows a secret value"; fi
done
saved=$(sops --decrypt --input-type yaml --output-type json "$tmp" | jq -r .stringData.RESTIC_PASSWORD)
[ "$saved" = "$password" ] || die "the encrypted file does not decrypt back to the same password"
saved=''

restic() {
  docker run --rm -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    -e AWS_DEFAULT_REGION "$restic_image" --no-cache "$@"
}
restic init > /dev/null || die "restic could not create the repository (message above). No file was written.
Check the endpoint, the keys and that the bucket is named $bucket, then run this again.
A new password will be made: replace the one in Proton Pass."
restic snapshots > /dev/null || die "the repository was created but could not be read back. Tell Claude; keep Proton Pass."

cp "$tmp" "$secret"
chmod 644 "$secret" # encrypted, like the other Secrets in Git
echo
echo "DONE. The R2 repository is ready and the encrypted Secret is in $secret."
echo "You can close the Cloudflare token page."

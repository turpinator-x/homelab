#!/usr/bin/env bash
# Owner password reset for the Forgejo trial (docs/forgejo.md). Run it yourself, in a terminal.
# Sets a new temporary password that must be changed at the next sign-in, copies it to the clipboard (marked
# sensitive, so clipboard history can skip it) and shows it once. Nothing is written to a file.
# The temporary password is briefly part of a command line, on this laptop and in the pod. AI-assisted (Claude Code).
set -euo pipefail

read -r -a forgejo <<< "${FORGEJO_CMD:-kubectl --context homelab -n forgejo exec deploy/forgejo -- forgejo}"
read -r -a clip <<< "${CLIP_CMD:-wl-copy --sensitive}"

die() { echo "STOPPED: $*" >&2; exit 1; }

users=$("${forgejo[@]}" admin user list)
names=$(printf '%s\n' "$users" | awk 'NR > 1 && NF { print $2 }')
[ -n "$names" ] || die "there is no account yet: run scripts/setup-forgejo-account.sh"
[ "$(printf '%s\n' "$names" | wc -l)" -eq 1 ] || die "there is more than one account, so nothing was changed"

echo "Your Forgejo username is: $names"
read -r -p "Press Enter to get a new temporary password (Ctrl+C to cancel). " _ || die "nothing was changed"

password=$(openssl rand -hex 16)
"${forgejo[@]}" admin user change-password --username "$names" --password "$password" --must-change-password > /dev/null

if printf '%s' "$password" | "${clip[@]}"; then
  echo "The temporary password is on your clipboard. In the sign-in page, paste it with Ctrl+V."
else
  echo "Could not copy it: select it below and press Ctrl+Shift+C."
fi
cat <<MSG

  Temporary password: $password

  1. Open https://git.home.arpa
  2. Username: $names
  3. Paste the temporary password and sign in.
  4. Make your new password in Proton Pass and SAVE the entry "Forgejo (git.home.arpa)" first.
  5. Then paste it into Forgejo's two new-password boxes.
MSG

#!/usr/bin/env bash
# Copy the trial repository's code and history from GitHub into the empty Forgejo repository (docs/forgejo.md).
# Run it yourself, in a terminal: it asks for your Forgejo username and access token.
# The new local clone's only remote is Forgejo, so work in it can't reach GitHub by accident. Git keeps the token in
# memory only (credential cache, 8 hours): your global "store" helper, which writes plain text, is switched off for
# these commands and in this clone. GitHub is only read. AI-assisted (Claude Code).
set -euo pipefail

repo=chain-explorer
source_url=${SOURCE_URL:-https://github.com/turpinator-x/$repo.git}
forgejo_url=${FORGEJO_URL:-https://git.home.arpa}
dest=${DEST:-$HOME/projects/forgejo-trial/$repo}
ca=${CA_FILE-$HOME/.config/forgejo-trial/git.home.arpa.crt}
history_file=${HISTORY_FILE:-$HOME/.local/state/omarchy/clipboard-history.json}
helper='cache --timeout=28800'

die() { echo "STOPPED: $*" >&2; exit 1; }
export GIT_TERMINAL_PROMPT=0
unset GIT_ASKPASS SSH_ASKPASS

[ ! -e "$dest" ] || die "$dest already exists, so nothing was changed"
settings=(-c credential.helper= -c "credential.helper=$helper")
if [ -n "$ca" ]; then
  [ -s "$ca" ] || die "the certificate file is missing: run scripts/setup-forgejo-account.sh"
  settings+=(-c "http.$forgejo_url/.sslCAInfo=$ca")
fi
tgit() { git "${settings[@]}" "$@"; } # every command that talks to Forgejo

read -r -p "Your Forgejo username: " user
[[ $user =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,38}$ ]] || die "that is not a valid username"
read -r -s -p "Paste the access token (it stays hidden), then press Enter: " token
echo
token=${token//[[:space:]]/}
[[ $token =~ ^[A-Za-z0-9]{40}$ ]] || die "that doesn't look like a Forgejo token (40 letters and numbers)"

# Clipboard history keeps what you copy from a web page. Remove the token from it.
if [ -f "$history_file" ]; then
  cleaned=$(mktemp "$history_file.XXXXXX")
  if TOKEN=$token jq 'map(select((.text // "") | contains(env.TOKEN) | not))' "$history_file" > "$cleaned"; then
    chmod --reference="$history_file" "$cleaned"
    mv "$cleaned" "$history_file"
  else
    rm -f "$cleaned"
    echo "Note: could not clean the clipboard history file."
  fi
fi

protocol=${forgejo_url%%://*} host=${forgejo_url#*://}
credential() { printf 'protocol=%s\nhost=%s\nusername=%s\npassword=%s\n\n' "$protocol" "$host" "$user" "$token"; }
mkdir -p "$(dirname "$dest")"
work=$(mktemp -d "$(dirname "$dest")/.import.XXXXXX")
ok=''
finish() {
  rm -rf "$work"
  # After a failure, forget the token
  if [ -z "$ok" ]; then credential | tgit credential reject; fi
}
trap finish EXIT
credential | tgit credential approve

echo "1 of 4: reading $repo from GitHub"
git clone -q "$source_url" "$work/clone"
source_refs=$(git -C "$work/clone" for-each-ref --format='%(objectname) %(refname)' refs/remotes/origin refs/tags |
  grep -v ' refs/remotes/origin/HEAD$' | sed 's| refs/remotes/origin/| refs/heads/|' | sort -k2)
[ -n "$source_refs" ] || die "the GitHub repository is empty"

target=$forgejo_url/$user/$repo.git
echo "2 of 4: checking the Forgejo repository"
there=$(tgit ls-remote --heads --tags "$target") ||
  die "Forgejo refused. Check the username and token, and that you created the repository \"$repo\"."
there=$(printf '%s' "$there" | awk '{ print $1 " " $2 }' | sort -k2)
if [ -n "$there" ] && [ "$there" != "$source_refs" ]; then
  die "the Forgejo repository isn't empty. Create it without a README or other starting files."
fi

echo "3 of 4: copying the code and history to Forgejo"
git -C "$work/clone" remote set-url origin "$target"
refspecs=()
while read -r sha ref; do refspecs+=("$sha:$ref"); done <<< "$source_refs"
tgit -C "$work/clone" push -q origin "${refspecs[@]}" ||
  die "the push was refused. The token needs \"repository: read and write\"."

echo "4 of 4: downloading it again from Forgejo to check it"
tgit clone -q "$target" "$work/check"
tgit -C "$work/check" fsck --full --no-progress > /dev/null
there=$(tgit ls-remote --heads --tags "$target" | awk '{ print $1 " " $2 }' | sort -k2)
[ "$there" = "$source_refs" ] || die "Forgejo's branches and tags differ from GitHub's"
[ "$(git -C "$work/check" rev-parse HEAD)" = "$(git -C "$work/clone" rev-parse HEAD)" ] || die "the downloaded copy differs"

# Keep these settings in the clone, so later pushes from it behave the same way
git -C "$work/check" config credential.helper ""
git -C "$work/check" config --add credential.helper "$helper"
[ -z "$ca" ] || git -C "$work/check" config "http.$forgejo_url/.sslCAInfo" "$ca"
mv "$work/check" "$dest"
ok=1
echo
echo "DONE: $(git -C "$dest" rev-list --all --count) commits are in Forgejo and download back correctly."
echo "Trial copy: $dest (its only remote is Forgejo). GitHub was only read."

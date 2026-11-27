#!/usr/bin/env bash
# One-time owner setup for the Forgejo trial (docs/forgejo.md). Run it yourself, in a terminal:
#   1. adds git.home.arpa to /etc/hosts (sudo asks for your password)
#   2. saves the server's public certificate for Git to use later
#   3. creates your account with a temporary password that must be changed at first sign-in
# The temporary password is printed once, in your terminal. Nothing secret is written to a file. Safe to rerun.
# AI-assisted (Claude Code).
set -euo pipefail

host=git.home.arpa
hosts_file=${HOSTS_FILE:-/etc/hosts}
cert_dir=${CERT_DIR:-$HOME/.config/forgejo-trial}
read -r -a sudo_cmd <<< "${SUDO_CMD-sudo}"
read -r -a forgejo <<< "${FORGEJO_CMD:-kubectl --context homelab -n forgejo exec deploy/forgejo -- forgejo}"

die() { echo "STOPPED: $*" >&2; exit 1; }

ip=${INGRESS_IP:-$(kubectl --context homelab -n forgejo get ingress forgejo -o 'jsonpath={.status.loadBalancer.ingress[0].ip}')}
[ -n "$ip" ] || die "the cluster reports no address for Forgejo"

echo "Step 1 of 3: the name $host on this laptop"
current=$(awk -v h="$host" '$1 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == h) print $1 }' "$hosts_file")
if [ -z "$current" ]; then
  echo "  Adding one line to $hosts_file. If asked, type your laptop password."
  printf '%s %s\n' "$ip" "$host" | "${sudo_cmd[@]}" tee -a "$hosts_file" > /dev/null
elif [ "$current" != "$ip" ]; then
  die "$hosts_file already points $host somewhere else. Nothing was changed."
fi
echo "  done"

echo "Step 2 of 3: the certificate"
mkdir -p "$cert_dir"
if [ -z "${SKIP_CERT:-}" ]; then
  new=$(mktemp)
  trap 'rm -f "$new"' EXIT
  openssl s_client -connect "$ip:443" -servername "$host" < /dev/null 2> /dev/null | openssl x509 > "$new" \
    || die "could not read the certificate from $host"
  curl -fsS -m 15 --resolve "$host:443:$ip" --cacert "$new" -o /dev/null "https://$host/api/healthz" \
    || die "$host did not answer with that certificate"
  install -m 644 "$new" "$cert_dir/$host.crt"
fi
echo "  done"

echo "Step 3 of 3: your account"
users=$("${forgejo[@]}" admin user list)
if [ "$(printf '%s\n' "$users" | awk 'NR > 1 && NF' | wc -l)" -gt 0 ]; then
  echo "  An account already exists, so nothing was created:"
  printf '%s\n' "$users" | awk 'NR > 1 && NF { print "    " $2 }'
  echo "  If you lost its password, ask Claude for the reset steps."
  exit 0
fi
read -r -p "  Type the username you want, then press Enter: " name
[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,38}$ ]] || die "use letters, numbers, dot, dash or underscore. Nothing was created."
"${forgejo[@]}" admin user create --admin --username "$name" --email "$name@$host" \
  --random-password --random-password-length 24 --must-change-password=true

cat <<MSG

Next, in your browser:
  1. Open https://$host
  2. A certificate warning is expected: this certificate is self-made. Continue to the site.
  3. Sign in as "$name" with the temporary password shown above.
  4. Forgejo asks for a new password. Make one in Proton Pass, save it there as "Forgejo ($host)".
  5. Tell Claude: done
MSG

#!/usr/bin/env bash
# Owner rule (2026-11-15): production and staging carry the SAME explorer/API key names, so every wallet
# scenario works in both ("no mismatches"). Values differ (each environment has its own keys); only the key
# NAMES are compared, which SOPS leaves in plain text. Run by validate.sh, so by CI on every PR.
set -euo pipefail
_here=${BASH_SOURCE[0]%/*}; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=lib/require-tools.sh
. "$_here/lib/require-tools.sh"
require_tools python3 diff sed tr dirname
cd "$(dirname "$0")/.."

prod=apps/staging/blockone-crypto-tax/blockone-explorer-keys-secret.yaml
stag=apps/staging/blockone-crypto-tax-staging/blockone-explorer-keys-secret.yaml

names() {
  # Key names under data: and stringData: of one Secret manifest, sorted.
  python3 - "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
keys = set((d.get("data") or {}).keys()) | set((d.get("stringData") or {}).keys())
if not keys:
    sys.exit(f"{sys.argv[1]}: no keys found")
print("\n".join(sorted(keys)))
PY
}

for f in "$prod" "$stag"; do
  [[ -f "$f" ]] || { echo "key parity: missing $f" >&2; exit 1; }
done

p=$(names "$prod")
s=$(names "$stag")
if [[ "$p" != "$s" ]]; then
  echo "key parity: production and staging explorer keys differ (names only):" >&2
  diff <(printf '%s\n' "$p") <(printf '%s\n' "$s") | sed -n 's/^< /  only in production: /p; s/^> /  only in staging:    /p' >&2
  echo "Add the missing key to the other environment (its own value), so both cover the same chains." >&2
  exit 1
fi
echo "key parity: production and staging have the same explorer keys: $(tr "\n" " " <<<"$p")"

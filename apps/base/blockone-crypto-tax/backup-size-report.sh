#!/bin/sh
# Prints how much a backup store holds and how that compares with its budget; never fails the backup on size.
# Usage: backup-size-report.sh <rclone path or remote> <budget bytes> <label>
# Output lines start with "size:"; "size: WARNING" at 75% of the budget, "size: CRITICAL" at 90%.
# (There is no metric for this: the R2 bucket and the mirror directory are not Kubernetes volumes of their own, so
# the pod log is where it shows. docs/blockone-crypto-tax.md, "Storage and alerts", says how to read it.)
set -eu
target=${1:?usage: backup-size-report.sh <path> <budget bytes> <label>}
budget=${2:?budget bytes}
label=${3:?label}
rclone_bin=${RCLONE:-rclone}
json=$("$rclone_bin" size --json "$target") || { echo "size: could not measure $label" >&2; exit 1; }
bytes=$(printf '%s' "$json" | sed -n 's/.*"bytes":\([0-9][0-9]*\).*/\1/p')
[ -n "$bytes" ] || { echo "size: could not read a size for $label from: $json" >&2; exit 1; }
pct=$((bytes * 100 / budget))
level=ok
[ "$pct" -lt 75 ] || level=WARNING
[ "$pct" -lt 90 ] || level=CRITICAL
echo "size: $level $label holds $bytes bytes, $pct% of its $budget byte budget"

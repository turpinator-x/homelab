#!/bin/sh
# Retention for the BlockOne backups, on R2 (blockone-backup) and on the mirror volume (blockone-backup-mirror).
# Mounted from the ConfigMap blockone-backup-scripts; tested by scripts/test-backup-prune.sh with a stand-in rclone.
#
# Usage: backup-prune.sh <crypt remote, e.g. backup: or local:>      (DRY_RUN=1: print the plan, delete nothing)
#
# A backup SET is everything that carries one stamp: blockone-db-<stamp>.dump, blockone-data-<stamp>.tar.gz and,
# for a pre-release set only, blockone-predeploy-<stamp>.marker (written by the backup job when its Job name is
# bk-predeploy-*, i.e. started by promote.sh). A set with no marker is a nightly set, so anything unrecognised is
# kept for the long period: the failure direction is "keep too much". Pre-rollback sets (bk-prerollback-*) are NOT
# marked: the app tells the owner they hold the only copy of dropped agreement signatures and live 35 days.
# Only paths of the form YYYY/MM/DD/blockone-<kind>-<stamp>.<ext> belong to a set (not .partial files, not files
# in other folders, not copy-blockone-... names).
#
#   pre-release sets: deleted when older than PREDEPLOY_DAYS (7)
#   nightly sets:     deleted when older than NIGHTLY_DAYS (35)
#
# Never deleted, whatever their age:
#   - the newest KEEP_NIGHTLY (3) complete nightly sets and the newest KEEP_PREDEPLOY (5) complete pre-release sets
#     (a rollback needs the set taken just before the last promotion; nightly sets cover a run of failed nights)
#   - the newest complete set of any kind
#   - files that are not part of a recognised set
# A set is complete when it has both the dump and the archive.
#
# Any failed delete prints rclone's error text and stops the run with exit 1 (nothing is swallowed; a bucket lock
# longer than the 7-day pre-release life therefore fails the nightly prune loudly, by design).
#
# Refuses to delete anything (exit 1) when: the listing is empty or fails, no set can be read from it, the clock
# is before 2026 or more than 2 days behind the newest set, nothing complete would remain, or more than
# MAX_DELETE_SETS (60) sets would go in one run.
set -eu

remote=${1:?usage: backup-prune.sh <remote:>}
rclone_bin=${RCLONE:-rclone}
predeploy_days=${PREDEPLOY_DAYS-7}
nightly_days=${NIGHTLY_DAYS-35}
keep_nightly=${KEEP_NIGHTLY-3}
keep_predeploy=${KEEP_PREDEPLOY-5}
max_delete=${MAX_DELETE_SETS-60}
dry=${DRY_RUN:-0}

# stamps as numbers (YYYYMMDDTHHMMSSZ -> YYYYMMDDHHMMSS) so they compare with -lt / -gt in any sh
num() { printf '%s' "$1" | tr -d TZ; }
die() { echo "prune: REFUSED: $*" >&2; exit 1; }

for v in "$predeploy_days" "$nightly_days" "$keep_nightly" "$keep_predeploy" "$max_delete"; do
  case $v in '' | *[!0-9]*) die "settings must be whole numbers, got '$v'" ;; esac
done
[ "$predeploy_days" -ge 7 ] || die "PREDEPLOY_DAYS below 7 is not allowed"
[ "$nightly_days" -ge 35 ] || die "NIGHTLY_DAYS below 35 is not allowed"
[ "$keep_nightly" -ge 1 ] && [ "$keep_predeploy" -ge 1 ] || die "the keep counts must be at least 1"

now=${NOW_EPOCH:-$(date -u +%s)}
[ "$now" -ge 1767225600 ] || die "the clock reads before 2026-01-01 ($now)"
stamp_of() { date -u -d "@$1" +%Y%m%dT%H%M%SZ; }
cut_pre=$(stamp_of $((now - predeploy_days * 86400)))
cut_nig=$(stamp_of $((now - nightly_days * 86400)))
limit_stamp=$(stamp_of "$((now + 2 * 86400))")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$rclone_bin" lsf -R --files-only "$remote" > "$work/listing" || die "could not list $remote"
[ -s "$work/listing" ] || die "the listing of $remote is empty"

# stamp kind(P|N) complete(C|I), oldest first
awk '
  match($0, /^[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9]\/blockone-(db|data|predeploy)-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z\.(dump|tar\.gz|marker)$/) {
    f = substr($0, 12)
    n = split(f, a, "-")
    s = substr(a[3], 1, 16)
    ext = substr(a[3], 18)
    if (a[2] == "db" && ext == "dump") d[s] = 1
    else if (a[2] == "data" && ext == "tar.gz") t[s] = 1
    else if (a[2] == "predeploy" && ext == "marker") p[s] = 1
    else next
    seen[s] = 1
  }
  END { for (s in seen) print s, (s in p ? "P" : "N"), ((s in d) && (s in t) ? "C" : "I") }
' "$work/listing" > "$work/sets.unsorted" || die "could not read the listing"
sort "$work/sets.unsorted" > "$work/sets" || die "could not sort the sets"
[ -s "$work/sets" ] || die "no backup set could be read from the listing of $remote"

newest=$(awk '{ s = $1 } END { print s }' "$work/sets")
[ "$(num "$newest")" -le "$(num "$limit_stamp")" ] || die "the newest set ($newest) is more than 2 days ahead of the clock"
newest_complete=$(awk '$3 == "C" { s = $1 } END { print s }' "$work/sets")
[ -n "$newest_complete" ] || die "no complete set (dump and archive) exists, so nothing is pruned"

# the stamps that are protected by count: newest first
: > "$work/protected"
tac_sets() { awk '{ l[NR] = $0 } END { for (i = NR; i >= 1; i--) print l[i] }' "$work/sets"; }
tac_sets > "$work/sets.newest-first" || die "could not order the sets"
awk -v kn="$keep_nightly" -v kp="$keep_predeploy" '
  $3 == "C" && $2 == "N" && nn < kn { nn++; print $1 }
  $3 == "C" && $2 == "P" && pp < kp { pp++; print $1 }
' "$work/sets.newest-first" > "$work/protected"
echo "$newest_complete" >> "$work/protected"

: > "$work/delete"
while read -r stamp kind complete; do
  if [ "$kind" = P ]; then cut=$cut_pre; else cut=$cut_nig; fi
  if grep -qx "$stamp" "$work/protected"; then
    echo "keep   $stamp kind=$kind complete=$complete (newest sets are never pruned)"
  elif [ "$(num "$stamp")" -lt "$(num "$cut")" ]; then
    echo "delete $stamp kind=$kind complete=$complete (older than $cut)"
    echo "$stamp" >> "$work/delete"
  else
    echo "keep   $stamp kind=$kind complete=$complete"
  fi
done < "$work/sets"

ndel=$(wc -l < "$work/delete")
[ "$ndel" -le "$max_delete" ] || die "$ndel sets would be deleted, more than MAX_DELETE_SETS=$max_delete"
if [ "$ndel" -gt 0 ]; then
  # the survivors must still hold a complete set (the protection above makes this a belt-and-braces check)
  left=$(awk 'NR == FNR { gone[$1] = 1; next } $3 == "C" && !($1 in gone) { n++ } END { print n + 0 }' "$work/delete" "$work/sets")
  [ "$left" -ge 1 ] || die "nothing complete would remain"
fi

if [ "$dry" = 1 ]; then
  echo "prune: dry run, $ndel set(s) would be deleted"
  exit 0
fi

while read -r stamp; do
  grep -E "^[0-9]{4}/[0-9]{2}/[0-9]{2}/blockone-(db|data|predeploy)-$stamp\.(dump|tar\.gz|marker)$" "$work/listing" > "$work/files" || die "no files found for set $stamp"
  while read -r path; do
    echo "deleting $remote$path"
    # A failed delete is always loud: rclone's own error text is printed, and the run exits 1. There is no
    # "locked" special case: with an R2 bucket lock of 6 days or less, pre-release sets (7 days) and nightly sets
    # (35 days) are never younger than the lock, so a refused delete means something is wrong (a longer lock, a
    # wrong token, a network or disk fault) and must be seen.
    if ! err=$("$rclone_bin" deletefile "$remote$path" 2>&1); then
      echo "prune: rclone said: $err" >&2
      echo "prune: FAILED to delete $remote$path" >&2
      exit 1
    fi
  done < "$work/files"
done < "$work/delete"
echo "prune: $ndel set(s) deleted"

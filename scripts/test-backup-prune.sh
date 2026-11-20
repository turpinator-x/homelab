#!/usr/bin/env bash
# the conditions given to ck() are evaluated lazily, so their variables are used inside quotes
# shellcheck disable=SC2016,SC2034
# Usage: ./scripts/test-backup-prune.sh
# Tests apps/base/blockone-crypto-tax/backup-prune.sh against synthetic listings with a stand-in rclone (a
# directory tree on disk). Covers what is deleted and, above all, what must never be: the newest sets, anything
# younger than the retention, files it does not recognise; and that it refuses on a bad listing or clock.
set -euo pipefail
_here=${BASH_SOURCE[0]%/*}; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=lib/require-tools.sh
. "$_here/lib/require-tools.sh"
require_tools git mktemp rm chmod mkdir ln cat grep awk sed sort wc find head date tr diff env bash sh python3 tar gzip mv df ls

root=$(git rev-parse --show-toplevel)
prune="$root/apps/base/blockone-crypto-tax/backup-prune.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0

# stand-in rclone: "lsf -R --files-only <remote>" lists $FAKE_DIR; "deletefile <remote><path>" removes it
cat > "$tmp/rclone" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
  lsf)
    [ -z "${FAKE_LSF_FAIL:-}" ] || exit 3
    # a listing that prints part of it and then fails
    if [ -n "${FAKE_LSF_PARTIAL:-}" ]; then (cd "$FAKE_DIR" && find . -type f | sed 's|^\./||' | sort | head -n 3); exit 3; fi
    (cd "$FAKE_DIR" && find . -type f | sed 's|^\./||' | sort) ;;
  deletefile)
    # FAKE_DEL_ERR: the text rclone prints when a delete fails (default: a generic one)
    [ -z "${FAKE_DEL_FAIL:-}" ] || { echo "${FAKE_DEL_ERR:-ERROR: permission denied}" >&2; exit 4; }
    rm -- "$FAKE_DIR/${2#*:}" ;;
  *) echo "unexpected rclone $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$tmp/rclone"
if [ -n "${BUSYBOX:-}" ]; then
  mkdir "$tmp/bb"
  for a in awk grep sort wc mktemp rm cat; do ln -s "$(readlink -f "$BUSYBOX")" "$tmp/bb/$a"; done
  echo "running under: $BUSYBOX ash (applets: awk grep sort wc mktemp rm cat; this busybox has no date or tr applet, GNU ones are used)"
fi

now=$(date -u -d 2026-11-19T20:00:00Z +%s)
# mkset <dir> <stamp> [nightly|predeploy|partial]
mkset() {
  local d=$1 s=$2 kind=${3:-nightly} day
  day="${s:0:4}/${s:4:2}/${s:6:2}"
  mkdir -p "$d/$day"
  echo x > "$d/$day/blockone-db-$s.dump"
  [ "$kind" = partial ] || echo x > "$d/$day/blockone-data-$s.tar.gz"
  [ "$kind" != predeploy ] || echo x > "$d/$day/blockone-predeploy-$s.marker"
}
run() { # <dir> [env...] -> output in $tmp/out, status in $rc
  local d=$1; shift
  rc=0
  # BUSYBOX=<busybox binary>: run the script with busybox ash and busybox's own applets for everything it calls
  if [ -n "${BUSYBOX:-}" ]; then
    env PATH="$tmp/bb:$PATH" FAKE_DIR="$d" RCLONE="$tmp/rclone" NOW_EPOCH="$now" "$@" "$BUSYBOX" ash "$prune" "r:" > "$tmp/out" 2>&1 || rc=$?
  else
    env FAKE_DIR="$d" RCLONE="$tmp/rclone" NOW_EPOCH="$now" "$@" sh "$prune" "r:" > "$tmp/out" 2>&1 || rc=$?
  fi
}
check() { # <name> <condition: 0 = pass>
  if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; sed 's/^/       /' "$tmp/out"; fails=$((fails + 1)); fi
}
ck() { local r=0; eval "$2" || r=1; check "$1" "$r"; }
kept() { local r=0; has "$1" "$2" || r=1; check "$3" "$r"; }
gone() { local r=0; has "$1" "$2" && r=1; check "$3" "$r"; }
has() { [ -e "$1/${2:0:4}/${2:4:2}/${2:6:2}/blockone-db-$2.dump" ]; }
sets_left() { find "$1" -name 'blockone-db-*' | wc -l; }

# 1. normal: nightly 40 days and 36 days old and 20 days old, predeploy 10, 8, 6 and 1 days old
d=$tmp/t1; mkdir "$d"
mkset "$d" 20261010T103000Z; mkset "$d" 20261014T103000Z; mkset "$d" 20261030T103000Z
mkset "$d" 20261109T150000Z predeploy; mkset "$d" 20261111T150000Z predeploy; mkset "$d" 20261113T150000Z predeploy
mkset "$d" 20261118T150000Z predeploy; mkset "$d" 20261119T103000Z
mkset "$d" 20261116T103000Z; mkset "$d" 20261117T103000Z # three newer nightly sets, so the old ones are not protected by count
mkset "$d" 20261112T150000Z predeploy; mkset "$d" 20261114T150000Z predeploy; mkset "$d" 20261115T150000Z predeploy
run "$d"
check "normal run succeeds" "$rc"
gone "$d" 20261010T103000Z "nightly 40 days old is deleted (newer nightly sets exist)"
gone "$d" 20261014T103000Z "nightly 36 days old is deleted"
kept "$d" 20261030T103000Z "nightly 20 days old is kept"
gone "$d" 20261109T150000Z "predeploy 10 days old is deleted"
gone "$d" 20261111T150000Z "predeploy 8 days old is deleted"
kept "$d" 20261113T150000Z "predeploy 6 days old is kept"
kept "$d" 20261118T150000Z "predeploy 1 day old is kept"
kept "$d" 20261119T103000Z "tonight's nightly is kept"
ck "the marker goes with its set" '[ ! -e "$d/2026/11/09/blockone-predeploy-20261109T150000Z.marker" ]'

# 2. only old sets: newest N of each kind and the newest complete set survive, however old
d=$tmp/t2; mkdir "$d"
for s in 20260101T103000Z 20260102T103000Z 20260103T103000Z 20260104T103000Z 20260105T103000Z; do mkset "$d" "$s"; done
for s in 20260101T150000Z 20260102T150000Z 20260103T150000Z 20260104T150000Z 20260105T150000Z 20260106T150000Z 20260107T150000Z; do mkset "$d" "$s" predeploy; done
run "$d"
check "old-only run succeeds" "$rc"
ck "keeps 3 nightly + 5 predeploy sets of any age (8 left of 12)" '[ "$(sets_left "$d")" -eq 8 ]'
kept "$d" 20260105T103000Z "newest nightly survives"
kept "$d" 20260107T150000Z "newest predeploy survives"
gone "$d" 20260102T150000Z "6th-newest predeploy is deleted"

# 3. the newest verified set is kept even when it is the only one and ancient
d=$tmp/t3; mkdir "$d"; mkset "$d" 20260105T103000Z predeploy
run "$d"
ck "a lone ancient set is kept" '[ "$rc" -eq 0 ] && has "$d" 20260105T103000Z'

# 4. a partial (dump only) newest set never counts as the newest complete one; old partials are junk
d=$tmp/t4; mkdir "$d"
mkset "$d" 20260110T103000Z; mkset "$d" 20260111T103000Z partial; mkset "$d" 20261119T150000Z partial
run "$d"
kept "$d" 20260110T103000Z "the complete set is kept when newer sets are partial"
gone "$d" 20260111T103000Z "an old partial set is deleted"
kept "$d" 20261119T150000Z "a fresh partial set is kept"

# 5. files it doesn't recognise are never touched
d=$tmp/t5; mkdir "$d"; mkset "$d" 20261119T103000Z; mkdir -p "$d/misc"; echo x > "$d/misc/notes.txt"; echo x > "$d/2026/11/19/blockone-db-latest.dump"
run "$d"
ck "unrecognised files are kept" '[ -e "$d/misc/notes.txt" ] && [ -e "$d/2026/11/19/blockone-db-latest.dump" ]'

# 6. dry run deletes nothing
d=$tmp/t6; mkdir "$d"; mkset "$d" 20261001T103000Z; mkset "$d" 20261002T103000Z; mkset "$d" 20261003T103000Z; mkset "$d" 20261004T103000Z; mkset "$d" 20261119T103000Z
before=$(sets_left "$d"); run "$d" DRY_RUN=1
ck "dry run only reports" '[ "$(sets_left "$d")" -eq "$before" ] && grep -q "dry run, 2 set(s) would be deleted" "$tmp/out"'

# 7. refusals (each must exit non-zero and delete nothing)
d=$tmp/t7; mkdir "$d"; mkset "$d" 20261001T103000Z; mkset "$d" 20261002T103000Z; mkset "$d" 20261003T103000Z; mkset "$d" 20261004T103000Z; mkset "$d" 20261119T103000Z
n=$(sets_left "$d")
e=$tmp/empty; mkdir "$e"
run "$d" FAKE_LSF_FAIL=1
ck "refuses when the listing fails" '[ "$rc" -ne 0 ] && [ "$(sets_left "$d")" -eq "$n" ]'
run "$e"
ck "refuses an empty listing" '[ "$rc" -ne 0 ]'
run "$d" NOW_EPOCH=1700000000
ck "refuses a clock before 2026" '[ "$rc" -ne 0 ] && [ "$(sets_left "$d")" -eq "$n" ]'
run "$d" NOW_EPOCH=$((now - 10 * 86400))
ck "refuses a clock far behind the newest set" '[ "$rc" -ne 0 ] && [ "$(sets_left "$d")" -eq "$n" ]'
run "$d" PREDEPLOY_DAYS=3
ck "refuses a predeploy life under 7 days" '[ "$rc" -ne 0 ]'
run "$d" NIGHTLY_DAYS=10
ck "refuses a nightly life under 35 days" '[ "$rc" -ne 0 ]'
run "$d" MAX_DELETE_SETS=1
ck "refuses to delete more than MAX_DELETE_SETS" '[ "$rc" -ne 0 ] && [ "$(sets_left "$d")" -eq "$n" ]'
run "$d" FAKE_DEL_FAIL=1
ck "a failed delete fails the run" '[ "$rc" -ne 0 ]'
f=$tmp/t8; mkdir "$f"; mkset "$f" 20260101T103000Z partial; mkset "$f" 20260102T103000Z partial
run "$f"
ck "refuses when no complete set exists" '[ "$rc" -ne 0 ] && [ "$(sets_left "$f")" -eq 2 ]'
g=$tmp/t9; mkdir -p "$g/misc"; echo x > "$g/misc/a.txt"
run "$g"
ck "refuses a listing with no readable set" '[ "$rc" -ne 0 ]'

# ---- added after review ----
set_exists() { find "$1" -name "blockone-*-$2.*" | grep -q .; }
file_exists() { [ -e "$1" ]; }

# 8. deleted sets lose every file, the archive included
d=$tmp/t10; mkdir "$d"
for s in 20260101T103000Z 20260102T103000Z 20260103T103000Z 20260104T103000Z; do mkset "$d" "$s"; done
run "$d"
ck "the archive goes with a deleted set" '! file_exists "$d/2026/01/01/blockone-data-20260101T103000Z.tar.gz" && ! set_exists "$d" 20260101T103000Z'
ck "the newest sets keep both files" 'file_exists "$d/2026/01/04/blockone-data-20260104T103000Z.tar.gz" && file_exists "$d/2026/01/04/blockone-db-20260104T103000Z.dump"'

# 9. exact boundaries with the default lives (7 and 35 days): older by one second goes, exactly 7 / 35 days stays
d=$tmp/t11; mkdir "$d"
mkset "$d" 20261119T103000Z; mkset "$d" 20261118T103000Z; mkset "$d" 20261117T103000Z; mkset "$d" 20261116T103000Z
mkset "$d" 20261112T195959Z predeploy; mkset "$d" 20261112T200000Z predeploy   # now is 2026-11-19T20:00:00Z
for i in 1 2 3 4 5 6; do mkset "$d" "2026111$((i))T180000Z" predeploy; done  # six newer sets: the old ones are outside the newest five... but newer than 7 days
mkset "$d" 20261015T195959Z; mkset "$d" 20261015T200000Z
run "$d"
gone "$d" 20261112T195959Z "a pre-release set 7 days and 1 second old is deleted (life is 7, not 8)"
kept "$d" 20261112T200000Z "a pre-release set exactly 7 days old is kept"
gone "$d" 20261015T195959Z "a nightly set 35 days and 1 second old is deleted (life is 35, not 36)"
kept "$d" 20261015T200000Z "a nightly set exactly 35 days old is kept"

# 10. count protection only counts complete sets
d=$tmp/t12; mkdir "$d"
for s in 20260101T150000Z 20260102T150000Z 20260103T150000Z 20260104T150000Z 20260105T150000Z; do mkset "$d" "$s" predeploy; done
mkset "$d" 20260106T150000Z predeploy; mkset "$d" 20260107T150000Z predeploy
# two newer pre-release sets that are incomplete (no archive) must not use up protection slots
for s in 20260108T150000Z 20260109T150000Z; do mkset "$d" "$s" predeploy; rm "$d/2026/01/0${s:7:1}/blockone-data-$s.tar.gz"; done
mkset "$d" 20261119T103000Z
run "$d"
kept "$d" 20260103T150000Z "the 5th-newest complete pre-release set is protected although newer partial ones exist"
gone "$d" 20260102T150000Z "the 6th-newest complete pre-release set is not"

# 11. the keep floors and numeric validation
d=$tmp/t13; mkdir "$d"; mkset "$d" 20261119T103000Z; mkset "$d" 20261001T103000Z
run "$d" KEEP_NIGHTLY=0;        ck "refuses KEEP_NIGHTLY=0" '[ "$rc" -ne 0 ]'
run "$d" KEEP_NIGHTLY=;         ck "refuses an empty KEEP_NIGHTLY" '[ "$rc" -ne 0 ]'
run "$d" KEEP_PREDEPLOY=;       ck "refuses an empty KEEP_PREDEPLOY" '[ "$rc" -ne 0 ]'
run "$d" KEEP_PREDEPLOY=0;      ck "refuses KEEP_PREDEPLOY=0" '[ "$rc" -ne 0 ]'
run "$d" PREDEPLOY_DAYS=abc;    ck "refuses a non-numeric predeploy life" '[ "$rc" -ne 0 ]'
run "$d" NIGHTLY_DAYS=;         ck "refuses an empty nightly life" '[ "$rc" -ne 0 ]'
run "$d" MAX_DELETE_SETS=-1;    ck "refuses a negative MAX_DELETE_SETS" '[ "$rc" -ne 0 ]'
run "$d" NOW_EPOCH=abc;         ck "refuses a non-numeric clock" '[ "$rc" -ne 0 ]'

# 12. MAX_DELETE_SETS default is 60: 60 deletions pass, 61 are refused
for n in 65 66; do
  d=$tmp/t14-$n; mkdir "$d"
  i=0; while [ "$i" -lt "$n" ]; do mkset "$d" "$(date -u -d "2026-01-01 + $i days" +%Y%m%d)T150000Z" predeploy; i=$((i + 1)); done
  mkset "$d" 20261119T103000Z
  run "$d"
  if [ "$n" -eq 65 ]; then ck "60 deletions are allowed by default" '[ "$rc" -eq 0 ] && [ "$(sets_left "$d")" -eq 6 ]'
  else ck "61 deletions are refused by default" '[ "$rc" -ne 0 ] && [ "$(sets_left "$d")" -eq 67 ]'; fi
done

# 13. names that are not set members: .partial files, other folders, other prefixes
d=$tmp/t15; mkdir "$d"
mkset "$d" 20261119T103000Z; mkset "$d" 20261001T103000Z; mkset "$d" 20261002T103000Z; mkset "$d" 20261003T103000Z; mkset "$d" 20261004T103000Z
mkdir -p "$d/2026/10/01" "$d/other/2026/10/01" "$d/2026/10/05"
echo x > "$d/2026/10/01/copy-blockone-data-20261001T103000Z.tar.gz"
echo x > "$d/other/2026/10/01/blockone-db-20261001T103000Z.dump"
echo x > "$d/2026/10/01/blockone-data-20261001T103000Z.tar.gz.partial"
echo x > "$d/2026/10/05/blockone-db-20261005T103000Z.dump.partial"
echo x > "$d/2026/10/05/blockone-data-20261005T103000Z.tar.gz"   # an archive plus only a .partial dump: incomplete
run "$d"
ck "a set-named file in another folder is not deleted" 'file_exists "$d/other/2026/10/01/blockone-db-20261001T103000Z.dump"'
ck "copy-blockone-data-<stamp>.tar.gz is not deleted with its set" 'file_exists "$d/2026/10/01/copy-blockone-data-20261001T103000Z.tar.gz"'
ck ".partial files are never deleted or counted as members" 'file_exists "$d/2026/10/01/blockone-data-20261001T103000Z.tar.gz.partial" && file_exists "$d/2026/10/05/blockone-db-20261005T103000Z.dump.partial"'
ck "a set with only a .partial dump is incomplete (its own archive is old junk, deleted)" '! file_exists "$d/2026/10/05/blockone-data-20261005T103000Z.tar.gz"'

# 14. a listing that prints part of itself and then fails
d=$tmp/t16; mkdir "$d"; mkset "$d" 20261001T103000Z; mkset "$d" 20261002T103000Z; mkset "$d" 20261003T103000Z; mkset "$d" 20261004T103000Z; mkset "$d" 20261119T103000Z
n=$(sets_left "$d"); run "$d" FAKE_LSF_PARTIAL=1
ck "a listing that fails halfway refuses and deletes nothing" '[ "$rc" -ne 0 ] && [ "$(sets_left "$d")" -eq "$n" ]'

# 15. pre-rollback sets get no marker and are kept 35 days: an unmarked 10-day-old set is never pruned at 7 days
d=$tmp/t17; mkdir "$d"; mkset "$d" 20261119T103000Z; mkset "$d" 20261118T103000Z; mkset "$d" 20261117T103000Z; mkset "$d" 20261116T103000Z; mkset "$d" 20261109T150000Z
run "$d"
kept "$d" 20261109T150000Z "an unmarked (nightly or pre-rollback) set 10 days old is kept"
# the backup pod's own marker rule, from the manifest
python3 - "$root" "$tmp" << 'PY'
import sys, yaml
root, tmp = sys.argv[1:]
docs = list(yaml.safe_load_all(open(f"{root}/apps/base/blockone-crypto-tax/backup.yaml")))
cj = next(d for d in docs if d["kind"] == "CronJob" and d["metadata"]["name"] == "blockone-backup")
script = cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]["initContainers"][0]["args"][0]
open(f"{tmp}/archive.sh", "w").write(script)
PY
marker_for() { # <job name> -> exit 0 when the archive step writes a marker
  local w=$tmp/arch-$1; rm -rf "$w"; mkdir -p "$w/work" "$w/data"; echo x > "$w/data/f"
  sed "s#/work#$w/work#g; s#-C /data#-C $w/data#; s#^ *ls -l .*##" "$tmp/archive.sh" > "$w/run.sh"
  JOB_NAME=$1 bash "$w/run.sh" > /dev/null
  ls "$w"/work/blockone-predeploy-*.marker > /dev/null 2>&1
}
ck "a bk-predeploy-* job writes the marker" 'marker_for bk-predeploy-abc-1'
ck "a bk-prerollback-* job writes NO marker (35 days)" '! marker_for bk-prerollback-abc-1'
ck "a nightly job writes no marker" '! marker_for blockone-backup-29000'

# 16. every failed delete fails the run and its original error text is printed (nothing is swallowed). The texts
# include paths under blockone/ and /mirror/blockone, which contain the letters "lock".
fail_delete() { # <name> <error text>
  local d=$tmp/t18-$RANDOM; mkdir "$d"; ERRTXT=$2
  mkset "$d" 20261001T103000Z; mkset "$d" 20261002T103000Z; mkset "$d" 20261003T103000Z; mkset "$d" 20261004T103000Z; mkset "$d" 20261119T103000Z
  run "$d" FAKE_DEL_FAIL=1 FAKE_DEL_ERR="$2"
  ck "$1: fails the run (exit non-zero)" '[ "$rc" -ne 0 ]'
  ck "$1: prints rclone's error text" 'grep -qF -- "$ERRTXT" "$tmp/out" && grep -q "FAILED to delete" "$tmp/out"'
  ck "$1: is never reported as skipped" '! grep -q "prune: skipped" "$tmp/out"'
}
fail_delete "AccessDenied with an object path" "Failed to deletefile: AccessDenied: Access Denied (blockone/svgaaq/7me37l/blockone-db-x)"
fail_delete "timeout with the R2 URL" 'Failed to deletefile: RequestError: send request failed: Delete "https://acct.r2.cloudflarestorage.com/blockone-backups/blockone/abc": dial tcp: i/o timeout'
fail_delete "permission denied under the mirror" "Failed to deletefile: remove /mirror/blockone/abc/def: permission denied"
fail_delete "a real object-lock refusal" "Failed to deletefile: AccessDenied: object is locked by a retention rule"
fail_delete "a generic failure" "ERROR: permission denied"

# 18. the guards no other test reaches, with failing stand-ins for awk, sort and grep -E
shim() { # <tool> <condition on args, shell> -> a wrapper in $tmp/shim-<tool> that fails when the condition holds
  local dir=$tmp/shim-$1; mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nif %s; then echo "shim: %s failed" >&2; exit 1; fi\nexec %s "$@"\n' "$2" "$1" "$(command -v "$1")" > "$dir/$1"
  chmod +x "$dir/$1"; echo "$dir"
}
d=$tmp/t21; mkdir "$d"; mkset "$d" 20261001T103000Z; mkset "$d" 20261002T103000Z; mkset "$d" 20261003T103000Z; mkset "$d" 20261004T103000Z; mkset "$d" 20261119T103000Z
n=$(sets_left "$d")
sh_awk=$(shim awk '[[ "$*" == *"seen[s] = 1"* ]]')
run "$d" PATH="$sh_awk:${BUSYBOX:+$tmp/bb:}$PATH"
ck "an awk failure while reading the listing refuses and deletes nothing" '[ "$rc" -ne 0 ] && [ "$(sets_left "$d")" -eq "$n" ]'
sh_sort=$(shim sort 'true')
run "$d" PATH="$sh_sort:${BUSYBOX:+$tmp/bb:}$PATH"
ck "a sort failure refuses and deletes nothing" '[ "$rc" -ne 0 ] && [ "$(sets_left "$d")" -eq "$n" ]'
sh_grep=$(shim grep '[[ "$1" == "-E" ]]')
run "$d" PATH="$sh_grep:${BUSYBOX:+$tmp/bb:}$PATH"
ck "no files found for a set refuses before deleting that set" '[ "$rc" -ne 0 ] && [ "$(sets_left "$d")" -eq "$n" ]'

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed" >&2; exit 1; fi
echo "all prune checks passed"

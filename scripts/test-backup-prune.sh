#!/usr/bin/env bash
# the conditions given to ck() are evaluated lazily, so their variables are used inside quotes
# shellcheck disable=SC2016,SC2034
# Usage: ./scripts/test-backup-prune.sh
# Tests apps/base/blockone-crypto-tax/backup-prune.sh against synthetic listings with a stand-in rclone (a
# directory tree on disk). Covers what is deleted and, above all, what must never be: the newest sets, anything
# younger than the retention, files it does not recognise; and that it refuses on a bad listing or clock.
set -euo pipefail

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
  lsf) [ -z "${FAKE_LSF_FAIL:-}" ] || exit 3; (cd "$FAKE_DIR" && find . -type f | sed 's|^\./||' | sort) ;;
  deletefile) [ -z "${FAKE_DEL_FAIL:-}" ] || exit 4; rm -- "$FAKE_DIR/${2#*:}" ;;
  *) echo "unexpected rclone $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$tmp/rclone"

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
  env FAKE_DIR="$d" RCLONE="$tmp/rclone" NOW_EPOCH="$now" "$@" sh "$prune" "r:" > "$tmp/out" 2>&1 || rc=$?
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

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed" >&2; exit 1; fi
echo "all prune checks passed"

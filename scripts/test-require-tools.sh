#!/usr/bin/env bash
# Usage: ./scripts/test-require-tools.sh
# shellcheck disable=SC2319,SC2016 # "cond; check name $?" is the point; the fix text keeps $PATH literal
# Tests the preflight (scripts/lib/require-tools.sh) that validate.sh and the tests use: a PATH without /usr/bin is
# normalised (self-heal); a missing tool stops the run BEFORE anything else with ONE message that names exactly the
# missing tools, the PATH searched and the fix, and never reaches the old deep "required command 'awk' not found" /
# "sed: can't read" errors; it also works under busybox ash (BUSYBOX, default /usr/lib/initcpio/busybox).
# no -e: a failing "cond; check name $?" line must be reported by check, not abort the run
set -uo pipefail
_here=${BASH_SOURCE[0]%/*}; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=lib/require-tools.sh
. "$_here/lib/require-tools.sh"
require_tools git mktemp rm cat grep mkdir ln env bash
root=$(git rev-parse --show-toplevel)
lib=$root/scripts/lib/require-tools.sh
bash_bin=$(command -v bash)
BUSYBOX=${BUSYBOX:-/usr/lib/initcpio/busybox}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }
# run a command under a given PATH (the shell is always started by absolute path), output in $tmp/out and $tmp/err
runp() {
  local p=$1
  shift
  rc=0
  env PATH="$p" "$@" > "$tmp/out" 2> "$tmp/err" || rc=$?
}
one_message() { [ "$(grep -c '^preflight: required tool' "$tmp/err")" -eq 1 ]; }
no_noise() { ! grep -qE "required command|can't read|No such file|command not found" "$tmp/err" "$tmp/out"; }

# a directory of every /usr/bin tool except the given names: the "this one tool is missing" PATH
farm_without() {
  local d=$1 f n skip
  shift
  mkdir -p "$d"
  for f in /usr/bin/*; do
    n=${f##*/}
    for skip in "$@"; do [ "$n" != "$skip" ] || continue 2; done
    ln -s "$f" "$d/$n"
  done
}

# --- 1. self-heal: a PATH that lacks /usr/bin is normalised
runp /nonexistent "$bash_bin" -c ". '$lib'; require_tools awk sed du find; echo \"\$PATH\""
[ "$rc" -eq 0 ]; check "PATH=/nonexistent: the tools are found after normalising (rc=$rc)" $?
grep -q '^/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/nonexistent$\|^/usr/bin:.*:/nonexistent$\|:/nonexistent$' "$tmp/out"; check "the normalised PATH keeps the existing entry (after the standard directories)" $?
runp "/opt/keep-me:/usr/bin:/bin" "$bash_bin" -c ". '$lib'; normalize_path; echo \"\$PATH\""
case $(cat "$tmp/out") in *:/opt/keep-me:/usr/bin:/bin | /opt/keep-me:/usr/bin:/bin:*) r=0 ;; *) r=1 ;; esac
check "normalising adds only the missing standard directories and keeps the order of the rest ($(cat "$tmp/out"))" $r
runp "/usr/bin:/bin" "$bash_bin" -c ". '$lib'; normalize_path; normalize_path; echo \"\$PATH\""
! grep -qE '(/usr/bin.*){2}' "$tmp/out"; check "normalising twice adds nothing twice" $?

# --- 2. a missing tool: one message, exactly its name
runp /nonexistent "$bash_bin" -c ". '$lib'; require_tools awk no-such-tool-xyz sed"
[ "$rc" -ne 0 ] && one_message && grep -q 'not found: no-such-tool-xyz$' "$tmp/err"; check "a genuinely missing tool is named exactly (and no other) (rc=$rc)" $?
grep -q 'PATH searched: .*/usr/bin' "$tmp/err" && grep -qF 'fix:           export PATH=/usr/local/bin:/usr/bin:/bin:$PATH' "$tmp/err"; check "the message shows the PATH searched (normalised) and the one-line fix" $?
[ ! -s "$tmp/out" ]; check "nothing runs after the failure (no stdout)" $?
runp /nonexistent "$bash_bin" -c ". '$lib'; require_tools no-such-a awk no-such-b"
[ "$rc" -ne 0 ] && one_message && grep -q 'not found: no-such-a no-such-b$' "$tmp/err"; check "several missing tools: still ONE message listing them all" $?
runp /nonexistent "$bash_bin" -c ". '$lib'; require_tools no-such-a; echo REACHED"
! grep -q REACHED "$tmp/out"; check "execution stops at the failing preflight" $?

# --- 3. without normalisation, a PATH lacking one tool: the message names exactly that tool
farm_without "$tmp/noawk" awk
runp "$tmp/noawk" REQUIRE_TOOLS_NO_NORMALIZE=1 "$bash_bin" -c ". '$lib'; require_tools awk sed du find"
[ "$rc" -ne 0 ] && one_message && grep -q 'not found: awk$' "$tmp/err" && grep -qF "PATH searched: $tmp/noawk" "$tmp/err"; check "PATH without awk (no normalising): names exactly awk and the PATH searched" $?
runp "$tmp/noawk" "$bash_bin" -c ". '$lib'; require_tools awk"
[ "$rc" -eq 0 ] && ! grep -q . "$tmp/err" && [ "$(command -v awk)" != "" ]; check "the same PATH with normalising on heals itself when awk lives in a standard directory (rc=$rc)" $?

# a shell function that shadows a program is not the program: with no grep file on PATH the preflight must fail
farm_without "$tmp/nogrep" grep
runp "$tmp/nogrep" REQUIRE_TOOLS_NO_NORMALIZE=1 "$bash_bin" -c "grep() { :; }; . '$lib'; require_tools grep sed"
[ "$rc" -ne 0 ] && one_message && grep -q 'not found: grep$' "$tmp/err"; check "a shell function named grep does not count as the grep program" $?
runp "$tmp/nogrep" "$bash_bin" -c "grep() { :; }; . '$lib'; require_tools grep"
[ "$rc" -eq 0 ]; check "...but the real grep is found by PATH search once the standard directories are added (rc=$rc)" $?

# --- 4. the real tests: they stop at the preflight, before running anything
for t in test-storage-report test-storage-report-manifest test-backup-prune test-backup-manifest test-blockone-alerts check-blockone-key-parity check-staging-memory-parity; do
  runp "$tmp/noawk" REQUIRE_TOOLS_NO_NORMALIZE=1 "$bash_bin" "$root/scripts/$t.sh"
  # only scripts that list awk can be asked about awk; the others must not fail on it
  if grep -qE "^require_tools .*\bawk\b" "$root/scripts/$t.sh"; then
    [ "$rc" -ne 0 ] && one_message && grep -q 'not found: awk$' "$tmp/err" && [ ! -s "$tmp/out" ] && no_noise; check "$t.sh: without awk, one clear message naming awk, no output, no knock-on errors" $?
  else
    runp "$tmp/noawk" REQUIRE_TOOLS_NO_NORMALIZE=1 "$bash_bin" -c ". '$lib'; require_tools $(sed -n 's/^require_tools //p' "$root/scripts/$t.sh" | head -1)"
    [ "$rc" -eq 0 ] || ! grep -q 'not found: awk' "$tmp/err"; check "$t.sh: does not list awk, so its preflight does not name it" $?
  fi
done

# --- 5. validate.sh itself: a PATH without /usr/bin (the release-runner incident)
# the PATH of this run without the standard directories
stripped=
IFS=: read -r -a parts <<< "$PATH"
for d in "${parts[@]}"; do
  case $d in /usr/local/bin | /usr/bin | /bin | /usr/sbin | /sbin | /usr/local/sbin) ;; *) stripped=${stripped:+$stripped:}$d ;; esac
done
if PATH=$stripped command -v awk > /dev/null; then
  echo "skip - awk is outside /usr/bin on this host: cannot reproduce the missing-/usr/bin PATH"
else
  runp "$stripped" VALIDATE_PREFLIGHT_ONLY=1 "$bash_bin" "$root/scripts/validate.sh" --allow-prod-change
  if [ "$rc" -eq 0 ]; then
    grep -q '^== Tools' "$tmp/out" && grep -qE '^  awk +/usr/bin/awk' "$tmp/out" && grep -qE '^  sed +/' "$tmp/out"; check "validate.sh without /usr/bin on PATH self-heals and prints the resolved tool paths" $?
  else
    one_message && ! grep -qE 'not found: .*\b(awk|sed|du|find)\b' "$tmp/err" && no_noise; check "validate.sh without /usr/bin on PATH: one clear message, awk/sed/du/find are not reported (healed); only non-standard tools can be named (rc=$rc)" $?
  fi
fi
runp /nonexistent VALIDATE_PREFLIGHT_ONLY=1 "$bash_bin" "$root/scripts/validate.sh" --allow-prod-change
if [ "$rc" -eq 0 ]; then
  grep -q '^== Tools' "$tmp/out"; check "validate.sh with PATH=/nonexistent finds every tool in the standard directories and prints the header" $?
else
  one_message && ! grep -qE 'not found: .*\b(awk|sed|du|find)\b' "$tmp/err" && no_noise && ! grep -q '^== ' "$tmp/out"; check "validate.sh with PATH=/nonexistent: one message, no section started, awk/sed/du/find healed (rc=$rc)" $?
fi
runp "$tmp/noawk" REQUIRE_TOOLS_NO_NORMALIZE=1 VALIDATE_PREFLIGHT_ONLY=1 "$bash_bin" "$root/scripts/validate.sh" --allow-prod-change
[ "$rc" -ne 0 ] && one_message && grep -qE 'not found: .*\bawk\b' "$tmp/err" && ! grep -q '^== ' "$tmp/out"; check "validate.sh without awk and without normalising: one message naming awk, no section started" $?

# --- 6. busybox ash: the library is POSIX sh
if [ -x "$BUSYBOX" ]; then
  "$BUSYBOX" ash -n "$lib"; check "busybox ash parses the library" $?
  runp "$tmp/noawk" REQUIRE_TOOLS_NO_NORMALIZE=1 "$BUSYBOX" ash -c ". '$lib'; require_tools awk sed"
  [ "$rc" -ne 0 ] && one_message && grep -q 'not found: awk$' "$tmp/err"; check "busybox ash: missing awk is named in one message" $?
  runp /nonexistent "$BUSYBOX" ash -c ". '$lib'; require_tools awk sed du; echo healed"
  [ "$rc" -eq 0 ] && grep -q healed "$tmp/out"; check "busybox ash: PATH=/nonexistent is normalised" $?
  mkdir "$tmp/lt"
  runp /nonexistent "$BUSYBOX" ash -c ". '$lib'; link_tools '$tmp/lt' sed awk"
  [ "$rc" -eq 0 ] && [ -L "$tmp/lt/awk" ] && [ "$tmp/lt/awk" -ef "$(command -v awk)" ] && [ "$(readlink "$tmp/lt/awk")" != awk ]; check "busybox ash: link_tools links the absolute path" $?
else
  echo "skip - busybox not found at $BUSYBOX (set BUSYBOX=...)"
fi

# --- 7. link_tools: a missing tool fails with the same message, a present one is linked by absolute path
mkdir "$tmp/lt2"
runp /nonexistent "$bash_bin" -c ". '$lib'; link_tools '$tmp/lt2' sed no-such-tool-xyz"
[ "$rc" -ne 0 ] && one_message && grep -q 'not found: no-such-tool-xyz$' "$tmp/err"; check "link_tools: a missing tool fails with the same single message" $?

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed" >&2; exit 1; fi
echo "all preflight checks passed"

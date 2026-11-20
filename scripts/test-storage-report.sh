#!/usr/bin/env bash
# Usage: ./scripts/test-storage-report.sh
# Runs the weekly storage report script (apps/base/blockone-crypto-tax/storage-report.sh) against synthetic case
# trees: hostile folder and file names (spaces, newlines, leading dashes, shell metacharacters), symlinks and a symlink
# loop, a folder with 30,000 files; and proves that
#   - no raw folder or file name (nor anything a user could have typed) reaches the log, the alert, the state files;
#   - case folders show only as rank + 6 hex characters of the SHA-256 of the name, and the hash is the right one;
#   - only allow-listed folder names print, anything else is "<other>";
#   - the growth limits (20 percent, 500 MiB for /data, 250 MiB for one folder) turn the digest critical with a
#     GROWTH prefix, and quiet growth stays a warning;
#   - the failure paths fail loudly (Alertmanager refusing, du failing or timing out, missing volume, a missing tool,
#     an unwritable state volume) and never save state after a failed delivery;
#   - it runs under busybox ash (BUSYBOX, default /usr/lib/initcpio/busybox) with that busybox's own applets for every
#     tool it has; the host busybox has no find, nice, timeout, date or tr, so those stay GNU in that run and the
#     busybox find/nice/timeout/date/tr behaviour is covered only by using their common subset (see the docs).
# Needs GNU coreutils/findutils, python3 (JSON check). Run as a normal user (permission-denied cases are skipped as root).
# shellcheck disable=SC2319 # "cond; check name $?" is the point: $? is the condition just above
set -euo pipefail
shopt -s inherit_errexit

root=$(git rev-parse --show-toplevel)
script=${STORAGE_REPORT_SCRIPT:-$root/apps/base/blockone-crypto-tax/storage-report.sh}
BUSYBOX=${BUSYBOX:-/usr/lib/initcpio/busybox}
tmp=$(mktemp -d)
cleanup() { chmod -R u+rwx "$tmp" 2> /dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
fails=0
check() { if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }

# --- helpers -----------------------------------------------------------------------------------------------------
# a stand-in curl: records its arguments and the body, exits with STUB_RC
cat > "$tmp/curl-stub" << 'EOF'
#!/bin/sh
echo "$@" > "$STUB_OUT.args"
for a in "$@"; do
  case $a in @*) cp "${a#@}" "$STUB_OUT.body" ;; esac
done
exit "${STUB_RC:-0}"
EOF
chmod +x "$tmp/curl-stub"

mb() { head -c $(($1 * 1048576)) /dev/zero > "$2"; } # mb <MiB> <file>

fresh() { # fresh <name>: a new state folder and scratch folder, echoes nothing
  rm -rf "${tmp:?}/$1"
  mkdir -p "$tmp/$1/state" "$tmp/$1/scratch"
}

# run_report <name> <data> [VAR=value...]: runs the report with its own state folder; output in $tmp/<name>/{out,err}
run_report() {
  local name=$1 data=$2
  shift 2
  mkdir -p "$tmp/$name/state" "$tmp/$name/scratch"
  local rc=0
  env REPORT_DATA="$data" REPORT_STATE="$tmp/$name/state" REPORT_TMP="$tmp/$name/scratch" CURL="$tmp/curl-stub" \
    STUB_OUT="$tmp/$name/stub" POD_NAMESPACE=blockone-crypto-tax JOB_NAME=blockone-storage-report-test \
    REPORT_NOW=1800000000 "$@" ${SH:-sh} "$script" > "$tmp/$name/out" 2> "$tmp/$name/err" || rc=$?
  return "$rc"
}

# --- fixture: a hostile but plausible volume ---------------------------------------------------------------------
fx=$tmp/fx
mkdir -p "$fx/cases/.case-tmp" "$fx/cases/regwatch" "$fx/cases/.agreements" "$fx/engine" "$tmp/outside"
big="$fx/cases/Zorblax-Q-Taxpayer"
mkdir -p "$big/data/work/cache/alchemy" "$big/data/work/Smithwick Family Trust" "$big/data/work/proof_A" \
  "$big/data/work/locked" "$big/data/raw/koinly" "$big/reports/09_basis_2024" "$big/reports/Q3 ssn123456789" "$big/config"
mb 3 "$big/data/work/cache/alchemy/ssn123456789-wallet.json"
mb 1 "$big/data/work/Smithwick Family Trust/zz.csv"
mb 1 "$big/data/raw/koinly/koinly-export-Zorblax.csv"
head -c 20000 /dev/zero > "$big/reports/09_basis_2024/r.csv"
head -c 10000 /dev/zero > "$big/config/case.yaml"
hostile=(
  "$fx/cases/a b c"
  "$fx/cases/-rf"
  "$fx/cases/--help"
  "$fx/cases/\$(touch $tmp/PWNED)"
  "$fx/cases/\`touch $tmp/PWNED2\`"
  "$fx/cases/;touch $tmp/PWNED3;"
  "$fx/cases/.hidden-nl-secret"
  "$fx/cases/..dotdot-secret"
  "$fx/cases/ünï-çødé-sëcret"
)
i=0
for d in "${hostile[@]}"; do
  mkdir -p "$d/data/work"
  i=$((i + 1))
  head -c $((i * 40000)) /dev/zero > "$d/data/work/f"
  head -c 1000 /dev/zero > "$d/-dash file"
done
nl=$'newline\nsecret-nl'
mkdir -p "$fx/cases/$nl/data/work/$nl" "$fx/cases/$nl/data/work/cache"
head -c 120000 /dev/zero > "$fx/cases/$nl/data/work/$nl/file"
head -c 70000 /dev/zero > "$fx/cases/$nl/data/work/cache/$nl.json"
# symlinks: to a big folder outside the volume, to a file, and a loop
mb 6 "$tmp/outside/huge.bin"
ln -s "$tmp/outside" "$big/data/work/link-to-outside"
ln -s "$tmp/outside" "$fx/cases/link-case"
ln -s ../.. "$big/data/work/loop"
ln -s "$big/config/case.yaml" "$big/data/work/link-to-file"
# a folder named like an allow-listed one, and an app folder with a hostile sibling
mkdir -p "$big/data/work/cache/Secret-Provider-Zorblax"
head -c 5000 /dev/zero > "$big/data/work/cache/Secret-Provider-Zorblax/x"

set +e # from here a failing condition is counted by check, not fatal

leaks() { # leaks <file...>: succeeds when no private token appears in any of the files
  local f t
  for f in "$@"; do
    for t in Zorblax Smithwick ssn123456789 secret-nl "newline" PWNED "a b c" "\-rf" "--help" "ünï" sëcret "dotdot" "hidden-nl" "Q3 " "link-to" "Secret-Provider" "wallet.json" "koinly-export" "-dash"; do
      if grep -qiF -e "$t" "$f" 2> /dev/null; then echo "LEAK: '$t' found in $f" >&2; return 1; fi
    done
  done
  return 0
}

# ---- 1. baseline run on the hostile volume ----
rc=0
run_report r1 "$fx" || rc=$?
check "baseline run exits 0 (rc=$rc)" "$rc"
if [ "$rc" -ne 0 ]; then cat "$tmp/r1/err" >&2; fi
[ ! -e "$tmp/PWNED" ] && [ ! -e "$tmp/PWNED2" ] && [ ! -e "$tmp/PWNED3" ]; check "hostile names were never executed" $?
leaks "$tmp/r1/out" "$tmp/r1/err" "$tmp/r1/stub.body" "$tmp/r1/stub.args" "$tmp/r1/state/last.tsv" "$tmp/r1/state/history.tsv"; check "no raw folder or file name in the log, the alert body, the state files" $?
leaks "$tmp/r1/scratch"/* 2> /dev/null; check "nothing private is left in the scratch folder either (it is removed)" $?
[ -z "$(ls -A "$tmp/r1/scratch")" ]; check "the scratch folder is cleaned up on exit" $?

# ---- 2. hash labels and ranking ----
h() { printf '%s' "$1" | sha256sum | cut -c1-6; }
hb=$(h "Zorblax-Q-Taxpayer"); hn=$(h "$nl"); hh=$(h "-rf")
grep -q "^#1 .* $hb\|^#1 *$hb" "$tmp/r1/out"; check "the largest case folder is rank 1 with the right 6-character SHA-256 ($hb)" $?
grep -Eq "^#[0-9]+ +$hn " "$tmp/r1/out"; check "a name with a newline is labelled by the hash of the whole name ($hn)" $?
grep -Eq "^#[0-9]+ +$hh " "$tmp/r1/out"; check "a leading-dash name is labelled by its hash ($hh)" $?
n=$(grep -Ec '^#[0-9]+ ' "$tmp/r1/out"); [ "$n" -eq 10 ]; check "exactly 10 case folders are listed (got $n)" $?
grep -Eq 'Case folders: 11,' "$tmp/r1/out"; check "all 11 case folders are counted (the app folders and the symlink are not)" $?
awk '/^#[0-9]+ /{ s=$3; if ($4 ~ /KiB/) s=s/1024; if ($4 ~ /GiB/) s=s*1024; if (n++ && s>p+0.0001) bad=1; p=s } END { exit bad }' "$tmp/r1/out"; check "case folders are in descending size order" $?

# ---- 3. allow-list ----
grep -q '^data/work/cache/alchemy ' "$tmp/r1/out"; check "allow-listed names print (data/work/cache/alchemy)" $?
grep -q '^data/work/proof_A ' "$tmp/r1/out"; check "allow-listed names print (data/work/proof_A)" $?
grep -q '^reports/09_basis_2024 ' "$tmp/r1/out"; check "the generated per-year report folder name prints" $?
grep -q '^data/work/<other> ' "$tmp/r1/out"; check "a non-listed folder under data/work becomes <other>" $?
grep -q '^reports/<other> ' "$tmp/r1/out"; check "a non-listed folder under reports becomes <other>" $?
grep -q '^data/work/cache/<other> ' "$tmp/r1/out"; check "a non-listed folder under the cache becomes <other>" $?
! grep -q '<other>' "$tmp/r1/stub.body"; check "the digest has no angle brackets (Telegram HTML)" $?
# a user-chosen name is never allow-listed: the allow-list file has none of the fixture's names
! grep -E "case\b.*(\| *)Zorblax" "$script" > /dev/null; check "the allow-list holds no fixture name" $?

# ---- 4. symlinks are not followed, nothing leaves the volume ----
total_kb=$(awk -F'\t' '$1=="total"{print $3}' "$tmp/r1/state/last.tsv")
[ "$total_kb" -lt 8000 ]; check "a 6 MiB symlinked folder outside the volume is not counted (total ${total_kb} KiB)" $?
[ "$(awk -F'\t' '$1=="tree" && $2=="data"{print $3}' "$tmp/r1/state/last.tsv")" -lt 8000 ]; check "the symlink loop did not inflate the largest case (and the run ended)" $?

# ---- 5. a folder with 30,000 files ----
fx2=$tmp/fx2
mkdir -p "$fx2/cases/c1/data/work/cache/helius" "$fx2/cases/c1/data/work/proof_B"
( cd "$fx2/cases/c1/data/work/cache/helius" && seq 1 30000 | sed 's/^/f/' | xargs touch )
start=$(date +%s)
rc=0
run_report r5 "$fx2" || rc=$?
elapsed=$(($(date +%s) - start))
check "30,000-file run exits 0 (rc=$rc)" "$rc"
awk -F'\t' '$1=="tree" && $2=="data/work/cache/helius" { exit !($4==30000) }' "$tmp/r5/state/last.tsv"; check "the file count is exact (30000) beyond one find batch" $?
[ "$elapsed" -lt 60 ]; check "and fast enough (${elapsed}s)" $?

# ---- 6. growth limits ----
growth_fx() { # growth_fx <dir> <data MiB> <cache MiB> : one case folder
  rm -rf "${1:?}"
  mkdir -p "$1/cases/c1/data/work/cache/alchemy" "$1/cases/c1/data/raw/koinly"
  mb "$2" "$1/cases/c1/data/raw/koinly/k.csv"
  mb "$3" "$1/cases/c1/data/work/cache/alchemy/a.json"
}
sev() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["labels"]["severity"])' "$tmp/$1/stub.body"; }
summ() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["annotations"]["summary"])' "$tmp/$1/stub.body"; }
desc() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["annotations"]["description"])' "$tmp/$1/stub.body"; }
g=$tmp/g
growth_fx "$g" 10 2
run_report gA "$g"; [ "$(sev gA)" = warning ]; check "growth: the first report is a warning (baseline, no comparison)" $?
grep -q "none to compare" "$tmp/gA/out"; check "growth: the first report says it is a baseline" $?
mb 3 "$g/cases/c1/data/raw/koinly/k2.csv" # 12 -> 15 MiB total: +25 percent
run_report gA "$g" REPORT_NOW=1800604800
[ "$(sev gA)" = critical ]; check "growth: +25 percent of /data is critical" $?
summ gA | grep -q '^GROWTH:'; check "growth: a critical digest's summary starts with GROWTH:" $?
desc gA | grep -q 'percent (limit 20 percent)'; check "growth: the reason names the 20 percent limit" $?
grep -q '^GROWTH ALERT' "$tmp/gA/out"; check "growth: the log says GROWTH ALERT" $?

growth_fx "$g" 20 2
run_report gB "$g"
mb 1 "$g/cases/c1/data/raw/koinly/k2.csv" # 22 -> 23 MiB: +4.5 percent
run_report gB "$g" REPORT_NOW=1800604800
[ "$(sev gB)" = warning ] && ! summ gB | grep -q GROWTH; check "growth: +4.5 percent stays a warning without GROWTH" $?
grep -q 'Growth limits.*not crossed' "$tmp/gB/out"; check "growth: the log says the limits were not crossed" $?
rm "$g/cases/c1/data/raw/koinly/k2.csv" "$g/cases/c1/data/raw/koinly/k.csv"
run_report gB "$g" REPORT_NOW=1800700000 # shrinks
[ "$(sev gB)" = warning ]; check "growth: shrinking is a warning" $?

# absolute /data limit (500 MiB in production): same logic with the limit shrunk so a test needs no 500 MiB file
growth_fx "$g" 20 2
big_pct="GROW_PCT=100000"
run_report gC "$g" $big_pct GROW_TOTAL_KIB=2048
mb 3 "$g/cases/c1/data/raw/koinly/k2.csv"
run_report gC "$g" $big_pct GROW_TOTAL_KIB=2048 REPORT_NOW=1800604800
[ "$(sev gC)" = critical ]; check "growth: +3 MiB over a 2 MiB absolute limit is critical (the 500 MiB rule)" $?
desc gC | grep -q 'grew +3.0 MiB (limit 2.0 MiB)'; check "growth: the reason names the absolute limit" $?
rm "$g/cases/c1/data/raw/koinly/k2.csv"
mb 1 "$g/cases/c1/data/raw/koinly/k3.csv"
growth_fx "$g" 20 2
run_report gC2 "$g" $big_pct GROW_TOTAL_KIB=2048
mb 1 "$g/cases/c1/data/raw/koinly/k3.csv"
run_report gC2 "$g" $big_pct GROW_TOTAL_KIB=2048 REPORT_NOW=1800604800
[ "$(sev gC2)" = warning ]; check "growth: +1 MiB under the 2 MiB absolute limit stays a warning" $?

# one allow-listed folder (250 MiB in production)
growth_fx "$g" 20 2
off="GROW_PCT=100000 GROW_TOTAL_KIB=99999999"
run_report gD "$g" $off GROW_FOLDER_KIB=2048
mb 3 "$g/cases/c1/data/work/cache/alchemy/a2.json"
run_report gD "$g" $off GROW_FOLDER_KIB=2048 REPORT_NOW=1800604800
[ "$(sev gD)" = critical ]; check "growth: one folder +3 MiB over a 2 MiB folder limit is critical (the 250 MiB rule)" $?
desc gD | grep -q 'data/work/cache/alchemy grew +3.0 MiB'; check "growth: the digest names the folder that grew" $?
grep -q '^data/work/cache/alchemy .*+3.0 MiB' "$tmp/gD/out"; check "growth: the report shows the change next to the folder" $?
desc gD | grep -q 'Grew: '; check "growth: the digest lists the biggest growers" $?
# just under the folder limit stays quiet (a folder's ancestors, data and data/work, grow with it: the limit applies to each)
growth_fx "$g" 20 2
run_report gE "$g" $off GROW_FOLDER_KIB=2048
head -c 1500000 /dev/zero > "$g/cases/c1/data/work/cache/alchemy/a2.json"
run_report gE "$g" $off GROW_FOLDER_KIB=2048 REPORT_NOW=1800604800
[ "$(sev gE)" = warning ]; check "growth: +1.5 MiB under a 2 MiB folder limit stays a warning" $?
# the production limits are the ones the owner set
grep -q 'GROW_PCT:-20}' "$script" && grep -q 'GROW_TOTAL_KIB:-512000}' "$script" && grep -q 'GROW_FOLDER_KIB:-256000}' "$script"; check "the defaults are 20 percent, 500 MiB (512000 KiB) and 250 MiB (256000 KiB)" $?
# the real production limits, with real allocated files (skipped where fallocate is not available)
if command -v fallocate > /dev/null && fallocate -l 1M "$tmp/falloc-probe" && [ "$(du -sk "$tmp/falloc-probe" | cut -f1)" -ge 1024 ]; then
  growth_fx "$g" 5 2
  run_report gR "$g"
  fallocate -l 260M "$g/cases/c1/data/work/cache/alchemy/big.bin"
  run_report gR "$g" REPORT_NOW=1800604800
  [ "$(sev gR)" = critical ] && desc gR | grep -q 'data/work/cache/alchemy grew +260.0 MiB (limit 250.0 MiB for one folder)'; check "growth, production limits: +260 MiB in one folder is critical (250 MiB rule)" $?
  growth_fx "$g" 5 2
  run_report gR2 "$g"
  fallocate -l 520M "$g/cases/c1/data/raw/koinly/big1.bin"
  run_report gR2 "$g" REPORT_NOW=1800604800
  desc gR2 | grep -q '/data grew +520.0 MiB (limit 500.0 MiB)'; check "growth, production limits: +520 MiB on /data is critical (500 MiB rule)" $?
  # +200 MiB on a 1.5 GiB volume: under 250 MiB, under 500 MiB and under 20 percent
  growth_fx "$g" 5 2
  fallocate -l 1500M "$g/cases/c1/data/raw/koinly/base.bin"
  run_report gR3 "$g"
  fallocate -l 200M "$g/cases/c1/data/work/cache/alchemy/more.bin"
  run_report gR3 "$g" REPORT_NOW=1800604800
  [ "$(sev gR3)" = warning ]; check "growth, production limits: +200 MiB (13 percent) stays a warning" $?
  rm -rf "${g:?}"
else
  echo "skip - fallocate unavailable: the production limits are checked only by their default values"
fi
# a different largest case folder: the tree is not compared (no false growth from swapping cases)
growth_fx "$g" 20 2
run_report gF "$g"
mkdir -p "$g/cases/c2/data/raw/koinly"
mb 30 "$g/cases/c2/data/raw/koinly/z.csv"
run_report gF "$g" GROW_PCT=100000 GROW_TOTAL_KIB=99999999 GROW_FOLDER_KIB=1024 REPORT_NOW=1800604800
! desc gF | grep -q 'data/raw/koinly grew'; check "growth: when the largest case folder changes, its folders are not compared with the old one's" $?

# ---- 7. the alert's shape ----
python3 - "$tmp/gD/stub.body" "$tmp/gD/stub.args" << 'EOF'
import json, re, sys
a = json.load(open(sys.argv[1]))
args = open(sys.argv[2]).read()
ok = True
def chk(name, cond):
    global ok
    print(("ok   - " if cond else "FAIL - ") + name)
    ok = ok and cond
chk("the body is a one-element JSON array", isinstance(a, list) and len(a) == 1)
x = a[0]
chk("alertname is BlockOneStorageReport", x["labels"]["alertname"] == "BlockOneStorageReport")
chk("the Alertmanager BlockOne.+ route matches the alertname", re.fullmatch(r"BlockOne.+", x["labels"]["alertname"]) is not None)
chk("severity is warning or critical (what the route sends to Telegram)", x["labels"]["severity"] in ("warning", "critical"))
chk("summary and description are filled", x["annotations"]["summary"] and x["annotations"]["description"])
chk("the description is under Telegram's 4096 characters", len(x["annotations"]["description"]) < 1500)
chk("endsAt is an RFC 3339 UTC time", re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", x["endsAt"]) is not None)
chk("no angle brackets, ampersands or quotes in the digest", not re.search(r"[<>&\"'\\]", x["annotations"]["description"] + x["annotations"]["summary"]))
chk("curl: fails on HTTP errors (-f), JSON content type, retries", "-fsS" in args and "Content-Type: application/json" in args and "--retry 5" in args)
chk("curl posts to the Alertmanager v2 alerts API", "/api/v2/alerts" in args and "kube-prometheus-stack-alertmanager.monitoring.svc:9093" in args)
sys.exit(0 if ok else 1)
EOF
check "alert shape (see lines above)" $?

# the digest and labels pass a whitelist: hostile settings cannot break the JSON or inject markup
run_report w1 "$fx2" JOB_NAME='x"}],<b>&\' POD_NAMESPACE='ns"<i>'
python3 - "$tmp/w1/stub.body" << 'PYEOF'
import json, re, sys
x = json.load(open(sys.argv[1]))[0]
t = x["annotations"]["description"] + x["annotations"]["summary"] + x["labels"]["namespace"]
sys.exit(1 if re.search(r"[<>&\"'\\]", t) else 0)
PYEOF
check "hostile JOB_NAME and namespace values cannot inject quotes or markup into the alert" $?

# ---- 8. failure paths ----
fresh f1; mkdir -p "$tmp/f1/state"
cp "$tmp/r5/state/last.tsv" "$tmp/f1/state/last.tsv" # another volume's numbers: any overwrite would show
before=$(sha256sum < "$tmp/f1/state/last.tsv")
rc=0
run_report f1 "$fx" STUB_RC=7 || rc=$?
[ "$rc" -ne 0 ]; check "Alertmanager unreachable: the Job fails (rc=$rc)" $?
grep -q 'Alertmanager did not accept' "$tmp/f1/err"; check "Alertmanager unreachable: says so on stderr" $?
[ "$before" = "$(sha256sum < "$tmp/f1/state/last.tsv")" ] && [ ! -e "$tmp/f1/state/history.tsv" ]; check "Alertmanager unreachable: the state is NOT updated (next report still compares with the last delivered one)" $?
grep -q '^1\. Summary' "$tmp/f1/out"; check "Alertmanager unreachable: the report was still printed in full" $?
leaks "$tmp/f1/out" "$tmp/f1/err"; check "Alertmanager unreachable: still no raw names" $?

rc=0; run_report f2 "$tmp/does-not-exist" || rc=$?
[ "$rc" -ne 0 ] && grep -q 'not mounted' "$tmp/f2/err"; check "no data volume: fails" $?
mkdir -p "$tmp/emptyvol"
rc=0; run_report f3 "$tmp/emptyvol" || rc=$?
[ "$rc" -ne 0 ] && grep -q "no 'cases' folder" "$tmp/f3/err"; check "a volume without cases/: fails (wrong volume)" $?
rc=0; run_report f4 "$fx" REPORT_STATE="$tmp/no-such-state" || rc=$?
[ "$rc" -ne 0 ] && grep -q 'state volume' "$tmp/f4/err"; check "missing state volume: fails" $?

if [ "$(id -u)" -ne 0 ]; then
  fx3=$tmp/fx3
  mkdir -p "$fx3/cases/Zorblax-locked/data/work/Smithwick" "$fx3/cases/other/data"
  head -c 1000 /dev/zero > "$fx3/cases/Zorblax-locked/data/work/Smithwick/ssn123456789.csv"
  chmod 000 "$fx3/cases/Zorblax-locked/data/work/Smithwick"
  rc=0; run_report f5 "$fx3" || rc=$?
  chmod 755 "$fx3/cases/Zorblax-locked/data/work/Smithwick"
  [ "$rc" -ne 0 ] && grep -q "'du' failed twice" "$tmp/f5/err"; check "du fails on an unreadable folder: the Job fails (rc=$rc)" $?
  grep -q 'permission denied' "$tmp/f5/err"; check "du failure: the reason is summarised from a fixed list" $?
  leaks "$tmp/f5/out" "$tmp/f5/err"; check "du failure: the path of the unreadable folder is not in the log" $?
  [ ! -e "$tmp/f5/state/last.tsv" ]; check "du failure: no state saved" $?
  fresh f6; chmod 555 "$tmp/f6/state"
  rc=0; run_report f6 "$fx" || rc=$?
  chmod 755 "$tmp/f6/state"
  [ "$rc" -ne 0 ]; check "an unwritable state volume fails before measuring (rc=$rc)" $?
else
  echo "skip - permission-denied cases (running as root)"
fi

# a slow du: the timeout kills it, the Job fails
mkdir -p "$tmp/slowbin"
printf '#!/bin/sh\nsleep 20\n' > "$tmp/slowbin/du"
chmod +x "$tmp/slowbin/du"
rc=0; run_report f7 "$fx2" PATH="$tmp/slowbin:$PATH" CMD_TIMEOUT=1 || rc=$?
[ "$rc" -ne 0 ] && grep -q "failed twice (exit 124" "$tmp/f7/err"; check "a du that hangs is killed by the timeout and the Job fails (rc=$rc)" $?

# a missing tool
mkdir -p "$tmp/nofind"
for t in $(compgen -c | sort -u | grep -E '^(du|df|stat|awk|sort|sed|cut|tr|wc|sha256sum|date|mktemp|timeout|nice|grep|head|tail|cat|sleep|mv|rm|sh|env|python3|ionice|seq|touch|printf|dirname|basename)$'); do
  ln -sf "$(command -v "$t")" "$tmp/nofind/$t" 2> /dev/null || true
done
rc=0; run_report f8 "$fx2" PATH="$tmp/nofind" || rc=$?
[ "$rc" -ne 0 ] && grep -q "required command 'find' not found" "$tmp/f8/err"; check "a missing find fails loudly instead of reporting zeros" $?

# a damaged state file is reported, not trusted
fresh f9; printf 'garbage\n' > "$tmp/f9/state/last.tsv"
rc=0; run_report f9 "$fx2" || rc=$?
[ "$rc" -eq 0 ] && grep -q 'state file damaged' "$tmp/f9/out"; check "a damaged state file is announced and the report restarts the baseline" $?

# --- 9. busybox ash ---
if [ -x "$BUSYBOX" ]; then
  "$BUSYBOX" ash -n "$script"; check "busybox ash parses the script" $?
  farm=$tmp/bbfarm
  mkdir -p "$farm"
  for t in du df stat awk sort sed cut wc sha256sum mktemp grep head tail cat sleep mv rm cp printf seq touch tee uniq; do
    if "$BUSYBOX" --list | grep -qx "$t"; then ln -sf "$BUSYBOX" "$farm/$t"; fi
  done
  for t in find tr date timeout nice ionice sh env xargs dirname basename python3; do # no busybox applet on this host
    p=$(command -v "$t" || true)
    if [ -n "$p" ] && [ ! -e "$farm/$t" ]; then ln -sf "$p" "$farm/$t"; fi
  done
  rc=0
  SH="$BUSYBOX ash" run_report bb "$fx" PATH="$farm" || rc=$?
  check "the whole report runs under busybox ash with busybox du/df/stat/awk/sed/sort/sha256sum (rc=$rc)" "$rc"
  if [ "$rc" -ne 0 ]; then tail -5 "$tmp/bb/err" >&2; fi
  diff <(sed '/^meta/d' "$tmp/r1/state/last.tsv") <(sed '/^meta/d' "$tmp/bb/state/last.tsv"); check "busybox and GNU measure and label the same tree identically (state files equal)" $?
  leaks "$tmp/bb/out" "$tmp/bb/err" "$tmp/bb/stub.body"; check "busybox run: no raw names either" $?
else
  echo "skip - busybox not found at $BUSYBOX (set BUSYBOX=...)"
fi

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed" >&2; exit 1; fi
echo "all storage report checks passed"

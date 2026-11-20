#!/bin/sh
# Weekly read-only storage report for the BlockOne case-files volume (storage-report.yaml; docs/blockone-crypto-tax.md,
# "Weekly storage report"). POSIX sh, written for busybox ash (the curl image's shell) and tested under GNU too
# (scripts/test-storage-report.sh).
#
# It measures with du/find only, never follows symlinks, never leaves the volume (-x), runs at idle priority under a
# timeout, and writes nothing to the data volume (mounted read-only). Its only write is the small state volume
# ($STATE), which holds the previous report's numbers so growth can be shown and judged.
#
# PRIVACY: nothing the app's users chose (case folder names, file names, taxpayer names or IDs) is ever printed, logged
# or sent:
#   - case folders are labelled by rank and the first 6 hex characters of the SHA-256 of the folder name;
#   - below a case folder, a folder is named only if its name is on the fixed allow-list in label_of() (names the app
#     itself creates); any other folder is counted into an "<other>" bucket;
#   - file names are never read out, only counted (find -exec sh -c 'echo $#');
#   - the stderr of du/find/stat is withheld (it contains paths) and summarised by a fixed set of reason phrases;
#   - the digest sent to Alertmanager passes a character whitelist.
# So the log, the state files and the alert are free of private names even for hostile folder names.
#
# Exit codes: 0 report printed, alert delivered, state saved. 1 any failure (du/find failed or timed out, the volume
# is missing, Alertmanager unreachable or refused the alert): the Job fails and BlockOneStorageReportJobFailed fires.
#
# Settings (environment; the defaults are the production values, the others exist for the tests):
#   REPORT_DATA /data   REPORT_STATE /state   REPORT_TMP /tmp   ALERT_URL (in-cluster Alertmanager v2 alerts API)
#   POD_NAMESPACE, JOB_NAME (set from the pod by the manifest)   CURL (curl command)   REPORT_NOW (epoch; tests)
#   GROW_PCT 20, GROW_TOTAL_KIB 512000 (500 MiB), GROW_FOLDER_KIB 256000 (250 MiB)
set -eu
umask 077
LC_ALL=C # one sort order everywhere (busybox, GNU)
export LC_ALL

TAB=$(printf '\t')
DATA=${REPORT_DATA:-/data}
STATE=${REPORT_STATE:-/state}
TMPROOT=${REPORT_TMP:-/tmp}
ALERT_URL=${ALERT_URL:-http://kube-prometheus-stack-alertmanager.monitoring.svc:9093/api/v2/alerts}
CURL=${CURL:-curl}
NS=${POD_NAMESPACE:-unknown}
JOB=${JOB_NAME:-blockone-storage-report}
CMD_TIMEOUT=${CMD_TIMEOUT:-120}      # per du/find call
TOP_N=10
MAX_DEPTH=${REPORT_MAX_DEPTH:-7}     # folder levels below the largest taxpayer folder (data/work/cache/alchemy/<network> is 5)
MAX_DUCALLS=${REPORT_MAX_DUCALLS:-800}
PVC_NOMINAL_KIB=${PVC_NOMINAL_KIB:-5242880}   # the data PVC's nominal size (5Gi); local-path does not enforce it
GROW_PCT=${GROW_PCT:-20}
GROW_TOTAL_KIB=${GROW_TOTAL_KIB:-512000}
GROW_FOLDER_KIB=${GROW_FOLDER_KIB:-256000}
ALERT_TTL=${ALERT_TTL:-900}          # seconds the alert stays active (a "resolved" message follows)
NOW=${REPORT_NOW:-$(date -u +%s)}

die() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- preflight --------------------------------------------------------------------------------------------------
HARD="du find df stat awk sort sed cut tr wc sha256sum date mktemp grep head tail cat sleep mv rm cp tee"
FOUND=
MISSING=
for c in $HARD nice timeout ionice; do
  if command -v "$c" > /dev/null 2>&1; then FOUND="$FOUND $c"; else MISSING="$MISSING $c"; fi
done
for c in $HARD; do
  case " $MISSING " in *" $c "*) die "required command '$c' not found (found:$FOUND; missing:$MISSING)" ;; esac
done
command -v "$CURL" > /dev/null 2>&1 || die "required command '$CURL' not found"
[ -d "$DATA" ] || die "the data volume is not mounted (no folder at the data mount path)"
[ -d "$DATA/cases" ] || die "the data volume has no 'cases' folder: the wrong volume, or the app has never started"
[ -d "$STATE" ] && [ -w "$STATE" ] || die "the state volume is missing or not writable"
[ -d "$TMPROOT" ] && [ -w "$TMPROOT" ] || die "the scratch folder is missing or not writable"

W=$(mktemp -d "$TMPROOT/storage-report.XXXXXX") || die "cannot make a scratch folder"
trap 'rm -rf "$W"' EXIT
ERR=$W/err
: > "$ERR"
DUCALLS=0
TRUNCATED=0

# nice, idle I/O class and a timeout keep du/find from hogging the node. Each is used if present; a missing one is a
# loud note in the log (the Job's own 300 s deadline still bounds the run), never silent.
TOOL_NOTES=
PFX=
case " $FOUND " in
  *" nice "*) PFX="nice -n 19" ;;
  *) TOOL_NOTES="$TOOL_NOTES
WARNING: nice is missing: running at normal CPU priority." ;;
esac
if case " $FOUND " in *" ionice "*) true ;; *) false ;; esac && ionice -c 3 true > /dev/null 2>&1; then
  PFX="$PFX ionice -c 3"
else
  TOOL_NOTES="$TOOL_NOTES
WARNING: idle I/O class (ionice) is not available here: running at normal I/O priority."
fi
case " $FOUND " in
  *" timeout "*) PFX="$PFX timeout $CMD_TIMEOUT" ;;
  *) TOOL_NOTES="$TOOL_NOTES
WARNING: timeout is missing: du/find run without a per-call time limit." ;;
esac
# shellcheck disable=SC2086 # PFX is a fixed list of words without spaces or glob characters
gentle() {
  $PFX "$@"
}
UNREADABLE=0

# stderr of du/find/stat holds paths: never print it; say what kind of error it was, from a fixed list
errsum() {
  if [ ! -s "$ERR" ]; then
    echo "no error text"
    return 0
  fi
  awk '
    /Permission denied/ { a++ }
    /No such file or directory/ { b++ }
    /Input\/output error/ { c++ }
    /Not a directory/ { d++ }
    /Operation not permitted/ { e++ }
    /Stale file handle/ { f++ }
    { n++ }
    END {
      s = ""
      if (a) s = s "permission denied x" a "; "
      if (b) s = s "vanished while scanning x" b "; "
      if (c) s = s "I/O error x" c "; "
      if (d) s = s "not a directory x" d "; "
      if (e) s = s "operation not permitted x" e "; "
      if (f) s = s "stale file handle x" f "; "
      if (s == "") s = "unrecognised error text (withheld: it can contain folder names); "
      printf "%s%d line(s) of tool output withheld", s, n
    }' "$ERR"
}

# guarded OUTFILE CMD ARGS...: run gently, stdout to OUTFILE, stderr withheld; one retry (a file removed mid-scan).
# A second failure ends the run, EXCEPT exit 1 with output (du, find: "some entries could not be read", which is what a
# permission problem in one folder looks like): that is counted in UNREADABLE and the partial numbers are used,
# so one unreadable folder never hides the rest. Exit 2 and up, a timeout, or no output from du still fail the run.
guarded() {
  g_out=$1
  shift
  g_tries=0
  while :; do
    g_rc=0
    gentle "$@" > "$g_out" 2> "$ERR" || g_rc=$?
    if [ "$g_rc" -eq 0 ]; then return 0; fi
    g_tries=$((g_tries + 1))
    if [ "$g_tries" -ge 2 ]; then
      if [ "$g_rc" -eq 1 ] && { [ -s "$g_out" ] || [ "$1" = find ]; }; then
        UNREADABLE=$((UNREADABLE + 1))
        errsum >> "$W/unreadable.txt"
        echo >> "$W/unreadable.txt"
        return 0
      fi
      die "'$1' failed twice (exit $g_rc, 124/143 = timed out): $(errsum)"
    fi
    echo "note: '$1' failed once (exit $g_rc: $(errsum)); trying again in 3 s" >&2
    sleep 3
  done
}

# Helper run by find -exec ... {} + : one line per batch, so no file name is ever on a line of ours
cat > "$W/batch-count.sh" << 'EOF'
echo "C $#"
EOF
cat > "$W/batch-mtime.sh" << 'EOF'
echo "C $#"
t=$(stat -c %Y -- "$@") || exit 1
echo "$t" | awk 'NR == 1 || $1 > m { m = $1 } END { print "M", m + 0 }'
EOF

# measure_kb DIR -> KB (KiB, allocated, symlinks not followed, one filesystem)
measure_kb() {
  guarded "$W/du.out" du -skx "$1"
  KB=$(awk 'NR == 1 { print $1 + 0; exit }' "$W/du.out")
  DUCALLS=$((DUCALLS + 1))
}

# count_files DIR [mtime] -> FILES (regular files) and NEWEST (epoch of the newest file, 0 when not asked or empty)
count_files() {
  if [ "${2:-}" = mtime ]; then
    guarded "$W/find.out" find "$1" -xdev -type f -exec sh "$W/batch-mtime.sh" {} +
  else
    guarded "$W/find.out" find "$1" -xdev -type f -exec sh "$W/batch-count.sh" {} +
  fi
  awk '$1 == "C" { c += $2 } $1 == "M" && $2 > m { m = $2 } END { print c + 0, m + 0 }' "$W/find.out" > "$W/pair"
  read -r FILES NEWEST < "$W/pair"
}

# count_loose DIR -> LOOSE (entries directly inside DIR that are not folders: files, symlinks)
count_loose() {
  guarded "$W/find.out" find "$1" -mindepth 1 -maxdepth 1 ! -type d -exec sh "$W/batch-count.sh" {} +
  LOOSE=$(awk '$1 == "C" { c += $2 } END { print c + 0 }' "$W/find.out")
}

# --- the allow-list ---------------------------------------------------------------------------------------------
# Folder names the application (or the volume itself) creates: taken from the app repo's src/ and docs/
# (nftcb workspace layout, web/chainjobs, jobs, backup/restore scripts). A name not listed here is "<other>".
# Never add a name a user can choose (case, wallet, taxpayer, file names).
label_of() { # NAME PARENT-NAME
  case $1 in
    cases | engine | regwatch | .agreements | .case-tmp | lost+found) LABEL=$1 ;;
    README.md) LABEL=$1 ;;
    data | raw | work | config | reports | uploads | .tmp | decisions | packages | tmp | share | exports) LABEL=$1 ;;
    cache | direct | locked | lock_history | seed_adjustments | proof_A | proof_B | opening | pending | superseded) LABEL=$1 ;;
    corrections | corrections_head | checkpoints | records | tokens | collectibles | ledger | basis | audit | scans) LABEL=$1 ;;
    flarebank | identity | asset_ids | kraken | kraken_api | blofin | koinly | koinly_superseded | koinly_reports) LABEL=$1 ;;
    exodus | estate | evidence_copy | probe | agreements | web | security | sources | report | docs | templates | static) LABEL=$1 ;;
    bsc | base | optimism | ethereum | polygon | avalanche | arbitrum | linea | scroll | zksync | blast | gnosis | celo | mantle | fantom | mainnet) LABEL=$1 ;;
    eth-mainnet | bsc-mainnet | base-mainnet | opt-mainnet | arb-mainnet | polygon-mainnet | avax-mainnet) LABEL=$1 ;;
    alchemy | alchemy_data | alchemy_nft | algorand | blockscout | coingecko | esplora | etherscan | flare_api) LABEL=$1 ;;
    goplus | helius | irs | pi | solana | xrpl | blockone | kraken_api_raw | blofin_raw | regulatory_watch) LABEL=$1 ;;
    13_security | 38_cpa_decision_rules | 39_zero_proceeds | 07_compare_all) LABEL=$1 ;;
    [0-9][0-9]_compare_[0-9][0-9][0-9][0-9] | [0-9][0-9]_basis_[0-9][0-9][0-9][0-9]) LABEL=$1 ;;
    [0-9][0-9]_forms_[0-9][0-9][0-9][0-9] | [0-9][0-9]_chain_[0-9][0-9][0-9][0-9]) LABEL=$1 ;;
    [0-9][0-9]_fixlist_[0-9][0-9][0-9][0-9] | [0-9][0-9]_year_package_[0-9][0-9][0-9][0-9]) LABEL=$1 ;;
    [0-9][0-9]_koinly_vs_blockone_[0-9][0-9][0-9][0-9]) LABEL=$1 ;;
    [12][0-9][0-9][0-9]) # a tax-year folder, only where the app makes them
      case ${2:-} in
        reports | locked | lock_history | packages | opening | basis | ledger) LABEL=$1 ;;
        *) LABEL='<other>' ;;
      esac
      ;;
    .pre-restore-*) LABEL='.pre-restore-*' ;;
    .restoring-*) LABEL='.restoring-*' ;;
    *) LABEL='<other>' ;;
  esac
}

# App folders that sit next to the case folders in cases/ (everything else there is a case folder)
is_app_dir() {
  case $1 in
    .case-tmp | .agreements | regwatch | lost+found | .pre-restore-* | .restoring-*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- formatting (awk) -------------------------------------------------------------------------------------------
AWKFMT='
function h(kb,   a) {
  a = kb < 0 ? -kb : kb
  if (a >= 1048576) return sprintf("%.2f GiB", kb / 1048576)
  if (a >= 1024) return sprintf("%.1f MiB", kb / 1024)
  return sprintf("%d KiB", kb)
}
function hs(kb) { return (kb > 0 ? "+" : "") h(kb) }
'
# busybox awk has no strftime: dates are formatted by date(1) in the shell
fmt_day() {
  if [ "$1" -gt 0 ]; then date -u -d "@$1" +%Y-%m-%d; else echo "-"; fi
}
human() {
  awk -v kb="$1" "$AWKFMT"' BEGIN { print h(kb) }'
}
human_signed() {
  awk -v kb="$1" "$AWKFMT"' BEGIN { print hs(kb) }'
}

# --- measure ----------------------------------------------------------------------------------------------------
echo "Measuring (this is slow on purpose: nice, idle I/O, one folder at a time)..." >&2

measure_kb "$DATA"
TOTAL_KB=$KB

# 1. top-level folders of /data
: > "$W/top.tsv"
for c in "$DATA"/* "$DATA"/.[!.]* "$DATA"/..?*; do
  [ -d "$c" ] || continue
  [ -L "$c" ] && continue
  label_of "${c##*/}"
  measure_kb "$c"
  count_files "$c"
  printf '%s\t%s\t%s\n' "$LABEL" "$KB" "$FILES" >> "$W/top.tsv"
done
count_loose "$DATA"
TOP_LOOSE=$LOOSE
# several <other> folders become one row
awk -F "$TAB" '{ k[$1] += $2; f[$1] += $3 } END { for (l in k) printf "%s\t%d\t%d\n", l, k[l], f[l] }' "$W/top.tsv" > "$W/top.sum"
mv "$W/top.sum" "$W/top.tsv"
TOTAL_FILES=$(awk -F "$TAB" -v l="$TOP_LOOSE" '{ f += $3 } END { print f + l }' "$W/top.tsv")

# 2. cases/: the app stores a taxpayer's workspace at cases/<account id>/<taxpayer id>/ (app: web/files.py
# workspace_path); a flat cases/<id>/ is supported too. App folders (regwatch, .agreements, ...) are named, every
# other folder is an account (or a flat case), shown only as a 6-hex hash of its name.
: > "$W/appdirs.tsv"
: > "$W/cases.tsv"
CASES_KB=0
NCASES=0
BIG_DIR=
BIG_KB=-1
BIG_KEY=
has_workspace() {
  [ -d "$1/data" ] || [ -d "$1/reports" ] || [ -d "$1/config" ]
}
record_case() { # DIR ACCOUNT-HASH NAME
  measure_kb "$1"
  count_files "$1"
  rc_hash=$(printf '%s' "$3" | sha256sum | cut -c1-6)
  printf '%s\t%s\t%s\t%s\n' "$KB" "$rc_hash" "$FILES" "$2" >> "$W/cases.tsv"
  NCASES=$((NCASES + 1))
  CASES_KB=$((CASES_KB + KB))
  if [ "$KB" -gt "$BIG_KB" ]; then
    BIG_KB=$KB
    BIG_DIR=$1
    BIG_KEY="$2/$rc_hash"
  fi
}
for c in "$DATA/cases"/* "$DATA/cases"/.[!.]* "$DATA/cases"/..?*; do
  [ -d "$c" ] || continue
  [ -L "$c" ] && continue
  name=${c##*/}
  if is_app_dir "$name"; then
    measure_kb "$c"
    count_files "$c"
    label_of "$name"
    printf '%s\t%s\t%s\n' "$LABEL" "$KB" "$FILES" >> "$W/appdirs.tsv"
  elif has_workspace "$c"; then
    record_case "$c" "-" "$name"
  else
    acc=$(printf '%s' "$name" | sha256sum | cut -c1-6)
    for t in "$c"/* "$c"/.[!.]* "$c"/..?*; do
      [ -d "$t" ] || continue
      [ -L "$t" ] && continue
      record_case "$t" "$acc" "${t##*/}"
    done
  fi
done
count_loose "$DATA/cases"
CASES_LOOSE=$LOOSE
sort -t "$TAB" -k1,1nr -k4,4 -k2,2 "$W/cases.tsv" > "$W/cases.sorted"

# 3. inside the largest case folder: allow-listed names only
: > "$W/tree.tsv"
# shellcheck disable=SC3043 # local is in busybox ash and every other shell this runs under
walk() { # DIR PREFIX LEVELS_LEFT PARENT-NAME
  local w_dir="$1" w_prefix="$2" w_left="$3" w_parent="$4" w_other_kb=0 w_other_files=0 w_other_n=0 w_c w_label w_kb
  for w_c in "$w_dir"/* "$w_dir"/.[!.]* "$w_dir"/..?*; do
    [ -d "$w_c" ] || continue
    [ -L "$w_c" ] && continue
    if [ "$DUCALLS" -ge "$MAX_DUCALLS" ]; then
      TRUNCATED=1
      break
    fi
    label_of "${w_c##*/}" "$w_parent"
    w_label=$LABEL
    measure_kb "$w_c"
    w_kb=$KB
    if [ "$w_label" = '<other>' ]; then
      count_files "$w_c"
      w_other_kb=$((w_other_kb + w_kb))
      w_other_files=$((w_other_files + FILES))
      w_other_n=$((w_other_n + 1))
    else
      count_files "$w_c" mtime
      printf '%s\t%s\t%s\t%s\t1\n' "$w_prefix$w_label" "$w_kb" "$FILES" "$NEWEST" >> "$W/tree.tsv"
      if [ "$w_left" -gt 1 ]; then
        walk "$w_c" "$w_prefix$w_label/" $((w_left - 1)) "$w_label"
      fi
    fi
  done
  if [ "$w_other_n" -gt 0 ]; then
    printf '%s\t%s\t%s\t0\t%s\n' "${w_prefix}<other>" "$w_other_kb" "$w_other_files" "$w_other_n" >> "$W/tree.tsv"
  fi
}
if [ -n "$BIG_DIR" ]; then
  walk "$BIG_DIR" "" "$MAX_DEPTH" ""
fi
sort -t "$TAB" -k1,1 "$W/tree.tsv" > "$W/tree.sorted"
[ -s "$W/unreadable.txt" ] || : > "$W/unreadable.txt"

# 4. volume fill
df -Pk "$DATA" > "$W/df.out" 2> "$ERR" || die "df failed for the data volume: $(errsum)"
awk 'NR == 2 { print $2, $3, $5 }' "$W/df.out" > "$W/pair"
read -r NODE_SIZE_KB NODE_USED_KB NODE_PCT < "$W/pair"
NODE_PCT=${NODE_PCT%\%}
case $NODE_SIZE_KB$NODE_USED_KB$NODE_PCT in
  '' | *[!0-9]*) die "df gave no usable answer for the data volume" ;;
esac
NOMINAL_PCT=$((TOTAL_KB * 100 / PVC_NOMINAL_KIB))

# --- previous report and growth ---------------------------------------------------------------------------------
# State file format (tab separated): meta EPOCH DATE | bigcase HASH | total all KB FILES | top LABEL KB FILES |
# case HASH KB FILES | tree PATH KB FILES. Only hashes and allow-listed names are ever written.
{
  printf 'meta\t%s\t%s\n' "$NOW" "$(date -u -d "@$NOW" +%Y-%m-%d)"
  printf 'bigcase\t%s\n' "$BIG_KEY"
  printf 'total\tall\t%s\t%s\n' "$TOTAL_KB" "$TOTAL_FILES"
  awk -F "$TAB" '{ printf "top\t%s\t%s\t%s\n", $1, $2, $3 }' "$W/top.tsv"
  awk -F "$TAB" '{ printf "case\t%s/%s\t%s\t%s\n", $4, $2, $1, $3 }' "$W/cases.tsv"
  awk -F "$TAB" '{ printf "tree\t%s\t%s\t%s\n", $1, $2, $3 }' "$W/tree.tsv"
} | sort -t "$TAB" -k1,1 -k2,2 > "$W/state.new"

# deepest MIN: growth rows over MIN KiB, tree rows only when no deeper tree row below them also qualifies (one big
# file is one finding, not one per ancestor); the largest case's own row and the cases/ row are its ancestors too
deepest() {
  awk -F "$TAB" -v min="$1" -v big="$BIG_KEY" '
    $1 == "total" || $3 <= min { next }
    { n++; row[n] = $0; kind[n] = $1; key[n] = $2; if ($1 == "tree") nt++ }
    END {
      for (i = 1; i <= n; i++) {
        if (kind[i] == "tree") {
          skip = 0
          for (j = 1; j <= n; j++) if (j != i && kind[j] == "tree" && index(key[j], key[i] "/") == 1) { skip = 1; break }
          if (!skip) print row[i]
        } else if (!(nt && ((kind[i] == "case" && key[i] == big) || (kind[i] == "top" && key[i] == "cases")))) print row[i]
      }
    }' "$W/growth.tsv"
}

HAVE_PREV=0
PREV_NOTE=
PREV_DATE=
if [ -f "$STATE/last.tsv" ]; then
  if awk -F "$TAB" 'BEGIN { m = 0; t = 0 } $1 == "meta" && NF == 3 { m++ } $1 == "total" && NF == 4 { t++ } END { exit !(m == 1 && t == 1) }' "$STATE/last.tsv"; then
    HAVE_PREV=1
    PREV_DATE=$(awk -F "$TAB" '$1 == "meta" { print $3 }' "$STATE/last.tsv")
  else
    PREV_NOTE="the previous report's numbers could not be read (state file damaged), so this report is a new baseline"
  fi
else
  PREV_NOTE="no previous report on the state volume: this one is the baseline, growth shows from the next report"
fi

: > "$W/growth.tsv"
DTOT=0
DTOT_FILES=0
DTOT_PCT_X10=0
PCT=0.0
CRIT=0
: > "$W/reasons"
if [ "$HAVE_PREV" = 1 ]; then
  # kind, key, delta KiB, delta files, existed before (1/0); tree rows only when the largest case folder is the same
  awk -F "$TAB" '
    FNR == NR {
      if ($1 == "bigcase") pbig = $2
      else if ($1 != "meta") { k = $1 FS $2; pkb[k] = $3; pfi[k] = $4 }
      next
    }
    $1 == "bigcase" { cbig = $2; next }
    $1 == "meta" { next }
    { n++; row[n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        split(row[i], f, FS)
        k = f[1] FS f[2]
        if (f[1] == "tree" && cbig != pbig) continue
        printf "%s\t%s\t%d\t%d\t%d\n", f[1], f[2], f[3] - ((k in pkb) ? pkb[k] : 0), f[4] - ((k in pfi) ? pfi[k] : 0), (k in pkb) ? 1 : 0
      }
    }' "$STATE/last.tsv" "$W/state.new" > "$W/growth.tsv"
  awk -F "$TAB" '$1 == "total" { print $3, $4 }' "$W/growth.tsv" > "$W/pair"
  read -r DTOT DTOT_FILES < "$W/pair"
  PREV_TOTAL_KB=$((TOTAL_KB - DTOT))
  if [ "$PREV_TOTAL_KB" -gt 0 ]; then
    DTOT_PCT_X10=$((DTOT * 1000 / PREV_TOTAL_KB))
  fi
  PCT=$(awk -v x="$DTOT_PCT_X10" 'BEGIN { printf "%.1f", x / 10 }')
  if [ "$DTOT" -gt "$GROW_TOTAL_KIB" ]; then
    CRIT=1
    echo "/data grew $(human_signed "$DTOT") (limit $(human "$GROW_TOTAL_KIB"))" >> "$W/reasons"
  fi
  if [ "$PREV_TOTAL_KB" -gt 0 ] && [ $((DTOT * 100)) -gt $((PREV_TOTAL_KB * GROW_PCT)) ]; then
    CRIT=1
    echo "/data grew $PCT percent (limit $GROW_PCT percent)" >> "$W/reasons"
  fi
  deepest "$GROW_FOLDER_KIB" | awk -F "$TAB" '
    {
      lab = ($1 == "case") ? "case folder " $2 : (($1 == "top") ? "/data/" $2 : $2)
      printf "%s\t%d\n", lab, $3
    }' | sort > "$W/folder-reasons"
  while IFS="$TAB" read -r lab kb; do
    CRIT=1
    echo "$lab grew $(human_signed "$kb") (limit $(human "$GROW_FOLDER_KIB") for one folder)" >> "$W/reasons"
  done < "$W/folder-reasons"
fi

# tree rows with the newest file's date as text (label, KiB, files, epoch, day)
: > "$W/tree.disp"
while IFS="$TAB" read -r p kb nf ne _; do
  printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$kb" "$nf" "$ne" "$(fmt_day "$ne")" >> "$W/tree.disp"
done < "$W/tree.sorted"

# --- the report -------------------------------------------------------------------------------------------------
DAY=$(date -u -d "@$NOW" +%Y-%m-%d)
{
  echo "BlockOne storage report, $DAY (UTC)"
  echo "================================================="
  echo "Read-only. Folder names are never printed: case folders show as rank and a 6-character hash;"
  echo "folders below them show only if the app itself creates that name, otherwise as <other>."
  echo "Tools found:$FOUND"
  echo "Tools missing:${MISSING:- none}"
  if [ -n "$TOOL_NOTES" ]; then printf '%s\n' "$TOOL_NOTES" | sed '1d'; fi
  echo
  echo "1. Summary"
  echo "----------"
  awk -v total="$TOTAL_KB" -v nom="$PVC_NOMINAL_KIB" -v np="$NOMINAL_PCT" -v files="$TOTAL_FILES" -v ns="$NODE_SIZE_KB" \
    -v nu="$NODE_USED_KB" -v npct="$NODE_PCT" "$AWKFMT"'
    BEGIN {
      printf "%-34s %s\n", "Data volume in use (du of /data):", h(total) " in " files " files"
      printf "%-34s %s\n", "Volume nominal size (PVC):", h(nom) " (not enforced by local-path); in use is " np " percent of it"
      printf "%-34s %s\n", "Node filesystem holding it:", h(nu) " used of " h(ns) ", " npct " percent full"
    }'
  if [ "$HAVE_PREV" = 1 ]; then
    printf '%-34s %s (%s files), %s percent, since the report of %s\n' "Change since the last report:" \
      "$(human_signed "$DTOT")" "$DTOT_FILES" "$PCT" "$PREV_DATE"
  else
    printf '%-34s %s\n' "Change since the last report:" "none to compare: $PREV_NOTE"
  fi
  if [ "$CRIT" = 1 ]; then
    echo "GROWTH ALERT: limits crossed (severity critical):"
    sed 's/^/  - /' "$W/reasons"
  else
    echo "Growth limits ($GROW_PCT percent or $(human "$GROW_TOTAL_KIB") for /data, $(human "$GROW_FOLDER_KIB") for one folder): not crossed."
  fi
  if [ "$TRUNCATED" = 1 ]; then
    echo "NOTE: the folder tree was cut short at $MAX_DUCALLS measurements; deeper folders are missing from sections 4 and 5."
  fi
  echo

  echo "2. Top-level folders of /data"
  echo "-----------------------------"
  printf '%-26s %12s %10s %12s\n' "Folder" "Size" "Files" "Change"
  sort -t "$TAB" -k2,2nr "$W/top.tsv" | awk -F "$TAB" -v g="$W/growth.tsv" "$AWKFMT"'
    BEGIN { while ((getline line < g) > 0) { split(line, f, "\t"); if (f[1] == "top") d[f[2]] = f[3] } }
    { printf "%-26s %12s %10d %12s\n", $1, h($2), $3, ($1 in d) ? hs(d[$1]) : "-" }'
  printf '%-26s %12s %10d\n' "(files directly in /data)" "-" "$TOP_LOOSE"
  echo

  echo "3. /data/cases"
  echo "--------------"
  printf '%-26s %12s %10s\n' "App folder" "Size" "Files"
  sort "$W/appdirs.tsv" | awk -F "$TAB" "$AWKFMT"'{ printf "%-26s %12s %10d\n", $1, h($2), $3 }'
  printf '%-26s %12s %10d\n' "(files directly in cases)" "-" "$CASES_LOOSE"
  echo
  echo "Taxpayer folders: $NCASES, together $(human "$CASES_KB"). Each is cases/<account>/<taxpayer>, shown as the"
  echo "6-character hash of the account folder name (- when there is no account level) and of the taxpayer folder name."
  echo "The $TOP_N largest:"
  printf '%-6s %-8s %-8s %12s %10s %12s\n' "Rank" "Account" "Case" "Size" "Files" "Change"
  head -n "$TOP_N" "$W/cases.sorted" | awk -F "$TAB" -v g="$W/growth.tsv" "$AWKFMT"'
    BEGIN { while ((getline line < g) > 0) { split(line, f, "\t"); if (f[1] == "case") d[f[2]] = f[3] } }
    { k = $4 "/" $2; printf "#%-5d %-8s %-8s %12s %10d %12s\n", NR, $4, $2, h($1), $3, (k in d) ? hs(d[k]) : "-" }'
  awk -F "$TAB" -v n="$TOP_N" "$AWKFMT"'
    NR > n { r += $1; c++ } END { if (c > 0) printf "%-19s %12s   (%d more taxpayer folders)\n", "All the others:", h(r), c }' "$W/cases.sorted"
  echo

  echo "4. Inside the largest taxpayer folder (rank 1, account/case $BIG_KEY)"
  echo "------------------------------------------------------------"
  echo "Only app-created folder names are shown; any other name is counted in <other>."
  printf '%-48s %12s %10s %12s %12s\n' "Folder" "Size" "Files" "Newest file" "Change"
  awk -F "$TAB" -v g="$W/growth.tsv" "$AWKFMT"'
    BEGIN { while ((getline line < g) > 0) { split(line, f, "\t"); if (f[1] == "tree") d[f[2]] = f[3] } }
    { printf "%-48s %12s %10d %-12s %12s\n", $1, h($2), $3, $5, ($1 in d) ? hs(d[$1]) : "-" }' "$W/tree.disp"
  echo

  echo "5. The $TOP_N most recently changed app folders in the largest case folder"
  echo "------------------------------------------------------------------------"
  printf '%-48s %-12s %12s %10s\n' "Folder" "Newest file" "Size" "Files"
  awk -F "$TAB" '$4 > 0' "$W/tree.tsv" | sort -t "$TAB" -k4,4nr -k1,1 | head -n "$TOP_N" |
    while IFS="$TAB" read -r p kb nf ne _; do
      printf '%-48s %-12s %12s %10d\n' "$p" "$(fmt_day "$ne")" "$(human "$kb")" "$nf"
    done
  echo

  echo "6. Largest growth since the last report"
  echo "---------------------------------------"
  if [ "$HAVE_PREV" = 1 ]; then
    printf '%-48s %12s %12s\n' "Folder" "Change" "Files"
    deepest 0 | sort -t "$TAB" -k3,3nr -k2,2 | head -n "$TOP_N" |
      while IFS="$TAB" read -r kind key dkb dfi _; do
        case $kind in case) key="case folder $key" ;; top) key="/data/$key" ;; esac
        printf '%-48s %12s %12s\n' "$key" "$(human_signed "$dkb")" "$dfi"
      done
    echo "(Only folders that grew are listed. The largest case folder's own folders are compared only when it is the same"
    echo "case folder as last time.)"
  else
    echo "None yet: $PREV_NOTE."
  fi
  echo

  echo "7. Earlier reports (state volume)"
  echo "---------------------------------"
  if [ -s "$STATE/history.tsv" ]; then
    printf '%-12s %12s %12s %s\n' "Date" "Size" "Files" "Severity"
    tail -n 8 "$STATE/history.tsv" | awk -F "$TAB" "$AWKFMT"'{ printf "%-12s %12s %12d %s\n", $2, h($3), $4, $5 }'
  else
    echo "No earlier reports."
  fi
  echo

  echo "8. Latest backup archive"
  echo "------------------------"
  echo "Not available to this job: the archive is built in a scratch volume of the backup job and uploaded to R2, and"
  echo "reading either needs R2 keys or Kubernetes API access, which this job does not have by design."
  echo "Read it from the backup job's own log: the line for blockone-data-<stamp>.tar.gz in the 'archive' step (see"
  echo "docs/blockone-crypto-tax.md, Weekly storage report). Compare it with the size in section 1."
  echo
  echo "Tools: wrapper \"$PFX\" (empty: none available), $CMD_TIMEOUT s timeout per call, $DUCALLS tree measurements."
  if [ "$UNREADABLE" -gt 0 ]; then
    echo "UNREADABLE: $UNREADABLE measurement(s) hit entries that could not be read (permission denied or removed during the scan):"
    echo "the sizes for those folders are lower bounds. Reasons (no names):"
    sort "$W/unreadable.txt" | uniq -c | sed '/^ *[0-9]* *$/d; s/^/  /'
  fi
} | tee "$W/report.txt"

# --- the digest -------------------------------------------------------------------------------------------------
{
  if [ "$CRIT" = 1 ]; then
    echo "GROWTH: storage limits crossed"
    sed 's/^/- /' "$W/reasons"
  fi
  echo "BlockProof storage report $DAY (UTC)."
  echo "/data is $(human "$TOTAL_KB") in $TOTAL_FILES files; nominal volume $(human "$PVC_NOMINAL_KIB"): $NOMINAL_PCT percent used; node disk $NODE_PCT percent full."
  if [ "$HAVE_PREV" = 1 ]; then
    echo "Since $PREV_DATE: $(human_signed "$DTOT"), $DTOT_FILES files, $PCT percent."
    deepest 0 | sort -t "$TAB" -k3,3nr -k2,2 | head -n 3 |
      while IFS="$TAB" read -r kind key dkb dfi _; do
        case $kind in case) key="case $key" ;; top) key="/data/$key" ;; esac
        echo "Grew: $key $(human_signed "$dkb") ($dfi files)"
      done
  else
    echo "First report: baseline, no comparison yet."
  fi
  echo "Taxpayer folders: $NCASES, largest is rank 1 (account/case $BIG_KEY) at $(human "$BIG_KB")."
  if [ "$UNREADABLE" -gt 0 ]; then echo "Unreadable entries: $UNREADABLE measurement(s), sizes are lower bounds."; fi
  echo "Full report: kubectl --context homelab -n $NS logs job/$JOB"
} > "$W/digest.raw"
if [ "$CRIT" = 1 ]; then SEV=critical; else SEV=warning; fi
sed 's/<other>/(other)/g' "$W/digest.raw" | tr -cd 'A-Za-z0-9 _.,:;/%()+=#*\n-' > "$W/digest.txt"
SUMMARY=$(head -n 1 "$W/digest.txt")
if [ "$CRIT" = 1 ]; then
  SUMMARY="$SUMMARY: $(sed -n '2p' "$W/digest.txt" | sed 's/^- //')"
else
  if [ "$HAVE_PREV" = 1 ]; then
    SUMMARY="Weekly storage report $DAY: /data $(human "$TOTAL_KB"), $(human_signed "$DTOT") since $PREV_DATE"
  else
    SUMMARY="Weekly storage report $DAY: /data $(human "$TOTAL_KB") (first report, baseline)"
  fi
fi
SUMMARY=$(printf '%s' "$SUMMARY" | cut -c1-200)
DESC=$(awk 'NR > 0 { printf "%s%s", sep, $0; sep = "\\n" }' "$W/digest.txt")
ENDS=$(date -u -d "@$((NOW + ALERT_TTL))" +%Y-%m-%dT%H:%M:%SZ)
# every character in these strings passed the whitelist above (no quote, backslash or control character), so the JSON
# is built with printf
printf '[{"labels":{"alertname":"BlockOneStorageReport","severity":"%s","namespace":"%s"},"annotations":{"summary":"%s","description":"%s"},"endsAt":"%s"}]\n' \
  "$SEV" "$(printf '%s' "$NS" | tr -cd 'A-Za-z0-9-')" "$SUMMARY" "$DESC" "$ENDS" > "$W/alert.json"

echo "Digest for Telegram (severity $SEV):"
sed 's/^/  | /' "$W/digest.txt"

# --- deliver, then (only then) remember ------------------------------------------------------------------------
cr=0
"$CURL" -fsS --connect-timeout 5 --max-time 20 --retry 5 --retry-delay 5 --retry-all-errors \
  -H 'Content-Type: application/json' --data-binary @"$W/alert.json" -o "$W/am.out" "$ALERT_URL" || cr=$?
if [ "$cr" -ne 0 ]; then
  die "Alertmanager did not accept the alert (curl exit $cr); the report above is complete but nothing was sent and the state was NOT updated"
fi
echo "Alertmanager accepted the digest."

cp "$W/state.new" "$STATE/last.tsv.new" || die "cannot write the state volume"
mv "$STATE/last.tsv.new" "$STATE/last.tsv" || die "cannot write the state volume"
printf '%s\t%s\t%s\t%s\t%s\n' "$NOW" "$DAY" "$TOTAL_KB" "$TOTAL_FILES" "$SEV" >> "$STATE/history.tsv" || die "cannot write the state volume"
tail -n 60 "$STATE/history.tsv" > "$STATE/history.tsv.new" || die "cannot trim the history file"
mv "$STATE/history.tsv.new" "$STATE/history.tsv" || die "cannot trim the history file"
echo "State saved. Done."

#!/usr/bin/env bash
# Back up and restore a real Linkding with sample data, in Docker, with a throwaway restic repository.
# Nothing here touches the cluster or R2. Not part of validate.sh (it needs Docker). AI-assisted (Claude Code).
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
code=$PWD/apps/base/app-backup
linkding=$(grep -m1 -oE 'sissbruecker/linkding:[0-9.]+' apps/base/linkding/deployment.yaml)
restic=restic/restic:0.20.0@sha256:93999df80d4ac6cb148e82d2ef1fe6a81996f17ff535e772723538211b31555a

id="appbk-$$"
volumes=("$id-live" "$id-snap" "$id-repo" "$id-restore" "$id-code" "$id-scratch")
cleanup() {
  docker rm -f "$id-app" "$id-restored" > /dev/null 2>&1 || true # cleanup only: they may not exist
  docker volume rm -f "${volumes[@]}" > /dev/null
}
trap cleanup EXIT

passes=0
pass() { passes=$((passes + 1)); echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; exit 1; }
# must_fail "name" "expected text" command...
must_fail() {
  local name=$1 text=$2 out
  shift 2
  if out=$("$@" 2>&1); then fail "$name: succeeded but should fail"; fi
  grep -qF -- "$text" <<< "$out" || fail "$name: failed for another reason: $(tail -3 <<< "$out")"
  pass "$name"
}

# Throwaway credentials, generated per run and never printed.
export TEST_USER=backup-test
TEST_PASS=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
RESTIC_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
export TEST_PASS RESTIC_PASSWORD

for v in "${volumes[@]}"; do docker volume create "$v" > /dev/null; done
tar -C "$code" -cf - . | docker run --rm -i -v "$id-code:/code" --entrypoint tar "$linkding" -C /code -xf -
docker run --rm --user 0 --entrypoint chown -v "$id-snap:/a" -v "$id-repo:/b" -v "$id-restore:/c" -v "$id-scratch:/d" \
  "$linkding" 33:33 /a /b /c /d

# Same user as the cluster's pods (www-data, 33).
py() { docker run --rm --user 33:33 -v "$id-code:/code:ro" -v "$id-live:/live" -v "$id-snap:/snap" \
  -v "$id-restore:/restore" -v "$id-scratch:/scratch" -e PYTHONDONTWRITEBYTECODE=1 --entrypoint "$1" "$linkding" "${@:2}"; }
rst() { docker run --rm --user 33:33 -v "$id-code:/code:ro" -v "$id-snap:/snap:ro" -v "$id-repo:/repo" \
  -v "$id-restore:/restore" -e RESTIC_PASSWORD -e RESTIC_REPOSITORY=/repo -e BACKUP_APP=linkding \
  -e SNAPSHOT_DIR=/snap --entrypoint "$1" "$restic" "${@:2}"; }
start_app() { # name volume
  docker run -d --name "$1" -v "$2:/etc/linkding/data" -e LD_SUPERUSER_NAME="$TEST_USER" \
    -e LD_SUPERUSER_PASSWORD="$3" "$linkding" > /dev/null
  for _ in $(seq 1 90); do
    docker exec "$1" python -c 'import urllib.request as u; u.urlopen("http://127.0.0.1:9090/health", timeout=2)' \
      > /dev/null 2>&1 && return 0
    sleep 1
  done
  docker logs "$1" 2>&1 | tail -20 >&2
  fail "$1 did not become healthy"
}
add_bookmarks() { # container prefix count
  docker exec -i -e PREFIX="$2" -e COUNT="$3" "$1" python manage.py shell > /dev/null <<'PY'
import os
from django.contrib.auth.models import User
from django.utils import timezone
from bookmarks.models import Bookmark
owner = User.objects.get(username="backup-test")
for i in range(int(os.environ["COUNT"])):
    now = timezone.now()
    Bookmark.objects.create(url=f"https://example.com/{os.environ['PREFIX']}/{i}", title=f"{os.environ['PREFIX']}-{i}",
                            owner=owner, date_added=now, date_modified=now)
PY
}

echo "== Sample app"
start_app "$id-app" "$id-live" "$TEST_PASS"
add_bookmarks "$id-app" saved 120
docker exec "$id-app" sh -c 'mkdir -p /etc/linkding/data/assets && echo sample-asset > /etc/linkding/data/assets/sample.txt && chown -R www-data:www-data /etc/linkding/data/assets'

echo "== Snapshot while the app is running and writing"
add_bookmarks "$id-app" during 200 &
writer=$!
py python /code/snapshot.py /code/linkding.json /live /snap
wait "$writer"
pass "snapshot of a live database"
saved=$(py python -c 'import json; print(json.load(open("/snap/manifest.json"))["counts"]["bookmarks"])')
[ "$saved" -ge 120 ] || fail "manifest has only $saved bookmarks"

echo "== Backup"
rst restic --no-cache init > /dev/null
rst sh /code/backup.sh > /dev/null
pass "backup.sh: upload, retention, full read-back"
add_bookmarks "$id-app" after-backup 5

echo "== Restore into a separate volume and start the app from it"
rst restic --no-cache restore latest --host linkding --target /restore > /dev/null
py python /code/verify.py /code/linkding.json /restore
pass "restored data matches the manifest"
# A different superuser password: logging in with the saved one proves the account came from the backup.
start_app "$id-restored" "$id-restore" "not-the-saved-password-$$"
restored=$(docker exec -i -e TEST_USER -e TEST_PASS -e SAVED="$saved" "$id-restored" python - <<'PY'
import http.cookiejar, os, re, urllib.parse, urllib.request
base = "http://127.0.0.1:9090"
jar = http.cookiejar.CookieJar()
web = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
page = web.open(base + "/login/", timeout=10).read().decode()
csrf = re.search(r'name="csrfmiddlewaretoken" value="([^"]+)"', page).group(1)
body = urllib.parse.urlencode({"csrfmiddlewaretoken": csrf, "username": os.environ["TEST_USER"],
                               "password": os.environ["TEST_PASS"]}).encode()
web.open(urllib.request.Request(base + "/login/", data=body, headers={"Referer": base + "/login/"}), timeout=10)
listing = web.open(base + "/bookmarks?q=saved-119", timeout=10)
assert "/login" not in listing.url, "login with the saved password failed"
assert "saved-119" in listing.read().decode(), "saved bookmark not on the page"
print("ok")
PY
)
[ "$restored" = ok ] || fail "restored app check printed: $restored"
pass "restored app: saved login works and a saved bookmark is shown"
count=$(docker exec "$id-restored" python -c 'import sqlite3; d=sqlite3.connect("/etc/linkding/data/db.sqlite3"); print(d.execute("select count(*) from bookmarks_bookmark").fetchone()[0], d.execute("select count(*) from bookmarks_bookmark where title like \"after-backup-%\"").fetchone()[0])')
[ "$count" = "$saved 0" ] || fail "restored app has '$count', expected '$saved 0'"
pass "restored app has exactly the $saved saved bookmarks and none added afterwards"
asset=$(docker exec "$id-restored" cat /etc/linkding/data/assets/sample.txt)
[ "$asset" = sample-asset ] || fail "asset file not restored"
pass "asset file restored"
docker rm -f "$id-restored" > /dev/null

echo "== Retention: 35 days"
age() { date -u -d "$1 days ago" '+%Y-%m-%d %H:%M:%S'; }
for days in 60 40 30; do
  rst restic --no-cache backup /snap/secretkey.txt --host linkding --tag nightly --time "$(age "$days")" > /dev/null
done
dates() { rst restic --no-cache snapshots --json --host linkding | python3 -c 'import json,sys; print(*sorted(s["time"][:10] for s in json.load(sys.stdin)))'; }
rst sh /code/backup.sh > /dev/null
kept=$(dates)
for days in 60 40; do
  ! grep -qF "$(age "$days" | cut -c1-10)" <<< "$kept" || fail "$days-day-old backup was kept: $kept"
done
grep -qF "$(age 30 | cut -c1-10)" <<< "$kept" || fail "30-day-old backup was removed: $kept"
pass "backups older than 35 days are removed, a 30-day-old one is kept"
# Backups that stopped 100 days ago must not age away: the window counts back from the newest one.
for days in 130 100; do
  rst restic --no-cache backup /snap/secretkey.txt --host stopped --tag nightly --time "$(age "$days")" > /dev/null
done
rst restic --no-cache forget --host stopped --tag nightly --group-by host,tags --keep-within 35d > /dev/null
left=$(rst restic --no-cache snapshots --json --host stopped | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$left" = 2 ] || fail "stopped backups: $left of 2 left"
pass "old backups survive when no newer ones are being made"

echo "== Failures must be reported"
must_fail "snapshot into a non-empty folder" "destination is not empty" py python /code/snapshot.py /code/linkding.json /live /snap
py sh -c 'mkdir /scratch/nokey && cp /live/db.sqlite3 /scratch/nokey/'
must_fail "missing secret key" "required data is missing: secretkey.txt" py python /code/snapshot.py /code/linkding.json /scratch/nokey /scratch/out1
py sh -c 'mkdir /scratch/empty && echo k > /scratch/empty/secretkey.txt && python -c "
import sqlite3
d = sqlite3.connect(\"/scratch/empty/db.sqlite3\")
d.execute(\"create table bookmarks_bookmark(id)\"); d.execute(\"create table auth_user(id)\"); d.commit()"'
must_fail "new, empty database" "users: found 0, expected at least 1" py python /code/snapshot.py /code/linkding.json /scratch/empty /scratch/out2
py sh -c 'mkdir /scratch/bad && echo k > /scratch/bad/secretkey.txt && echo "this is not a database" > /scratch/bad/db.sqlite3'
must_fail "broken database" "snapshot FAILED" py python /code/snapshot.py /code/linkding.json /scratch/bad /scratch/out3
must_fail "backup of an unfinished snapshot" "the snapshot did not finish" \
  docker run --rm -v "$id-code:/code:ro" -e BACKUP_APP=linkding -e SNAPSHOT_DIR=/nowhere --entrypoint sh "$restic" /code/backup.sh
fresh_copy() { py sh -c 'rm -rf /scratch/copy && cp -a /snap /scratch/copy'; }
fresh_copy && py sh -c 'echo changed > /scratch/copy/assets/sample.txt'
must_fail "changed file" "checksum differs: assets/sample.txt" py python /code/verify.py /code/linkding.json /scratch/copy
fresh_copy && py rm /scratch/copy/secretkey.txt
must_fail "missing file" "file list differs" py python /code/verify.py /code/linkding.json /scratch/copy
fresh_copy && py python -c 'import json; p="/scratch/copy/manifest.json"; m=json.load(open(p)); m["counts"]["bookmarks"]+=1; json.dump(m, open(p,"w"))'
must_fail "row count differs" "bookmarks: restored" py python /code/verify.py /code/linkding.json /scratch/copy
good_password=$RESTIC_PASSWORD
RESTIC_PASSWORD=wrong-password
must_fail "wrong repository password" "wrong password" rst restic --no-cache snapshots
RESTIC_PASSWORD=$good_password
# Flip bytes in the largest stored pack: the nightly full read-back must notice.
# shellcheck disable=SC2016 # expands inside the container
rst sh -c 'f=$(find /repo/data -type f -exec ls -S {} + | head -1); chmod u+w "$f"; printf "XXXXXXXX" | dd of="$f" bs=1 seek=200 conv=notrunc 2>/dev/null'
must_fail "damaged backup file" "Fatal" rst restic --no-cache check --read-data
rst sh -c 'rm -rf /repo/*'
must_fail "missing repository is not silently created" "repository does not exist" rst sh /code/backup.sh

echo "All $passes checks passed."

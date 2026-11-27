#!/usr/bin/env bash
# Back up and restore a real Forgejo with a pushed repository, in Docker, with a throwaway restic repository, and
# check that the pause for the backup always ends. Nothing here touches the cluster or R2. AI-assisted.
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
forgejo=$(grep -m1 -oE 'codeberg.org/forgejo/forgejo:[^ ]+' apps/base/forgejo/deployment.yaml)
python=$(grep -m1 -oE 'sissbruecker/linkding:[0-9.]+' apps/staging/linkding/backup.yaml) # the snapshot image
restic=restic/restic:0.20.0@sha256:93999df80d4ac6cb148e82d2ef1fe6a81996f17ff535e772723538211b31555a

id="fjbk-$$"
volumes=("$id-data" "$id-snap" "$id-repo" "$id-restore" "$id-code")
work=$(mktemp -d)
cleanup() {
  docker rm -f "$id-app" "$id-restored" "$id-job" > /dev/null 2>&1 || true # cleanup only: they may not exist
  docker volume rm -f "${volumes[@]}" > /dev/null
  rm -rf "$work"
}
trap cleanup EXIT
passes=0
pass() { passes=$((passes + 1)); echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; docker logs "$id-app" 2>&1 | tail -15 >&2 || true; exit 1; }

RESTIC_PASSWORD=$(openssl rand -hex 16)
export RESTIC_PASSWORD
user_password=$(openssl rand -hex 16)

for v in "${volumes[@]}"; do docker volume create "$v" > /dev/null; done
tar -C apps/base/app-backup -cf - . | docker run --rm -i -v "$id-code:/code" --entrypoint tar "$python" -C /code -xf -
tar -C apps/base/forgejo -cf - supervise.sh | docker run --rm -i -v "$id-code:/code" --entrypoint tar "$python" -C /code -xf -
docker run --rm --user 0 --entrypoint chown -v "$id-data:/a" -v "$id-snap:/b" -v "$id-repo:/c" -v "$id-restore:/d" \
  "$python" 1000:1000 /a /b /c /d

sleep1() { sleep 1; }
start_app() { # name data-volume port
  docker run -d --name "$1" --user 1000:1000 --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp:uid=1000,gid=1000,mode=0770 --env-file apps/base/forgejo/forgejo.env -v "$2:/var/lib/gitea" \
    -v "$id-code:/supervise:ro" -p "127.0.0.1:$3:3000" "$forgejo" \
    sh /supervise/supervise.sh /usr/local/bin/gitea -c /var/lib/gitea/custom/conf/app.ini web > /dev/null
  wait_healthy "$1" "$3"
}
healthy() { curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$1/api/healthz" 2> /dev/null; }
wait_healthy() { for _ in $(seq 1 90); do healthy "$2" && return 0; sleep1; done; docker logs "$1" 2>&1 | tail -15 >&2; fail "$1 did not become healthy"; }
# The live liveness command, run in the container
liveness() { docker exec "$1" sh -c "$(sed -n 's/^ *command: \[sh, -c, "\(.*\)"\]$/\1/p' apps/base/forgejo/deployment.yaml)"; }
vol() { docker run --rm --user 1000:1000 -v "$id-code:/code:ro" -v "$id-data:/data" -v "$id-snap:/snap" \
  -v "$id-restore:/restore" -e PYTHONDONTWRITEBYTECODE=1 --entrypoint "$1" "$python" "${@:2}"; }
quiesce() { # spec dest [extra docker args]
  docker run --rm --name "$id-job" --user 1000:1000 -v "$id-code:/code:ro" -v "$id-data:/data" -v "$id-snap:/snap" \
    -e PYTHONDONTWRITEBYTECODE=1 "${@:3}" --entrypoint python "$python" /code/quiesce.py "$1" /data "$2"; }
rst() { docker run --rm --user 1000:1000 -v "$id-code:/code:ro" -v "$id-snap:/snap:ro" -v "$id-repo:/repo" \
  -v "$id-restore:/restore" -e RESTIC_PASSWORD -e RESTIC_REPOSITORY=/repo -e BACKUP_APP=forgejo \
  -e SNAPSHOT_DIR=/snap/good --entrypoint "$1" "$restic" "${@:2}"; }
gitc() { git -c credential.helper= -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@git.home.arpa \
  -c http.extraHeader="Authorization: Basic $(printf 'tester:%s' "$user_password" | base64 -w0)" "$@"; }
no_request() { vol sh -c 'test ! -e /data/backup-control/pause-request'; }

echo "== A real Forgejo under the wrapper, with a pushed repository"
start_app "$id-app" "$id-data" 13100
liveness "$id-app" || fail "liveness command fails on a healthy app"
pass "starts under the wrapper; the liveness command succeeds"
docker exec "$id-app" forgejo admin user create --admin --username tester --email tester@git.home.arpa \
  --password "$user_password" --must-change-password=false > /dev/null
curl -fsS -u "tester:$user_password" -H 'Content-Type: application/json' -d '{"name":"demo","private":true}' \
  http://127.0.0.1:13100/api/v1/user/repos > /dev/null
gitc init -q -b main "$work/src"
echo saved > "$work/src/a.txt"
gitc -C "$work/src" add a.txt
gitc -C "$work/src" commit -qm "test: saved"
gitc -C "$work/src" push -q http://127.0.0.1:13100/tester/demo.git main
saved=$(gitc -C "$work/src" rev-parse HEAD)

echo "== Paused snapshot, upload, restore"
: > "$work/probe"
(for _ in $(seq 1 600); do if healthy 13100; then s=up; else s=down; fi; echo "$(date +%s%N) $s" >> "$work/probe"; [ -e "$work/stop" ] && break; sleep 0.2; done) &
probe=$!
quiesce /code/forgejo.json /snap/good || fail "paused snapshot failed"
wait_healthy "$id-app" 13100
sleep 1; touch "$work/stop"; wait "$probe"
grep -q ' down$' "$work/probe" || fail "Forgejo was never seen offline, so the pause isn't proven"
offline=$(awk '$2=="down"{if(!a)a=$1;b=$1} END{printf "%.1f",(b-a)/1e9}' "$work/probe")
pass "snapshot taken while stopped; Forgejo came back (seen offline for about ${offline}s here)"
no_request || fail "the pause request was left behind"
logs=$(docker logs "$id-app" 2>&1) # not piped into grep -q: with pipefail an early match can look like a failure
grep -qF 'backup pause: Forgejo is stopped' <<< "$logs" || fail "no stop acknowledgement in the log"
pass "the pause request was removed"
rst restic --no-cache init > /dev/null
rst sh /code/backup.sh > /dev/null
pass "backup.sh: upload, retention, full read-back"

echo later >> "$work/src/a.txt"
gitc -C "$work/src" commit -qam "test: after the backup"
gitc -C "$work/src" push -q http://127.0.0.1:13100/tester/demo.git main
rst restic --no-cache restore latest --host forgejo --target /restore > /dev/null
vol python /code/verify.py /code/forgejo.json /restore
pass "restored data matches the manifest"
docker rm -f "$id-app" > /dev/null
start_app "$id-restored" "$id-restore" 13101
gitc clone -q http://127.0.0.1:13101/tester/demo.git "$work/clone"
[ "$(gitc -C "$work/clone" rev-parse HEAD)" = "$saved" ] || fail "the restored repository is at a different commit"
gitc -C "$work/clone" fsck --full --no-progress > /dev/null || fail "the cloned repository is damaged"
pass "restored Forgejo: same sign-in works, the clone is at the saved commit, not the later one"
docker rm -f "$id-restored" > /dev/null

echo "== The pause must always end"
start_app "$id-app" "$id-data" 13100
printf '{"databases":["data/forgejo.db"],"paths":[],"required":["does-not-exist"],"counts":{}}' |
  docker run --rm -i --user 1000:1000 -v "$id-snap:/snap" --entrypoint sh "$python" -c 'cat > /snap/bad.json'
vol sh -c 'rm -rf /snap/good /snap/x'
if out=$(quiesce /snap/bad.json /snap/x 2>&1); then fail "a broken snapshot was reported as good"; fi
grep -qF "required data is missing" <<< "$out" || fail "failed for another reason: $out"
wait_healthy "$id-app" 13100
no_request || fail "request left behind after a failed snapshot"
pass "failed snapshot: reported, request removed, Forgejo running again"

# A job that dies without cleaning up: only the request's expiry can bring Forgejo back
# shellcheck disable=SC2016 # expands inside the container, on its clock
vol sh -c 'echo "$(($(date +%s) + 20)) deadjob" > /data/backup-control/pause-request'
for _ in $(seq 1 15); do healthy 13100 || break; sleep1; done
if healthy 13100; then fail "did not pause for a valid request"; fi
# The port closes a moment before Forgejo has exited and the wrapper has confirmed it
for _ in $(seq 1 15); do vol test -e /data/backup-control/paused && break; sleep1; done
vol test -e /data/backup-control/paused || fail "the stop was never confirmed"
liveness "$id-app" || fail "liveness would restart the container during a pause"
pass "during a pause the liveness command succeeds"
wait_healthy "$id-app" 13100
pass "abandoned request: Forgejo started again when it expired"

# shellcheck disable=SC2016 # expands inside the container, on its clock
vol sh -c 'echo "$(($(date +%s) + 86400)) farfuture" > /data/backup-control/pause-request'
sleep 5
healthy 13100 || fail "paused for a request a day ahead"
vol sh -c 'echo "garbage;rm -rf /" > /data/backup-control/pause-request'
sleep 3
healthy 13100 || fail "paused for a malformed request"
vol sh -c 'rm /data/backup-control/pause-request'
pass "a far-future or malformed request is ignored"

docker stop -t 30 "$id-app" > /dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$id-app")" = 0 ] || fail "unclean stop"
logs=$(docker logs "$id-app" 2>&1)
grep -qF 'Forgejo stopped (0)' <<< "$(tail -3 <<< "$logs")" || fail "Forgejo did not exit cleanly on stop"
pass "stopping the container stops Forgejo cleanly"
if out=$(quiesce /code/forgejo.json /snap/x -e ACK_SECONDS=5 2>&1); then fail "snapshot of an app that never acknowledged"; fi
grep -qF "did not stop within 5 seconds" <<< "$out" || fail "failed for another reason: $out"
no_request || fail "request left behind"
pass "app not running: no snapshot, no request left behind"

docker start "$id-app" > /dev/null
wait_healthy "$id-app" 13100
docker exec "$id-app" sh -c 'kill -KILL $(pgrep -f "gitea -c .* web$" | tail -1)'
for _ in $(seq 1 20); do [ "$(docker inspect -f '{{.State.Running}}' "$id-app")" = false ] && break; sleep1; done
[ "$(docker inspect -f '{{.State.Running}}' "$id-app")" = false ] || fail "container kept running after Forgejo died"
[ "$(docker inspect -f '{{.State.ExitCode}}' "$id-app")" != 0 ] || fail "a crash was reported as success"
pass "a crashed Forgejo ends the container with an error, so Kubernetes restarts it"

echo "All $passes checks passed."

#!/usr/bin/env bash
# Back up and restore a real Audiobookshelf with sample data, in Docker, with a throwaway restic repository.
# The shared failure cases are in test-app-backup.sh. Nothing here touches the cluster or R2. AI-assisted.
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
code=$PWD/apps/base/app-backup
abs=$(grep -m1 -oE 'ghcr.io/advplyr/audiobookshelf:[0-9.]+' apps/base/audiobookshelf/deployment.yaml)
python=$(grep -m1 -oE 'sissbruecker/linkding:[0-9.]+' apps/staging/linkding/backup.yaml) # the snapshot image
restic=restic/restic:0.20.0@sha256:93999df80d4ac6cb148e82d2ef1fe6a81996f17ff535e772723538211b31555a

id="absbk-$$"
volumes=("$id-config" "$id-metadata" "$id-snap" "$id-repo" "$id-restore" "$id-code" "$id-scratch")
cleanup() {
  docker rm -f "$id-app" "$id-restored" > /dev/null 2>&1 || true # cleanup only: they may not exist
  docker volume rm -f "${volumes[@]}" > /dev/null
}
trap cleanup EXIT
passes=0
pass() { passes=$((passes + 1)); echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; exit 1; }

TEST_PASS=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
RESTIC_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
export TEST_PASS RESTIC_PASSWORD

for v in "${volumes[@]}"; do docker volume create "$v" > /dev/null; done
tar -C "$code" -cf - . | docker run --rm -i -v "$id-code:/code" --entrypoint tar "$python" -C /code -xf -
docker run --rm --user 0 --entrypoint chown -v "$id-config:/a" -v "$id-metadata:/b" -v "$id-snap:/c" -v "$id-repo:/d" \
  -v "$id-restore:/e" -v "$id-scratch:/f" "$python" 1000:1000 /a /b /c /d /e /f

# Same user as the cluster's pods (node, 1000).
py() { docker run --rm --user 1000:1000 -v "$id-code:/code:ro" -v "$id-config:/data/config" -v "$id-metadata:/data/metadata" \
  -v "$id-snap:/snap" -v "$id-restore:/restore" -v "$id-scratch:/scratch" -e PYTHONDONTWRITEBYTECODE=1 \
  --entrypoint "$1" "$python" "${@:2}"; }
rst() { docker run --rm --user 1000:1000 -v "$id-code:/code:ro" -v "$id-snap:/snap:ro" -v "$id-repo:/repo" \
  -v "$id-restore:/restore" -e RESTIC_PASSWORD -e RESTIC_REPOSITORY=/repo -e BACKUP_APP=audiobookshelf \
  -e SNAPSHOT_DIR=/snap --entrypoint "$1" "$restic" "${@:2}"; }
start_app() { # name config-mount metadata-mount
  docker run -d --name "$1" --user 1000:1000 -e PORT=3005 -v "$2:/config" -v "$3:/metadata" "$abs" > /dev/null
  for _ in $(seq 1 90); do
    docker exec "$1" node -e 'fetch("http://127.0.0.1:3005/healthcheck").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))' \
      > /dev/null 2>&1 && return 0
    sleep 1
  done
  docker logs "$1" 2>&1 | tail -20 >&2
  fail "$1 did not become healthy"
}
# Run JavaScript in the app's container. api(path, body, token) returns the parsed JSON and throws on an error status.
js() { # container script
  docker exec -i -e TEST_PASS "$1" node - <<JS
async function api(path, body, token) {
  const r = await fetch("http://127.0.0.1:3005" + path, { method: body ? "POST" : "GET",
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: "Bearer " + token } : {}) },
    body: body ? JSON.stringify(body) : undefined });
  const text = await r.text();
  if (!r.ok) throw new Error(path + " " + r.status + " " + text.slice(0, 200));
  try { return JSON.parse(text); } catch { return text; }
}
const login = async () => { const u = (await api("/login", { username: "backup-test", password: process.env.TEST_PASS })).user;
  return u.accessToken || u.token; };
(async () => { $2 })().catch(e => { console.error(String(e)); process.exit(1); });
JS
}

echo "== Sample app"
start_app "$id-app" "$id-config" "$id-metadata"
js "$id-app" 'await api("/init", { newRoot: { username: "backup-test", password: process.env.TEST_PASS } });
  const t = await login();
  await api("/api/libraries", { name: "saved-library", mediaType: "book", folders: [{ fullPath: "/tmp" }] }, t);
  await api("/api/users", { username: "second-user", password: "second-" + process.env.TEST_PASS, type: "user" }, t);'
docker exec "$id-app" sh -c 'mkdir -p /metadata/items/sample && echo sample-cover > /metadata/items/sample/cover.txt'

echo "== Snapshot while the app is running, then back up"
py python /code/snapshot.py /code/audiobookshelf.json /data /snap
pass "snapshot of the running app"
rst restic --no-cache init > /dev/null
rst sh /code/backup.sh > /dev/null
pass "backup.sh: upload, retention, full read-back"
js "$id-app" 'const t = await login(); await api("/api/libraries", { name: "after-backup", mediaType: "book", folders: [{ fullPath: "/tmp" }] }, t);'

echo "== Restore and start a second app from it"
rst restic --no-cache restore latest --host audiobookshelf --target /restore > /dev/null
py python /code/verify.py /code/audiobookshelf.json /restore
pass "restored data matches the manifest"
# The snapshot holds config/ and metadata/ side by side; the app wants them as two mounts.
py sh -c 'mkdir -p /scratch/config /scratch/metadata && cp -a /restore/config/. /scratch/config/ && cp -a /restore/metadata/. /scratch/metadata/'
mountpoint=$(docker volume inspect -f '{{.Mountpoint}}' "$id-scratch")
docker rm -f "$id-app" > /dev/null
start_app "$id-restored" "$mountpoint/config" "$mountpoint/metadata"
out=$(js "$id-restored" 'const t = await login(); const l = await api("/api/libraries", null, t); const u = await api("/api/users", null, t);
  console.log(l.libraries.map(x => x.name).sort().join(",") + " | " + u.users.map(x => x.username).sort().join(","));')
[ "$out" = "saved-library | backup-test,second-user" ] || fail "restored app shows: $out"
pass "restored app: saved login works, shows the saved library and both users, not the later library"
[ "$(docker exec "$id-restored" cat /metadata/items/sample/cover.txt)" = sample-cover ] || fail "metadata file not restored"
pass "metadata file restored"

echo "== A new, never set up app must not be saved as a good backup"
docker rm -f "$id-restored" > /dev/null
py sh -c 'rm -rf /data/config/* /data/metadata/*'
start_app "$id-app" "$id-config" "$id-metadata"
py sh -c 'rm -rf /scratch/out'
if out=$(py python /code/snapshot.py /code/audiobookshelf.json /data /scratch/out 2>&1); then fail "accepted an empty app"; fi
grep -qF "users: found 0, expected at least 1" <<< "$out" || fail "failed for another reason: $out"
pass "app with no users is refused"

echo "All $passes checks passed."

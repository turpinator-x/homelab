#!/bin/sh
# Runs Forgejo, and stops it while a backup asks for a pause (docs/forgejo.md). A backup needs Forgejo offline so its
# database and repositories match. The request is a file on the data volume, so the backup job needs no cluster
# access. A request expires by itself: a backup job that dies can't leave Forgejo stopped. AI-assisted (Claude Code).
#   $CONTROL_DIR/pause-request  "<expiry, seconds since 1970> <token>", written by quiesce.py
#   $CONTROL_DIR/paused         "<token>", written here once Forgejo has exited cleanly
set -eu

CONTROL_DIR=${CONTROL_DIR:-/var/lib/gitea/backup-control}
MAX_PAUSE=900 # a request further ahead than this is ignored

mkdir -p "$CONTROL_DIR"
rm -f "$CONTROL_DIR/paused"
pid=''
stopping=''

# Sets token when there is a request that is still valid.
requested() {
  token=''
  [ -f "$CONTROL_DIR/pause-request" ] || return 1
  expiry='' wanted=''
  read -r expiry wanted < "$CONTROL_DIR/pause-request" || [ -n "$wanted" ] || return 1
  case $expiry in '' | *[!0-9]*) return 1 ;; esac
  case $wanted in '' | *[!A-Za-z0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ "$expiry" -gt "$now" ] && [ "$expiry" -le $((now + MAX_PAUSE)) ] || return 1
  token=$wanted
}

running() { [ -n "$pid" ] && kill -0 "$pid" 2> /dev/null; }

trap 'stopping=1' TERM INT

while [ -z "$stopping" ]; do
  if requested; then
    if [ -n "$pid" ]; then
      echo "backup pause: stopping Forgejo"
      kill -TERM "$pid" 2> /dev/null || echo "backup pause: Forgejo had already exited"
      status=0
      wait "$pid" || status=$?
      pid=''
      [ -z "$stopping" ] || break
      # An unclean exit is not acknowledged: leave, and let Kubernetes restart the container.
      if [ "$status" -ne 0 ]; then
        echo "backup pause: Forgejo exited with $status" >&2
        exit "$status"
      fi
    fi
    if [ "$(cat "$CONTROL_DIR/paused" 2> /dev/null || true)" != "$token" ]; then # no file yet is expected
      printf '%s\n' "$token" > "$CONTROL_DIR/paused.tmp"
      mv "$CONTROL_DIR/paused.tmp" "$CONTROL_DIR/paused"
      echo "backup pause: Forgejo is stopped"
    fi
  else
    if [ -z "$pid" ]; then
      rm -f "$CONTROL_DIR/paused"
      "$@" &
      pid=$!
      echo "started Forgejo"
    elif ! running; then
      status=0
      wait "$pid" || status=$?
      [ -z "$stopping" ] || { pid=''; break; }
      echo "Forgejo exited by itself with $status" >&2
      [ "$status" -ne 0 ] || status=1
      exit "$status"
    fi
  fi
  sleep 1 &
  wait $! || true # a signal interrupts the wait
done

rm -f "$CONTROL_DIR/paused"
if [ -n "$pid" ]; then
  kill -TERM "$pid" 2> /dev/null || echo "Forgejo had already exited"
  status=0
  wait "$pid" || status=$?
  # A signal can interrupt wait while Forgejo is still shutting down.
  while running; do
    status=0
    wait "$pid" || status=$?
  done
  echo "Forgejo stopped ($status)"
fi
exit 0

#!/usr/bin/env python3
"""Pause an app, take a snapshot of its data while it is stopped, and let it start again.

Used for Forgejo, whose database and repositories only match while it is offline. supervise.sh in the app's
container does the stopping. The request expires by itself, and is removed whether the snapshot works or not.
Standard library only. AI-assisted (Claude Code).

Usage: quiesce.py SPEC.json SOURCE_DIR EMPTY_DEST_DIR
Environment: PAUSE_SECONDS (longest pause, default 600), ACK_SECONDS (wait for the app to stop, default 90).
"""

import json
import os
import secrets
import signal
import sqlite3
import shutil
import sys
import time
from pathlib import Path

from snapshot import BackupError, snapshot

CONTROL = "backup-control"


def read(path):
    try:
        return path.read_text().strip()
    except FileNotFoundError:
        return ""


def active_request(path):
    fields = read(path).split()
    return len(fields) == 2 and fields[0].isdigit() and int(fields[0]) > time.time()


def quiesce(spec, source, dest, pause_seconds, ack_seconds):
    control = source / CONTROL
    if not control.is_dir():
        raise BackupError(f"{CONTROL} not found: is the app running with supervise.sh?")
    request, paused = control / "pause-request", control / "paused"
    if active_request(request):
        raise BackupError("another pause is already in progress")

    token = secrets.token_hex(16)
    expiry = int(time.time()) + pause_seconds
    started = time.monotonic()
    try:
        temporary = control / "pause-request.tmp"
        temporary.write_text(f"{expiry} {token}\n")
        temporary.replace(request)
        while read(paused) != token:
            if time.monotonic() - started > ack_seconds:
                raise BackupError(f"the app did not stop within {ack_seconds} seconds")
            time.sleep(0.5)
        counts, total = snapshot(spec, source, dest)
        # If the pause ran out while copying, the app may have started again and changed files.
        if time.time() >= expiry or read(paused) != token:
            raise BackupError("the pause ended before the copy finished, so the copy can't be trusted")
    finally:
        if read(request).endswith(token):
            request.unlink()
    return counts, total, time.monotonic() - started


def stop(signum, frame):
    raise BackupError("stopped by a signal")


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    signal.signal(signal.SIGTERM, stop)  # so that a deleted job still removes its request
    spec = json.loads(Path(argv[1]).read_text())
    try:
        counts, total, seconds = quiesce(
            spec,
            Path(argv[2]),
            Path(argv[3]),
            int(os.environ.get("PAUSE_SECONDS", "600")),
            int(os.environ.get("ACK_SECONDS", "90")),
        )
    except (BackupError, OSError, ValueError, sqlite3.Error, shutil.Error) as error:
        print(f"snapshot FAILED: {error}", file=sys.stderr)
        return 1
    print(f"snapshot ok: {total} files, counts {counts}; pause requested for {seconds:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

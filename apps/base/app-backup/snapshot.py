#!/usr/bin/env python3
"""Copy a running app's data into an empty folder, safely enough to back up.

SQLite databases are copied with SQLite's online backup API (a plain file copy of a database in use can be
broken). A manifest records every file's checksum and a few row counts, so a restore can be checked against
what was really saved. Standard library only. AI-assisted (Claude Code).

Usage: snapshot.py SPEC.json SOURCE_DIR EMPTY_DEST_DIR
"""

import hashlib
import json
import shutil
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

MANIFEST = "manifest.json"


class BackupError(Exception):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def list_files(root):
    """Every regular file under root except the manifest, as sorted relative paths."""
    found = []
    for path in root.rglob("*"):
        if path.is_symlink():
            raise BackupError(f"symbolic link in the data, not backed up silently: {path.relative_to(root)}")
        if path.is_file() and path.relative_to(root).as_posix() != MANIFEST:
            found.append(path.relative_to(root).as_posix())
    return sorted(found)


def check_database(path):
    uri = f"file:{path}?mode=ro&immutable=1"
    with closing(sqlite3.connect(uri, uri=True)) as db:
        result = [row[0] for row in db.execute("PRAGMA integrity_check")]
    if result != ["ok"]:
        raise BackupError(f"integrity check failed for {path.name}: {result[:3]}")


def count_rows(root, rule):
    uri = f"file:{root / rule['database']}?mode=ro&immutable=1"
    with closing(sqlite3.connect(uri, uri=True)) as db:
        return db.execute(rule["query"]).fetchone()[0]


def query_column(root, rule):
    uri = f"file:{root / rule['database']}?mode=ro&immutable=1"
    with closing(sqlite3.connect(uri, uri=True)) as db:
        return [row[0] for row in db.execute(rule["query"])]


def copy_database(source, target):
    if not source.is_file():
        raise BackupError(f"database not found: {source.name}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(f"file:{source}?mode=ro", uri=True, timeout=60)) as live:
        with closing(sqlite3.connect(target)) as copy:
            live.backup(copy)
            # One self-contained file: no -wal or -shm beside it.
            copy.execute("PRAGMA journal_mode=DELETE")


def snapshot(spec, source, dest):
    if not source.is_dir():
        raise BackupError(f"source folder not found: {source}")
    dest.mkdir(parents=True, exist_ok=True)
    if any(dest.iterdir()):
        raise BackupError(f"destination is not empty: {dest}")
    for name in spec["required"]:
        if not (source / name).exists():
            raise BackupError(f"required data is missing: {name}")

    # Databases first: a file added after this point is harmless extra in the backup.
    for name in spec["databases"]:
        copy_database(source / name, dest / name)
        check_database(dest / name)

    for name in spec["paths"]:
        item = source / name
        if item.is_dir():
            shutil.copytree(item, dest / name, symlinks=True)
        elif item.is_file():
            (dest / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, dest / name)

    counts = {}
    for label, rule in spec["counts"].items():
        counts[label] = count_rows(dest, rule)
        # An app that lost its volume starts with a new, empty database. Don't save that as a good backup.
        if counts[label] < rule["minimum"]:
            raise BackupError(f"{label}: found {counts[label]}, expected at least {rule['minimum']}")

    # Files the database says must be there, such as each repository's. None are needed when it lists nothing.
    for rule in spec.get("files_for_rows", []):
        for name in query_column(dest, rule):
            if not (dest / name).is_file():
                raise BackupError(f"the database lists it, but it is not in the copy: {name}")

    files = {name: sha256(dest / name) for name in list_files(dest)}
    (dest / MANIFEST).write_text(json.dumps({"counts": counts, "files": files}, indent=2) + "\n")
    return counts, len(files)


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    spec = json.loads(Path(argv[1]).read_text())
    try:
        counts, total = snapshot(spec, Path(argv[2]), Path(argv[3]))
    except (BackupError, OSError, sqlite3.Error, shutil.Error) as error:
        print(f"snapshot FAILED: {error}", file=sys.stderr)
        return 1
    print(f"snapshot ok: {total} files, counts {counts}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

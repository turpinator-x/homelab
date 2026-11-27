#!/usr/bin/env python3
"""Check restored data against the manifest that snapshot.py saved with it. AI-assisted (Claude Code).

Fails if a file is missing, changed or unexpected, if a database fails SQLite's integrity check, or if a row
count differs. It reads only; it never changes the restored data.

Usage: verify.py SPEC.json RESTORED_DIR
"""

import json
import sqlite3
import sys
from pathlib import Path

from snapshot import MANIFEST, BackupError, check_database, count_rows, list_files, sha256


def verify(spec, root):
    manifest = json.loads((root / MANIFEST).read_text())
    expected = manifest["files"]
    actual = list_files(root)

    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    if missing or extra:
        raise BackupError(f"file list differs: {len(missing)} missing {missing[:3]}, {len(extra)} unexpected {extra[:3]}")
    for name in actual:
        if sha256(root / name) != expected[name]:
            raise BackupError(f"checksum differs: {name}")
    for name in spec["databases"]:
        if name not in expected:
            raise BackupError(f"database not in the manifest: {name}")
        check_database(root / name)
    for label, rule in spec["counts"].items():
        found = count_rows(root, rule)
        if found != manifest["counts"][label] or found < rule["minimum"]:
            raise BackupError(f"{label}: restored {found}, saved {manifest['counts'][label]}")
    return manifest["counts"], len(actual)


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    spec = json.loads(Path(argv[1]).read_text())
    try:
        counts, total = verify(spec, Path(argv[2]))
    except (BackupError, OSError, KeyError, ValueError, sqlite3.Error) as error:
        print(f"verify FAILED: {error}", file=sys.stderr)
        return 1
    print(f"verify ok: {total} files, counts {counts}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

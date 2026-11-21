#!/usr/bin/env python3
"""Cold backup and verified restore into a new directory (standard library only)."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import tempfile


def inventory(root):
    records = {}
    for path in sorted(root.rglob("*")):
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise ValueError(f"Unexpected file type at {path.relative_to(root)}")
        digest = hashlib.sha256()
        with path.open("rb") as src:
            for chunk in iter(lambda: src.read(1024 * 1024), b""):
                digest.update(chunk)
        records[path.relative_to(root).as_posix()] = digest.hexdigest()
    return records


def verify_db(root):
    path = root / "runtime/tefter.sqlite"
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
        if db.execute("PRAGMA integrity_check").fetchall() != [("ok",)] or db.execute("PRAGMA foreign_key_check").fetchone():
            raise ValueError("Operational database failed integrity checks")
        db.execute("SELECT id FROM users LIMIT 1").fetchall()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["backup", "restore"])
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    src, dest = args.source.resolve(strict=True), args.destination.absolute()
    if dest.exists() or dest.is_symlink() or dest.resolve().is_relative_to(src):
        parser.error("Choose a new destination outside the source directory")
    os.umask(0o077)
    with tempfile.TemporaryDirectory(dir=dest.parent) as temp:
        stage = Path(temp) / "stage"
        if args.operation == "backup":
            with (src / "runtime/instance.lock").open("a+b") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                verify_db(src)
                before = inventory(src)
                shutil.copytree(src, stage / "instance", symlinks=True)
                if before != inventory(stage / "instance") or before != inventory(src):
                    raise ValueError("Source changed during backup")
                (stage / "manifest.json").write_text(json.dumps(dict(version=1, files=before), sort_keys=True))
        else:
            manifest = json.loads((src / "manifest.json").read_text())
            if manifest["version"] != 1 or inventory(src / "instance") != manifest["files"]:
                raise ValueError("Backup checksum mismatch")
            shutil.copytree(src / "instance", stage, symlinks=True)
            if inventory(stage) != manifest["files"]:
                raise ValueError("Restored checksum mismatch")
            verify_db(stage)
        stage.rename(dest)


if __name__ == "__main__":
    main()

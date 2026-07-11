#!/usr/bin/env python3
"""Write a consistent SQLite online backup to standard output."""

from __future__ import annotations

import sqlite3
import sys
import tempfile
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {Path(sys.argv[0]).name} DATABASE", file=sys.stderr)
        return 2

    source_path = Path(sys.argv[1])
    if not source_path.is_file():
        print(f"SQLite database not found: {source_path}", file=sys.stderr)
        return 1

    with tempfile.NamedTemporaryFile(prefix="hermes-sqlite-", suffix=".db") as temporary:
        with sqlite3.connect(source_path) as source, sqlite3.connect(temporary.name) as target:
            source.backup(target, pages=1024, sleep=0.05)
        with open(temporary.name, "rb") as backup:
            while chunk := backup.read(1024 * 1024):
                sys.stdout.buffer.write(chunk)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Validate a GBrain PostgreSQL custom archive and its backup metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate(
    archive: Path,
    metadata: Path,
    pg_restore: str,
    skip_catalog: bool = False,
    database: str = "gbrain",
) -> dict[str, object]:
    if not archive.is_file() or archive.stat().st_size == 0:
        raise ValueError(f"backup archive is missing or empty: {archive}")
    if not metadata.is_file():
        raise ValueError(f"backup metadata is missing: {metadata}")

    payload = json.loads(metadata.read_text(encoding="utf-8"))
    expected = {
        "database": database,
        "format": "postgresql-custom",
        "archive": archive.name,
        "bytes": archive.stat().st_size,
        "sha256": sha256(archive),
    }
    for key, value in expected.items():
        if payload.get(key) != value:
            raise ValueError(f"metadata mismatch for {key}: expected {value!r}")

    catalog_entries: int | None = None
    if not skip_catalog:
        executable = shutil.which(pg_restore)
        if executable:
            result = subprocess.run(
                [executable, "--list", str(archive)],
                check=True,
                capture_output=True,
                text=True,
            )
            catalog = result.stdout
        elif pg_restore == "pg_restore":
            repo_root = Path(__file__).resolve().parent.parent
            with archive.open("rb") as source:
                result = subprocess.run(
                    [
                        "docker",
                        "compose",
                        "--env-file",
                        str(repo_root / ".env"),
                        "exec",
                        "-T",
                        "gbrain-postgres",
                        "pg_restore",
                        "--list",
                    ],
                    cwd=repo_root,
                    stdin=source,
                    check=True,
                    capture_output=True,
                )
            catalog = result.stdout.decode("utf-8")
        else:
            raise OSError(f"pg_restore executable not found: {pg_restore}")
        catalog_entries = sum(
            1 for line in catalog.splitlines() if line and not line.startswith(";")
        )
        if catalog_entries == 0:
            raise ValueError("pg_restore reported an empty archive catalog")
    return {
        "archive": str(archive),
        "database": database,
        "bytes": archive.stat().st_size,
        "catalog_entries": catalog_entries,
        "sha256": expected["sha256"],
        "valid": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backup", type=Path, required=True)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--pg-restore", default="pg_restore")
    parser.add_argument(
        "--database",
        choices=("gbrain", "metabase"),
        default="gbrain",
        help="expected database name recorded in metadata",
    )
    parser.add_argument(
        "--skip-catalog",
        action="store_true",
        help="validate metadata and checksum only; the caller must inspect the archive catalog",
    )
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    metadata = args.metadata or Path(f"{args.backup}.json")
    try:
        report = validate(
            args.backup,
            metadata,
            args.pg_restore,
            args.skip_catalog,
            args.database,
        )
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"PostgreSQL backup validation failed: {error}", file=sys.stderr)
        return 1
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

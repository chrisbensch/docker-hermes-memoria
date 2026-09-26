#!/usr/bin/env python3
"""Remove the retired local Hindsight MCP entry from Hermes profile configs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


def remove_hindsight_block(text: str) -> tuple[str, bool]:
    """Remove a two-space mcp_servers.hindsight YAML mapping, preserving siblings."""
    lines = text.splitlines(keepends=True)
    output: list[str] = []
    removed = False
    in_mcp_servers = False
    index = 0
    while index < len(lines):
        line = lines[index].rstrip("\r\n")
        if line and not line[0].isspace() and line.endswith(":"):
            in_mcp_servers = line[:-1] == "mcp_servers"
        if in_mcp_servers and line == "  hindsight:":
            removed = True
            index += 1
            while index < len(lines):
                line = lines[index].rstrip("\r\n")
                if not line.strip() or line.startswith("    ") or line.startswith("\t"):
                    index += 1
                    continue
                break
            continue
        output.append(lines[index])
        index += 1
    return "".join(output), removed


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def migrate_profiles(data_dir: Path, apply: bool, now: datetime | None = None) -> list[Path]:
    profiles_dir = data_dir / "profiles"
    configs = sorted(path for path in profiles_dir.glob("*/config.yaml") if path.is_file())
    if not configs:
        raise ValueError(f"No profile config files found under {profiles_dir}")
    changes: list[tuple[Path, str, str, str]] = []
    for config in configs:
        original = config.read_text(encoding="utf-8")
        updated, removed = remove_hindsight_block(original)
        if removed:
            changes.append((config, original, updated, sha256(config)))
    if not changes:
        print("No Hindsight MCP entries found; profiles are already migrated.")
        return []
    for config, _, _, _ in changes:
        print(f"{'Would update' if not apply else 'Will update'} {config}")
    if not apply:
        print("Dry run only. Re-run with --apply to back up and update these profiles.")
        return [item[0] for item in changes]

    timestamp = (now or datetime.now(timezone.utc)).strftime("%Y%m%dT%H%M%SZ")
    backup_dir = data_dir / "migration-backups" / f"remove-hindsight-{timestamp}"
    backup_dir.mkdir(parents=True, mode=0o700, exist_ok=False)
    manifest: dict[str, dict[str, str]] = {}
    for config, original, updated, before_digest in changes:
        relative = config.relative_to(data_dir)
        backup = backup_dir / relative
        backup.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        shutil.copy2(config, backup)
        mode = config.stat().st_mode & 0o777
        temporary = config.with_name(config.name + f".tmp.{os.getpid()}")
        temporary.write_text(updated, encoding="utf-8")
        temporary.chmod(mode)
        temporary.replace(config)
        manifest[str(relative)] = {
            "before_sha256": before_digest,
            "after_sha256": sha256(config),
            "backup": str(backup.relative_to(backup_dir)),
        }
    (backup_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"Updated {len(changes)} profile(s); verified copies are in {backup_dir}.")
    return [item[0] for item in changes]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=Path("/opt/data"))
    parser.add_argument("--apply", action="store_true", help="back up and update profile configs")
    args = parser.parse_args()
    try:
        migrate_profiles(args.data_dir, args.apply)
    except (OSError, ValueError) as exc:
        print(f"Hindsight profile migration failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

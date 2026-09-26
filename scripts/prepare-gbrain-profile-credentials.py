#!/usr/bin/env python3
"""Convert a private GBrain grant handoff into broker and Hermes secret files."""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import stat
import sys
from pathlib import Path
from typing import Any


PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,62}$")
MAX_HANDOFF_BYTES = 65_536


class PreparationError(RuntimeError):
    """Raised when credential preparation cannot be completed safely."""


def read_private_handoff(path: Path) -> dict[str, Any]:
    path = path.resolve(strict=True)
    file_stat = path.lstat()
    if not stat.S_ISREG(file_stat.st_mode) or path.is_symlink():
        raise PreparationError("GBrain credential handoff must be a regular non-symlink file")
    if file_stat.st_uid != os.geteuid() or file_stat.st_mode & 0o077:
        raise PreparationError("GBrain credential handoff must be owned by the current user and mode 0600")
    if file_stat.st_size > MAX_HANDOFF_BYTES:
        raise PreparationError("GBrain credential handoff is unexpectedly large")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PreparationError("GBrain credential handoff is not valid JSON") from exc
    if not isinstance(value, dict):
        raise PreparationError("GBrain credential handoff must be a JSON object")
    if value.get("version") != 1:
        raise PreparationError("Unsupported GBrain credential handoff version")
    for key in ("client_id", "client_secret"):
        if not isinstance(value.get(key), str) or not value[key]:
            raise PreparationError(f"GBrain credential handoff lacks {key}")
    if value.get("profile") not in (None, "memory-writer"):
        raise PreparationError("GBrain client is not a memory-writer grant")
    return value


def prepare_output_directory(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = path.resolve(strict=True)
    directory_stat = path.stat()
    if directory_stat.st_uid != os.geteuid() or directory_stat.st_mode & 0o077:
        raise PreparationError("Output directory must be owned by the current user and mode 0700")
    return path


def write_private_file(path: Path, content: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
    except FileExistsError as exc:
        raise PreparationError(f"Refusing to replace existing credential file: {path}") from exc
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
    except Exception:
        path.unlink(missing_ok=True)
        raise


def prepare_credentials(profile: str, handoff_path: Path, output_dir: Path) -> dict[str, str]:
    if not PROFILE_RE.fullmatch(profile):
        raise PreparationError("Profile must use lowercase letters, numbers, underscores, or hyphens")
    handoff = read_private_handoff(handoff_path)
    output_dir = prepare_output_directory(output_dir)
    broker_path = output_dir / f"{profile}.env"
    hermes_path = output_dir / f"{profile}.broker-token"
    if broker_path.exists() or hermes_path.exists():
        raise PreparationError(f"Credential output already exists for profile {profile}")

    broker_token = secrets.token_hex(32)
    broker_content = (
        f"GBRAIN_BROKER_TOKEN={broker_token}\n"
        f"GBRAIN_OAUTH_CLIENT_ID={handoff['client_id']}\n"
        f"GBRAIN_OAUTH_CLIENT_SECRET={handoff['client_secret']}\n"
    )
    hermes_content = f"GBRAIN_MCP_PROXY_TOKEN={broker_token}\n"
    write_private_file(broker_path, broker_content)
    try:
        write_private_file(hermes_path, hermes_content)
    except Exception:
        broker_path.unlink(missing_ok=True)
        raise
    return {"profile": profile, "broker_file": str(broker_path), "hermes_token_file": str(hermes_path)}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prepare private broker and Hermes token files from a GBrain grant handoff"
    )
    parser.add_argument("--profile", required=True)
    parser.add_argument("--credentials", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = prepare_credentials(args.profile, args.credentials, args.output_dir)
    except (PreparationError, OSError) as exc:
        print(f"Credential preparation failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True) + "\n", end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

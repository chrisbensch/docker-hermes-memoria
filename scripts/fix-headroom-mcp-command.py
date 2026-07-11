#!/usr/bin/env python3
"""Safely migrate existing Hermes profiles to the Headroom socket-group command."""

from __future__ import annotations

import argparse
import copy
import os
import shutil
import subprocess
import sys
import tempfile
from collections import namedtuple
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
HEADROOM_COMMAND = (
    "exec docker exec -i -e HEADROOM_PROXY_URL=http://headroom-proxy:8787 "
    "hermes-headroom-mcp headroom mcp serve"
)
OLD_COMMAND = "docker"
OLD_ARGS = [
    "exec",
    "-i",
    "-e",
    "HEADROOM_PROXY_URL=http://headroom-proxy:8787",
    "hermes-headroom-mcp",
    "headroom",
    "mcp",
    "serve",
]
NEW_COMMAND = "sg"
NEW_ARGS = ["hostdocker", "-c", HEADROOM_COMMAND]
BLOCK_KEYS = {"command", "args", "enabled", "timeout"}
Result = namedtuple("Result", "profile path status detail")


def old_block() -> dict[str, Any]:
    return {"command": OLD_COMMAND, "args": list(OLD_ARGS), "enabled": True, "timeout": 120}


def new_block() -> dict[str, Any]:
    return {"command": NEW_COMMAND, "args": list(NEW_ARGS), "enabled": True, "timeout": 120}


def classify_headroom_block(block: Any) -> str:
    if not isinstance(block, dict):
        return "malformed"
    if set(block) != BLOCK_KEYS:
        return "custom"
    if not isinstance(block.get("enabled"), bool):
        return "malformed"
    timeout = block.get("timeout")
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)):
        return "malformed"
    signature = (block.get("command"), block.get("args"))
    if signature == (OLD_COMMAND, OLD_ARGS):
        return "old"
    if signature == (NEW_COMMAND, NEW_ARGS):
        return "new"
    return "custom"


def transform_config(document: Any) -> tuple[str, Any, str]:
    if not isinstance(document, dict):
        return "failed", document, "malformed top-level YAML mapping"
    servers = document.get("mcp_servers")
    if servers is None:
        return "skipped", document, "Headroom MCP block is absent"
    if not isinstance(servers, dict):
        return "failed", document, "malformed mcp_servers mapping"
    if "headroom" not in servers:
        return "skipped", document, "Headroom MCP block is absent"

    block = servers["headroom"]
    classification = classify_headroom_block(block)
    if classification == "new":
        return "already-correct", document, "Headroom MCP command already uses sg hostdocker"
    if classification == "custom":
        return "failed", document, "custom or ambiguous Headroom MCP block refused"
    if classification == "malformed":
        return "failed", document, "malformed Headroom MCP block refused"

    transformed = copy.deepcopy(document)
    replacement = new_block()
    replacement["enabled"] = block["enabled"]
    replacement["timeout"] = block["timeout"]
    transformed["mcp_servers"]["headroom"] = replacement
    return "changed", transformed, "Headroom MCP command requires migration"


def load_config(path: Path, yaml_module: Any) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return yaml_module.safe_load(handle)


def atomic_write(path: Path, document: Any, yaml_module: Any) -> None:
    original_stat = path.stat()
    mode = original_stat.st_mode & 0o7777
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary_name = handle.name
            yaml_module.safe_dump(document, handle, default_flow_style=False, sort_keys=False, allow_unicode=True)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), mode)
            os.fchown(handle.fileno(), original_stat.st_uid, original_stat.st_gid)
        os.replace(temporary_name, path)
        temporary_name = None
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def process_config(
    path: Path,
    *,
    profile: str,
    dry_run: bool,
    timestamp: str,
    yaml_module: Any,
) -> Result:
    try:
        document = load_config(path, yaml_module)
    except Exception:
        return Result(profile, path, "failed", "unable to read or parse config")

    try:
        status, transformed, detail = transform_config(document)
        if status != "changed" or dry_run:
            if status == "changed" and dry_run:
                detail = "would migrate Headroom MCP command"
            return Result(profile, path, status, detail)

        backup = path.with_name(f"{path.name}.headroom-mcp-backup-{timestamp}")
        if backup.exists():
            return Result(profile, path, "failed", f"backup already exists: {backup.name}")
        shutil.copy2(path, backup)
        atomic_write(path, transformed, yaml_module)
        return Result(profile, path, "changed", f"backup created: {backup.name}")
    except Exception:
        return Result(profile, path, "failed", "unable to back up or atomically update config")


def validate_profile_name(profile: str) -> bool:
    return bool(profile) and profile not in {".", ".."} and Path(profile).name == profile


def process_data_dir(
    data_dir: Path,
    *,
    profiles: list[str],
    dry_run: bool,
    timestamp: str,
    yaml_module: Any,
) -> list[Result]:
    data_dir = Path(data_dir)
    results: list[Result] = []

    if profiles:
        seen: set[str] = set()
        for profile in profiles:
            if profile in seen:
                continue
            seen.add(profile)
            if not validate_profile_name(profile):
                results.append(Result(profile, data_dir, "failed", "invalid profile name"))
                continue
            path = data_dir / "profiles" / profile / "config.yaml"
            if not path.is_file():
                results.append(Result(profile, path, "failed", "selected profile config does not exist"))
                continue
            results.append(
                process_config(
                    path,
                    profile=profile,
                    dry_run=dry_run,
                    timestamp=timestamp,
                    yaml_module=yaml_module,
                )
            )
        return results

    profiles_dir = data_dir / "profiles"
    if profiles_dir.is_dir():
        for path in sorted(profiles_dir.glob("*/config.yaml")):
            results.append(
                process_config(
                    path,
                    profile=path.parent.name,
                    dry_run=dry_run,
                    timestamp=timestamp,
                    yaml_module=yaml_module,
                )
            )

    base_path = data_dir / "config.yaml"
    if base_path.is_file():
        base_result = process_config(
            base_path,
            profile="base",
            dry_run=dry_run,
            timestamp=timestamp,
            yaml_module=yaml_module,
        )
        if base_result.status != "skipped":
            results.append(base_result)
    return results


def require_yaml() -> Any:
    try:
        import yaml
    except ImportError as exc:
        raise RuntimeError("PyYAML is required inside the Hermes container") from exc
    return yaml


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    with path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.removeprefix("export ").strip()
            if key:
                values[key] = value.strip()
    return values


def run_inside(data_dir: Path, profiles: list[str], dry_run: bool) -> int:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    try:
        results = process_data_dir(
            data_dir,
            profiles=profiles,
            dry_run=dry_run,
            timestamp=timestamp,
            yaml_module=require_yaml(),
        )
    except Exception as exc:
        print(f"failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    for result in results:
        print(f"{result.status}: {result.path} ({result.detail})")
    if not results:
        print(f"skipped: {data_dir} (no profile configs found)")
    return 1 if any(result.status == "failed" for result in results) else 0


def run_host(profiles: list[str], dry_run: bool) -> int:
    env_path = REPO_ROOT / ".env"
    if not env_path.is_file():
        print(f"failed: required Compose environment file is missing: {env_path}", file=sys.stderr)
        return 1
    try:
        env_values = read_env_file(env_path)
    except OSError as exc:
        print(f"failed: could not read {env_path}: {exc}", file=sys.stderr)
        return 1
    if not env_values.get("APPDATA_DIR"):
        print("failed: APPDATA_DIR is missing or empty in .env", file=sys.stderr)
        return 1

    command = [
        "docker",
        "compose",
        "--env-file",
        str(env_path),
        "exec",
        "-T",
        "hermes",
        "python",
        "-",
        "--inside-data-dir",
        "/opt/data",
    ]
    if dry_run:
        command.append("--dry-run")
    for profile in profiles:
        command.extend(("--profile", profile))
    try:
        source = Path(__file__).read_bytes()
        return subprocess.run(command, cwd=REPO_ROOT, input=source, check=False).returncode
    except OSError as exc:
        print(f"failed: could not execute Docker Compose: {exc}", file=sys.stderr)
        return 1


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="report changes without writing or backing up")
    parser.add_argument("--profile", action="append", default=[], help="limit migration to a profile (repeatable)")
    parser.add_argument("--inside-data-dir", type=Path, help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.inside_data_dir is not None:
        return run_inside(args.inside_data_dir, args.profile, args.dry_run)
    return run_host(args.profile, args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())

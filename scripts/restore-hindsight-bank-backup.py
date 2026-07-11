#!/usr/bin/env python3
"""Restore a validated Hindsight document-transfer backup with explicit safety gates."""

from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


REPO_ROOT = Path(__file__).resolve().parents[1]


class RestoreError(RuntimeError):
    """Raised when a restore precondition, import, or verification fails."""


def load_validator():
    path = REPO_ROOT / "scripts" / "validate-hindsight-bank-backup.py"
    spec = importlib.util.spec_from_file_location("hindsight_backup_validator", path)
    if spec is None or spec.loader is None:
        raise RestoreError(f"Unable to load backup validator: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ApiClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def request_json(self, method: str, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        data = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(f"{self.base_url}{path}", data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RestoreError(f"{method} {path} failed with HTTP {exc.code}: {detail[:500]}") from exc
        except urllib.error.URLError as exc:
            raise RestoreError(f"{method} {path} failed: {exc.reason}") from exc
        try:
            decoded = json.loads(body)
        except json.JSONDecodeError as exc:
            raise RestoreError(f"{method} {path} returned invalid JSON") from exc
        if not isinstance(decoded, dict):
            raise RestoreError(f"{method} {path} returned a non-object response")
        return decoded

    def request_multipart(self, method: str, path: str, field_name: str, file_path: Path) -> dict[str, Any]:
        boundary = f"----hindsight-restore-{uuid.uuid4().hex}"
        file_data = file_path.read_bytes()
        body = b"".join(
            (
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{field_name}"; filename="{file_path.name}"\r\n'.encode(),
                b"Content-Type: application/zip\r\n\r\n",
                file_data,
                f"\r\n--{boundary}--\r\n".encode(),
            )
        )
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=body,
            headers={"Accept": "application/json", "Content-Type": f"multipart/form-data; boundary={boundary}"},
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                decoded = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RestoreError(f"{method} {path} failed with HTTP {exc.code}: {detail[:500]}") from exc
        if not isinstance(decoded, dict):
            raise RestoreError(f"{method} {path} returned a non-object response")
        return decoded


def parse_version(value: Any) -> tuple[int, ...]:
    if not isinstance(value, str):
        raise RestoreError(f"Invalid target API version: {value!r}")
    try:
        return tuple(int(part) for part in value.split("."))
    except ValueError as exc:
        raise RestoreError(f"Invalid target API version: {value!r}") from exc


def fetch_all_items(client: Any, path: str, page_size: int = 100) -> list[dict[str, Any]]:
    offset = 0
    all_items: list[dict[str, Any]] = []
    total: int | None = None
    while total is None or offset < total:
        separator = "&" if "?" in path else "?"
        page = client.request_json("GET", f"{path}{separator}limit={page_size}&offset={offset}")
        items = page.get("items")
        if not isinstance(items, list):
            raise RestoreError(f"Unexpected paginated response for {path}")
        total_value = page.get("total", len(items))
        if isinstance(total_value, bool) or not isinstance(total_value, int):
            raise RestoreError(f"Invalid total for {path}: {total_value!r}")
        total = total_value
        all_items.extend(items)
        if not items and offset < total:
            raise RestoreError(f"Empty page before total for {path}: offset={offset}, total={total}")
        offset += len(items)
    if len(all_items) != total:
        raise RestoreError(f"Pagination mismatch for {path}: got={len(all_items)}, total={total}")
    return all_items


def preflight(client: Any, selected_banks: list[str]) -> dict[str, Any]:
    health = client.request_json("GET", "/health")
    if health.get("status") != "healthy":
        raise RestoreError(f"Destination Hindsight is not healthy: {health}")
    version = client.request_json("GET", "/version")
    if parse_version(version.get("api_version")) < (0, 8, 4):
        raise RestoreError(f"Destination Hindsight must be at least 0.8.4: {version}")
    if version.get("features", {}).get("document_import_api") is False:
        raise RestoreError("Destination document import API is disabled")
    openapi = client.request_json("GET", "/openapi.json")
    paths = openapi.get("paths")
    required = {
        "/v1/default/banks/{bank_id}": "put",
        "/v1/default/banks/{bank_id}/document-transfer": "post",
        "/v1/default/banks/{bank_id}/operations/{operation_id}": "get",
    }
    if not isinstance(paths, dict) or any(method not in paths.get(path, {}) for path, method in required.items()):
        raise RestoreError("Destination OpenAPI is missing required restore endpoints")
    banks_response = client.request_json("GET", "/v1/default/banks")
    existing = banks_response.get("banks")
    if not isinstance(existing, list):
        raise RestoreError("Destination bank inventory is invalid")
    existing_ids = {bank.get("bank_id") for bank in existing if isinstance(bank, dict)}
    conflicts = sorted(bank for bank in selected_banks if bank in existing_ids)
    if conflicts:
        raise RestoreError(f"Destination already has selected bank(s): {', '.join(conflicts)}")
    return {"health": health, "version": version, "banks_before": existing}


def poll_operation(client: Any, bank_id: str, operation_id: str, timeout_seconds: int, sleep_fn: Callable[[float], None]) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    path = f"/v1/default/banks/{bank_id}/operations/{operation_id}"
    while True:
        operation = client.request_json("GET", path)
        status = operation.get("status")
        if status == "completed":
            return operation
        if status in {"failed", "cancelled", "not_found"}:
            raise RestoreError(f"{bank_id}: operation {operation_id} did not complete: {operation}")
        if time.monotonic() >= deadline:
            raise RestoreError(f"{bank_id}: operation {operation_id} timed out after {timeout_seconds}s")
        sleep_fn(2)


def snapshot_target(target_backup_dir: Path, banks_before: list[dict[str, Any]]) -> None:
    target_backup_dir.mkdir(parents=True, exist_ok=False)
    (target_backup_dir / "target-before.json").write_text(json.dumps({"banks": banks_before}, indent=2) + "\n", encoding="utf-8")
    archive_path = target_backup_dir / "hindsight-pg0-before.tgz"
    with archive_path.open("wb") as handle:
        result = subprocess.run(
            ["docker", "compose", "--env-file", ".env", "exec", "-T", "hindsight-mcp", "tar", "-C", "/home/hindsight", "-czf", "-", ".pg0"],
            cwd=REPO_ROOT,
            stdout=handle,
            stderr=subprocess.PIPE,
            check=False,
        )
    if result.returncode != 0:
        archive_path.unlink(missing_ok=True)
        raise RestoreError(f"Failed to snapshot target Hindsight state: {result.stderr.decode(errors='replace')}")


def default_target_backup_dir() -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    return REPO_ROOT / "tmp" / f"hindsight-target-pre-restore-{stamp}"


def run_restore(
    client: Any,
    backup_dir: Path,
    *,
    selected_banks: list[str] | None = None,
    apply: bool,
    timeout_seconds: int = 900,
    target_backup_dir: Path | None = None,
    snapshotter: Callable[[Path], None] | None = None,
    sleep_fn: Callable[[float], None] = time.sleep,
) -> dict[str, Any]:
    validator = load_validator()
    try:
        validation = validator.validate_backup(backup_dir)
    except validator.ValidationError as exc:
        raise RestoreError(f"Backup validation failed: {exc}") from exc
    available_banks = validation["bank_ids"]
    selected = selected_banks or available_banks
    unknown = sorted(set(selected) - set(available_banks))
    if unknown:
        raise RestoreError(f"Requested bank(s) absent from backup: {', '.join(unknown)}")
    selected = [bank for bank in available_banks if bank in selected]
    target = preflight(client, selected)
    report: dict[str, Any] = {
        "mode": "apply" if apply else "dry-run",
        "backup": validation,
        "target": target,
        "selected_banks": selected,
        "banks": {},
    }
    if not apply:
        return report

    target_backup_dir = target_backup_dir or default_target_backup_dir()
    if snapshotter is not None:
        snapshotter(target_backup_dir)
    else:
        snapshot_target(target_backup_dir, target["banks_before"])
    report["target_backup_dir"] = str(target_backup_dir)

    for bank_id in selected:
        counts = validation["banks"][bank_id]
        bank_dir = Path(validation["backup_dir"]) / "banks" / bank_id
        bank_report: dict[str, Any] = {"expected": counts, "status": "creating"}
        report["banks"][bank_id] = bank_report
        client.request_json("PUT", f"/v1/default/banks/{bank_id}", {})
        bank_report["target_config_before_import"] = client.request_json("GET", f"/v1/default/banks/{bank_id}/config")
        bank_report["status"] = "importing"
        submission = client.request_multipart(
            "POST",
            f"/v1/default/banks/{bank_id}/document-transfer?on_conflict=skip",
            "file",
            bank_dir / "document-transfer.zip",
        )
        operation_id = submission.get("operation_id")
        if not isinstance(operation_id, str) or not operation_id:
            raise RestoreError(f"{bank_id}: document import did not return operation_id")
        bank_report["operation_id"] = operation_id
        bank_report["operation"] = poll_operation(client, bank_id, operation_id, timeout_seconds, sleep_fn)
        document_count = len(fetch_all_items(client, f"/v1/default/banks/{bank_id}/documents"))
        memory_count = len(fetch_all_items(client, f"/v1/default/banks/{bank_id}/memories/list"))
        entity_count = len(fetch_all_items(client, f"/v1/default/banks/{bank_id}/entities"))
        if document_count != counts["documents"]:
            raise RestoreError(f"{bank_id}: expected {counts['documents']} documents, got {document_count}")
        expected_memories = counts["facts"] + counts["observations"]
        if memory_count != expected_memories:
            raise RestoreError(f"{bank_id}: expected {expected_memories} memories, got {memory_count}")
        bank_report["counts"] = {"documents": document_count, "memories": memory_count, "entities": entity_count}
        bank_report["status"] = "completed"
    return report


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Restore a validated Hindsight backup")
    parser.add_argument("--backup-dir", type=Path, required=True, help="Validated backup directory")
    parser.add_argument("--api-url", default="http://127.0.0.1:8888", help="Destination Hindsight API URL")
    parser.add_argument("--bank", action="append", dest="banks", help="Bank ID to restore; repeat as needed")
    parser.add_argument("--apply", action="store_true", help="Perform writes after preflight and target snapshot")
    parser.add_argument("--timeout-seconds", type=int, default=900, help="Per-bank import timeout")
    parser.add_argument("--target-backup-dir", type=Path, help="Destination snapshot directory for --apply")
    parser.add_argument("--report", type=Path, help="Explicit restore report path")
    args = parser.parse_args()
    if args.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be positive")
    try:
        report = run_restore(
            ApiClient(args.api_url),
            args.backup_dir,
            selected_banks=args.banks,
            apply=args.apply,
            timeout_seconds=args.timeout_seconds,
            target_backup_dir=args.target_backup_dir,
        )
    except RestoreError as exc:
        print(f"Restore failed: {exc}", file=sys.stderr)
        return 1

    report_path = args.report
    if report_path is None and args.apply:
        report_path = Path(report["target_backup_dir"]) / "restore-report.json"
    if report_path is not None:
        write_report(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

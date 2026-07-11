#!/usr/bin/env python3
"""Create a complete, validator-compatible Hindsight document-transfer backup."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]


class BackupError(RuntimeError):
    """Raised when a source Hindsight backup cannot be completed safely."""


def load_validator():
    path = REPO_ROOT / "scripts" / "validate-hindsight-bank-backup.py"
    spec = importlib.util.spec_from_file_location("hindsight_backup_validator", path)
    if spec is None or spec.loader is None:
        raise BackupError(f"Unable to load backup validator: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ApiClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def request_bytes(self, method: str, path: str) -> bytes:
        request = urllib.request.Request(f"{self.base_url}{path}", headers={"Accept": "application/json"}, method=method)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise BackupError(f"{method} {path} failed with HTTP {exc.code}: {detail[:500]}") from exc
        except urllib.error.URLError as exc:
            raise BackupError(f"{method} {path} failed: {exc.reason}") from exc

    def request_json(self, method: str, path: str) -> dict[str, Any]:
        body = self.request_bytes(method, path)
        try:
            decoded = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise BackupError(f"{method} {path} returned invalid JSON") from exc
        if not isinstance(decoded, dict):
            raise BackupError(f"{method} {path} returned a non-object response")
        return decoded


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def fetch_all_items(client: Any, path: str, page_size: int = 100) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    offset = 0
    result: list[dict[str, Any]] = []
    first_page: dict[str, Any] | None = None
    while True:
        separator = "&" if "?" in path else "?"
        page = client.request_json("GET", f"{path}{separator}limit={page_size}&offset={offset}")
        if first_page is None:
            first_page = page
        items = page.get("items")
        total = page.get("total")
        if not isinstance(items, list) or isinstance(total, bool) or not isinstance(total, int):
            raise BackupError(f"Invalid paginated response for {path}")
        if not all(isinstance(item, dict) for item in items):
            raise BackupError(f"Invalid item in paginated response for {path}")
        result.extend(items)
        if len(result) == total:
            payload = dict(first_page)
            payload.update({"items": result, "total": total, "limit": page_size, "offset": 0})
            return result, payload
        if not items or len(result) > total:
            raise BackupError(f"Pagination mismatch for {path}")
        offset += len(items)


def inspect_transfer_archive(path: Path, bank_id: str) -> dict[str, int]:
    try:
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
            if "manifest.json" not in names or "observations.json" not in names:
                raise BackupError(f"{bank_id}: transfer archive is missing manifest or observations")
            manifest = json.loads(archive.read("manifest.json"))
    except zipfile.BadZipFile as exc:
        raise BackupError(f"{bank_id}: invalid document-transfer ZIP") from exc
    except json.JSONDecodeError as exc:
        raise BackupError(f"{bank_id}: invalid document-transfer manifest") from exc
    if not isinstance(manifest, dict) or manifest.get("source_bank_id") != bank_id:
        raise BackupError(f"{bank_id}: document-transfer source bank mismatch")
    counts = {
        "documents": manifest.get("document_count"),
        "facts": manifest.get("fact_count"),
        "observations": manifest.get("observation_count"),
    }
    if any(isinstance(value, bool) or not isinstance(value, int) for value in counts.values()):
        raise BackupError(f"{bank_id}: document-transfer counts are invalid")
    return counts  # type: ignore[return-value]


def bank_counts(banks: list[dict[str, Any]]) -> dict[str, int]:
    result: dict[str, int] = {}
    for bank in banks:
        bank_id = bank.get("bank_id")
        fact_count = bank.get("fact_count")
        if not isinstance(bank_id, str) or isinstance(fact_count, bool) or not isinstance(fact_count, int):
            raise BackupError("Source bank inventory is invalid")
        result[bank_id] = fact_count
    return result


def export_bank(client: Any, backup_dir: Path, bank_id: str) -> dict[str, Any]:
    bank_dir = backup_dir / "banks" / bank_id
    documents_dir = bank_dir / "documents"
    documents_dir.mkdir(parents=True)
    section_paths = {
        "bank-config.json": f"/v1/default/banks/{bank_id}/export",
        "mental-models.json": f"/v1/default/banks/{bank_id}/mental-models",
        "directives.json": f"/v1/default/banks/{bank_id}/directives",
    }
    sections: dict[str, Any] = {}
    for filename, path in section_paths.items():
        payload = client.request_json("GET", path)
        write_json(bank_dir / filename, payload)
        sections[filename] = len(payload.get("items", [])) if isinstance(payload.get("items"), list) else 0

    memories, memories_payload = fetch_all_items(client, f"/v1/default/banks/{bank_id}/memories/list")
    entities, entities_payload = fetch_all_items(client, f"/v1/default/banks/{bank_id}/entities")
    documents, documents_payload = fetch_all_items(client, f"/v1/default/banks/{bank_id}/documents")
    write_json(bank_dir / "memories.json", memories_payload)
    write_json(bank_dir / "entities.json", entities_payload)
    write_json(bank_dir / "documents.json", documents_payload)
    sections.update({"memories.json": len(memories), "entities.json": len(entities), "documents.json": len(documents)})

    for document in documents:
        document_id = document.get("id")
        if not isinstance(document_id, str) or not document_id:
            raise BackupError(f"{bank_id}: document without an id")
        write_json(documents_dir / f"{document_id}.json", client.request_json("GET", f"/v1/default/banks/{bank_id}/documents/{document_id}"))

    archive_path = bank_dir / "document-transfer.zip"
    archive_bytes = client.request_bytes("GET", f"/v1/default/banks/{bank_id}/document-transfer?include_observations=true")
    archive_path.write_bytes(archive_bytes)
    transfer = inspect_transfer_archive(archive_path, bank_id)
    sections["document-transfer.zip"] = {
        "sha256": hashlib.sha256(archive_bytes).hexdigest(),
        **transfer,
    }
    return {"bank_id": bank_id, "sections": sections}


def export_backup(client: Any, output_dir: Path, backup_name: str) -> dict[str, Any]:
    if not backup_name or Path(backup_name).name != backup_name:
        raise BackupError("Backup name must be a simple directory name")
    health = client.request_json("GET", "/health")
    if health.get("status") != "healthy":
        raise BackupError(f"Hindsight is not healthy: {health}")
    version = client.request_json("GET", "/version")
    if version.get("features", {}).get("document_export_api") is False:
        raise BackupError("Hindsight document export API is disabled")
    before = client.request_json("GET", "/v1/default/banks")
    banks = before.get("banks")
    if not isinstance(banks, list) or not banks:
        raise BackupError("Source bank inventory is empty or invalid")
    before_counts = bank_counts(banks)
    backup_dir = output_dir / backup_name
    backup_dir.mkdir(parents=True, exist_ok=False)
    summaries = [export_bank(client, backup_dir, bank_id) for bank_id in sorted(before_counts)]
    after = client.request_json("GET", "/v1/default/banks")
    after_banks = after.get("banks")
    if not isinstance(after_banks, list) or bank_counts(after_banks) != before_counts:
        raise BackupError("Source bank counts changed during export")
    manifest = {
        "backup_timestamp": datetime.now(timezone.utc).isoformat(),
        "api_url": getattr(client, "base_url", "custom-client"),
        "total_banks": len(summaries),
        "banks": summaries,
    }
    write_json(backup_dir / "manifest.json", manifest)
    validator = load_validator()
    try:
        validation = validator.validate_backup(backup_dir)
    except validator.ValidationError as exc:
        raise BackupError(f"Export validation failed: {exc}") from exc
    return validation


def main() -> int:
    parser = argparse.ArgumentParser(description="Export all Hindsight banks with observations")
    parser.add_argument("--api-url", default="http://127.0.0.1:8888", help="Hindsight API URL")
    parser.add_argument("--output-dir", type=Path, required=True, help="Parent backup directory")
    parser.add_argument("--backup-name", help="Simple backup directory name")
    parser.add_argument("--report", type=Path, help="Optional JSON report path")
    args = parser.parse_args()
    name = args.backup_name or f"hindsight-backup-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"
    try:
        report = export_backup(ApiClient(args.api_url), args.output_dir, name)
    except BackupError as exc:
        print(f"Backup failed: {exc}", file=sys.stderr)
        return 1
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

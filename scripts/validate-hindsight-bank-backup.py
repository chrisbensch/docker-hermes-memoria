#!/usr/bin/env python3
"""Validate a Hindsight document-transfer backup without contacting any API."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path
from typing import Any


class ValidationError(RuntimeError):
    """Raised when a backup cannot be restored safely."""


REQUIRED_BANK_FILES = (
    "bank-config.json",
    "memories.json",
    "entities.json",
    "mental-models.json",
    "directives.json",
    "documents.json",
    "document-transfer.zip",
)


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValidationError(f"Missing required file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"Invalid JSON in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ValidationError(f"Expected JSON object in {path}")
    return data


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError(f"Expected integer {label}, got {value!r}")
    return value


def validate_bank(backup_dir: Path, summary: dict[str, Any]) -> dict[str, int]:
    bank_id = summary.get("bank_id")
    if not isinstance(bank_id, str) or not bank_id:
        raise ValidationError("Manifest bank entry has no bank_id")

    bank_dir = backup_dir / "banks" / bank_id
    if not bank_dir.is_dir():
        raise ValidationError(f"{bank_id}: bank directory is missing")
    for filename in REQUIRED_BANK_FILES:
        if not (bank_dir / filename).is_file():
            raise ValidationError(f"{bank_id}: missing {filename}")
    if not (bank_dir / "documents").is_dir():
        raise ValidationError(f"{bank_id}: missing documents directory")

    sections = summary.get("sections")
    if not isinstance(sections, dict):
        raise ValidationError(f"{bank_id}: manifest sections are missing")
    transfer_summary = sections.get("document-transfer.zip")
    if not isinstance(transfer_summary, dict):
        raise ValidationError(f"{bank_id}: ZIP summary is missing")
    expected_hash = transfer_summary.get("sha256")
    if not isinstance(expected_hash, str):
        raise ValidationError(f"{bank_id}: ZIP checksum is missing")

    archive_path = bank_dir / "document-transfer.zip"
    if sha256_file(archive_path) != expected_hash:
        raise ValidationError(f"{bank_id}: ZIP checksum mismatch")

    memories = load_json(bank_dir / "memories.json")
    documents = load_json(bank_dir / "documents.json")
    memory_total = require_int(memories.get("total"), f"{bank_id} memories.total")
    document_total = require_int(documents.get("total"), f"{bank_id} documents.total")

    try:
        with zipfile.ZipFile(archive_path) as archive:
            names = set(archive.namelist())
            if "manifest.json" not in names:
                raise ValidationError(f"{bank_id}: ZIP manifest.json is missing")
            if "observations.json" not in names:
                raise ValidationError(f"{bank_id}: observations.json is missing")
            transfer = json.loads(archive.read("manifest.json"))
            document_entries = [name for name in names if name.startswith("documents/") and name.endswith(".json")]
    except zipfile.BadZipFile as exc:
        raise ValidationError(f"{bank_id}: invalid transfer ZIP") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"{bank_id}: invalid ZIP manifest JSON") from exc

    if not isinstance(transfer, dict):
        raise ValidationError(f"{bank_id}: ZIP manifest is not an object")
    if transfer.get("source_bank_id") != bank_id:
        raise ValidationError(f"{bank_id}: source bank mismatch")
    if transfer.get("schema_version") != 1:
        raise ValidationError(f"{bank_id}: unsupported transfer schema")
    if transfer.get("archive_type") != "documents":
        raise ValidationError(f"{bank_id}: expected document-transfer archive")

    transfer_documents = require_int(transfer.get("document_count"), f"{bank_id} transfer document_count")
    transfer_facts = require_int(transfer.get("fact_count"), f"{bank_id} transfer fact_count")
    transfer_observations = require_int(transfer.get("observation_count"), f"{bank_id} transfer observation_count")
    if transfer_documents != document_total or len(document_entries) != document_total:
        raise ValidationError(f"{bank_id}: document count mismatch")
    if transfer_facts + transfer_observations != memory_total:
        raise ValidationError(f"{bank_id}: memory coverage mismatch")

    for key, actual in (("documents", transfer_documents), ("facts", transfer_facts), ("observations", transfer_observations)):
        if transfer_summary.get(key) != actual:
            raise ValidationError(f"{bank_id}: manifest {key} differs from ZIP")
    if sections.get("memories.json") != memory_total:
        raise ValidationError(f"{bank_id}: manifest memories count differs from file")
    if sections.get("documents.json") != document_total:
        raise ValidationError(f"{bank_id}: manifest documents count differs from file")

    return {
        "documents": transfer_documents,
        "facts": transfer_facts,
        "observations": transfer_observations,
        "memories": memory_total,
    }


def validate_backup(backup_dir: Path) -> dict[str, Any]:
    backup_dir = backup_dir.resolve()
    manifest = load_json(backup_dir / "manifest.json")
    banks = manifest.get("banks")
    if not isinstance(banks, list) or not banks:
        raise ValidationError("Backup manifest has no banks")
    if manifest.get("total_banks") != len(banks):
        raise ValidationError("Backup manifest total_banks mismatch")

    seen_bank_ids: set[str] = set()
    report_banks: dict[str, dict[str, int]] = {}
    totals = {"banks": 0, "documents": 0, "facts": 0, "observations": 0, "memories": 0}
    for summary in banks:
        if not isinstance(summary, dict):
            raise ValidationError("Backup manifest contains invalid bank entry")
        bank_id = summary.get("bank_id")
        if not isinstance(bank_id, str) or bank_id in seen_bank_ids:
            raise ValidationError(f"Duplicate or invalid bank id: {bank_id!r}")
        seen_bank_ids.add(bank_id)
        counts = validate_bank(backup_dir, summary)
        report_banks[bank_id] = counts
        totals["banks"] += 1
        for key in ("documents", "facts", "observations", "memories"):
            totals[key] += counts[key]

    on_disk_bank_ids = {path.name for path in (backup_dir / "banks").iterdir() if path.is_dir()}
    if on_disk_bank_ids != seen_bank_ids:
        unexpected = sorted(on_disk_bank_ids.symmetric_difference(seen_bank_ids))
        raise ValidationError(f"Bank directories do not match manifest: {unexpected}")

    return {
        "backup_dir": str(backup_dir),
        "backup_timestamp": manifest.get("backup_timestamp"),
        "source_api": manifest.get("api_url"),
        "bank_ids": list(report_banks),
        "banks": report_banks,
        "totals": totals,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a Hindsight document-transfer backup")
    parser.add_argument("--backup-dir", type=Path, required=True, help="Backup directory to validate")
    parser.add_argument("--report", type=Path, help="Optional JSON report output path")
    args = parser.parse_args()
    try:
        report = validate_backup(args.backup_dir)
    except ValidationError as exc:
        print(f"Validation failed: {exc}", file=sys.stderr)
        return 1
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

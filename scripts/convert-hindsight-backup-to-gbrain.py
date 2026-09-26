#!/usr/bin/env python3
"""Convert a validated Hindsight backup into an auditable GBrain corpus."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import sys
import tempfile
import unicodedata
import zipfile
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
CONVERTER_SCHEMA_VERSION = 3
GBRAIN_REF = "31f257a0a7b218b40e03d302bc6913c99f26f0ec"
SAFE_PROFILE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
MIN_ENTITY_MENTIONS = 2

# Mirrors GBrain's conservative single-token entity-name quality gate at the
# pinned compatibility ref, with chat-role tokens added for Hindsight exports.
# These records remain searchable notes; only automatic relationship
# extraction is disabled for them.
GENERIC_ENTITY_TOKENS = frozenset(
    {
        "admin",
        "agenda",
        "anyone",
        "assistant",
        "bot",
        "chief",
        "company",
        "contact",
        "draft",
        "everyone",
        "founder",
        "founders",
        "general",
        "hello",
        "human",
        "inbox",
        "info",
        "meeting",
        "meetings",
        "memory",
        "minutes",
        "misc",
        "none",
        "note",
        "notes",
        "null",
        "other",
        "people",
        "person",
        "readme",
        "someone",
        "something",
        "staff",
        "summary",
        "support",
        "system",
        "tbd",
        "team",
        "test",
        "thanks",
        "todo",
        "tool",
        "undefined",
        "unknown",
        "unnamed",
        "untitled",
        "update",
        "updates",
        "user",
        "users",
        "various",
        "welcome",
        "will",
    }
)


class ConversionError(RuntimeError):
    """Raised when a conversion cannot be completed safely."""


def load_validator():
    path = REPO_ROOT / "scripts" / "validate-hindsight-bank-backup.py"
    spec = importlib.util.spec_from_file_location("hindsight_backup_validator", path)
    if spec is None or spec.loader is None:
        raise ConversionError(f"Unable to load backup validator: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ConversionError(f"Expected object for {label}")
    return value


def require_items(path: Path) -> list[dict[str, Any]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConversionError(f"Unable to read validated JSON section: {path.name}") from exc
    items = require_object(value, path.name).get("items")
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        raise ConversionError(f"Expected object items in {path.name}")
    return items


def profile_for_bank(bank_id: str) -> str:
    profile = bank_id.removeprefix("hermes-")
    if not SAFE_PROFILE.fullmatch(profile) or profile == "default":
        raise ConversionError(f"Bank id does not map to a safe GBrain profile: {bank_id!r}")
    return profile


def artifact_slug(identifier: str) -> str:
    if not identifier:
        raise ConversionError("Artifact is missing an id")
    readable = re.sub(r"[^a-z0-9._-]+", "-", identifier.lower()).strip("-._")[:64]
    if not readable:
        readable = "item"
    return f"{readable}-{sha256_bytes(identifier.encode('utf-8'))[:12]}"


def yaml_string(value: str) -> str:
    # JSON strings are valid YAML scalars and avoid hand-written escaping.
    return json.dumps(value, ensure_ascii=False)


def string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return sorted({item for item in value if isinstance(item, str) and item})


def frontmatter(fields: dict[str, Any]) -> str:
    lines = ["---"]
    for key, value in fields.items():
        if value is None or value == []:
            continue
        if isinstance(value, list):
            rendered = json.dumps(value, ensure_ascii=False, sort_keys=True)
        elif isinstance(value, bool):
            rendered = "true" if value else "false"
        elif isinstance(value, (int, float)) and not isinstance(value, bool):
            rendered = str(value)
        else:
            rendered = yaml_string(str(value))
        lines.append(f"{key}: {rendered}")
    lines.extend(("---", ""))
    return "\n".join(lines)


def text_section(heading: str, value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        return ""
    return f"\n## {heading}\n\n{value.rstrip()}\n"


def is_cjk(character: str) -> bool:
    value = ord(character)
    return (
        0x3400 <= value <= 0x4DBF
        or 0x4E00 <= value <= 0x9FFF
        or 0xF900 <= value <= 0xFAFF
        or 0x3040 <= value <= 0x30FF
        or 0xAC00 <= value <= 0xD7AF
    )


def entity_name_tokens(name: str) -> tuple[str, ...]:
    """Approximate GBrain's pinned title tokenizer for duplicate detection."""
    tokens: list[str] = []
    current: list[str] = []

    def flush() -> None:
        if current:
            tokens.append(unicodedata.normalize("NFC", "".join(current)).lower())
            current.clear()

    for character in unicodedata.normalize("NFC", name):
        if is_cjk(character):
            flush()
            tokens.append(character.lower())
            continue
        category = unicodedata.category(character)
        if character.isalpha() or "0" <= character <= "9":
            current.append(character)
        elif category.startswith("M") and current:
            current.append(character)
        else:
            flush()
    flush()
    return tuple(tokens)


def entity_quality_decisions(
    records: Iterable[tuple[str, str, dict[str, Any]]],
) -> tuple[dict[tuple[str, str], dict[str, Any]], dict[str, Any]]:
    """Quarantine ambiguous/noisy names while retaining every source record."""
    decisions: dict[tuple[str, str], dict[str, Any]] = {}
    groups: dict[tuple[str, ...], list[tuple[str, str, dict[str, Any]]]] = defaultdict(list)
    prepared: list[tuple[str, str, dict[str, Any], str, tuple[str, ...]]] = []

    for bank_id, profile, item in records:
        identifier = item.get("id")
        canonical_name = item.get("canonical_name")
        if not isinstance(identifier, str) or not identifier:
            raise ConversionError(f"{bank_id}: entity artifact is missing an id")
        if not isinstance(canonical_name, str) or not canonical_name.strip():
            raise ConversionError(f"{bank_id}: entity {identifier} is missing a canonical name")
        name = canonical_name.strip()
        tokens = entity_name_tokens(name)
        prepared.append((bank_id, profile, item, name, tokens))
        if tokens:
            groups[tokens].append((bank_id, profile, item))

    ambiguous = {tokens for tokens, group in groups.items() if len(group) > 1}
    for bank_id, _profile, item, name, tokens in prepared:
        key = (bank_id, str(item["id"]))
        cjk_count = sum(1 for character in name if is_cjk(character))
        count = item.get("mention_count")
        mention_count = count if isinstance(count, int) and not isinstance(count, bool) else 0
        unsafe_surface = (
            any(character in name for character in ("/", "\\", "_"))
            or "://" in name
            or name.endswith("()")
            or re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?", name) is not None
            or re.search(r"\.[A-Za-z0-9]{1,8}$", name) is not None
            or not any(character.isalpha() for character in name)
        )
        if not tokens:
            reason = "no_linkable_tokens"
        elif tokens in ambiguous:
            reason = "ambiguous_name"
        elif name.startswith("@") and not any(character.isspace() for character in name):
            reason = "bare_handle"
        elif cjk_count and cjk_count < 2:
            reason = "short_name"
        elif not cjk_count and len(name) < 4:
            reason = "short_name"
        elif mention_count < MIN_ENTITY_MENTIONS:
            reason = "low_evidence"
        elif len(tokens) == 1 and tokens[0] in GENERIC_ENTITY_TOKENS:
            reason = "generic_single_token"
        elif unsafe_surface:
            reason = "identifier_like"
        elif len(tokens) == 1 and name == name.lower():
            reason = "lowercase_single_token"
        else:
            decisions[key] = {"status": "linkable", "reason": "high_confidence"}
            continue
        decisions[key] = {"status": "suppressed", "reason": reason}

    reasons: dict[str, int] = {}
    for decision in decisions.values():
        reason = str(decision["reason"])
        reasons[reason] = reasons.get(reason, 0) + 1
    report = {
        "policy_version": 1,
        "minimum_mention_count": MIN_ENTITY_MENTIONS,
        "linkable": sum(1 for decision in decisions.values() if decision["status"] == "linkable"),
        "suppressed": sum(1 for decision in decisions.values() if decision["status"] == "suppressed"),
        "ambiguous_name_groups": len(ambiguous),
        "reasons": dict(sorted(reasons.items())),
    }
    return decisions, report


def render_page(
    kind: str,
    bank_id: str,
    profile: str,
    item: dict[str, Any],
    entity_quality: dict[str, Any] | None = None,
) -> str:
    identifier = item.get("id")
    if not isinstance(identifier, str) or not identifier:
        raise ConversionError(f"{bank_id}: {kind} artifact is missing an id")
    title = f"Hindsight {kind.replace('_', ' ')} {identifier}"
    page_type = "note"
    if kind == "entity":
        canonical_name = item.get("canonical_name")
        if not isinstance(canonical_name, str) or not canonical_name.strip():
            raise ConversionError(
                f"{bank_id}: entity {identifier} is missing a canonical name"
            )
        title = canonical_name.strip()
        if entity_quality is None:
            raise ConversionError(f"{bank_id}: entity {identifier} has no quality decision")
        page_type = "entity" if entity_quality["status"] == "linkable" else "note"
    kind_tag = kind.replace("_", "-")
    fields: dict[str, Any] = {
        "title": title,
        "type": page_type,
        "tags": sorted({"hindsight-import", f"hindsight-{kind_tag}", *string_list(item.get("tags"))}),
        "source": "hindsight",
        "hindsight_bank_id": bank_id,
        "hindsight_profile": profile,
        "hindsight_kind": kind,
        "hindsight_id": identifier,
        "created_at": item.get("created_at"),
        "updated_at": item.get("updated_at") or item.get("edited_at"),
        "occurred_start": item.get("occurred_start"),
        "occurred_end": item.get("occurred_end"),
        "mentioned_at": item.get("mentioned_at"),
        "hindsight_document_id": item.get("document_id"),
        "hindsight_fact_type": item.get("fact_type"),
        "hindsight_state": item.get("state"),
    }
    if entity_quality is not None:
        fields.update(
            {
                "hindsight_entity_status": entity_quality["status"],
                "hindsight_entity_quality_reason": entity_quality["reason"],
            }
        )
    body = frontmatter(fields) + f"# {fields['title']}\n"
    if kind == "document":
        body += text_section("Original text", item.get("original_text"))
    elif kind in {"fact", "observation"}:
        body += text_section("Memory", item.get("text"))
        body += text_section("Context", item.get("context"))
    elif kind == "entity":
        body += text_section("Canonical name", item.get("canonical_name"))
    elif kind == "directive":
        body += text_section("Directive", item.get("content"))
    elif kind == "mental_model":
        body += text_section("Mental model", item.get("content") or item.get("text"))
    return body.rstrip() + "\n"


def write_artifact(
    corpus_root: Path,
    *,
    profile: str,
    bank_id: str,
    kind: str,
    item: dict[str, Any],
    files: list[dict[str, Any]],
    entity_quality: dict[str, Any] | None = None,
) -> None:
    identifier = item.get("id")
    if not isinstance(identifier, str) or not identifier:
        raise ConversionError(f"{bank_id}: {kind} artifact is missing an id")
    slug = artifact_slug(identifier)
    category = {
        "document": "documents",
        "fact": "memories/facts",
        "observation": "memories/observations",
        "entity": "entities",
        "directive": "directives",
        "mental_model": "mental-models",
    }[kind]
    base = corpus_root / "profiles" / profile / category
    markdown_path = base / f"{slug}.md"
    raw_path = base / ".raw" / f"{slug}.json"
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    markdown = render_page(kind, bank_id, profile, item, entity_quality).encode("utf-8")
    raw = canonical_json(item).encode("utf-8")
    markdown_path.write_bytes(markdown)
    raw_path.write_bytes(raw)
    files.append(
        {
            "bank_id": bank_id,
            "profile": profile,
            "kind": kind,
            "source_id": identifier,
            "markdown_path": markdown_path.relative_to(corpus_root).as_posix(),
            "markdown_sha256": sha256_bytes(markdown),
            "raw_path": raw_path.relative_to(corpus_root).as_posix(),
            "raw_sha256": sha256_bytes(raw),
        }
    )


def load_transfer_documents(archive: zipfile.ZipFile, bank_id: str) -> list[dict[str, Any]]:
    names = sorted(
        name for name in archive.namelist() if name.startswith("documents/") and name.endswith(".json")
    )
    result: list[dict[str, Any]] = []
    for name in names:
        try:
            result.append(require_object(json.loads(archive.read(name)), f"{bank_id}:{name}"))
        except (KeyError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise ConversionError(f"{bank_id}: invalid transfer document") from exc
    return result


def load_transfer_observations(archive: zipfile.ZipFile, bank_id: str) -> list[dict[str, Any]]:
    try:
        value = json.loads(archive.read("observations.json"))
    except (KeyError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ConversionError(f"{bank_id}: invalid transfer observations") from exc
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise ConversionError(f"{bank_id}: transfer observations are not an object list")
    return value


def unique_ids(items: Iterable[dict[str, Any]], bank_id: str, kind: str) -> None:
    seen: set[str] = set()
    for item in items:
        identifier = item.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in seen:
            raise ConversionError(f"{bank_id}: duplicate or invalid {kind} id")
        seen.add(identifier)


def convert_backup(backup_dir: Path, output_dir: Path) -> dict[str, Any]:
    backup_dir = backup_dir.resolve()
    output_dir = output_dir.resolve()
    if output_dir.exists():
        raise ConversionError(f"Refusing to replace existing output directory: {output_dir}")

    validator = load_validator()
    try:
        validation = validator.validate_backup(backup_dir)
    except validator.ValidationError as exc:
        raise ConversionError(f"Source backup validation failed: {exc}") from exc

    source_manifest_path = backup_dir / "manifest.json"
    source_manifest = json.loads(source_manifest_path.read_text(encoding="utf-8"))
    bank_summaries = source_manifest.get("banks")
    if not isinstance(bank_summaries, list):
        raise ConversionError("Validated backup manifest has no bank list")

    profile_map: dict[str, str] = {}
    for summary in bank_summaries:
        bank_id = summary.get("bank_id") if isinstance(summary, dict) else None
        if not isinstance(bank_id, str):
            raise ConversionError("Validated backup has an invalid bank id")
        profile = profile_for_bank(bank_id)
        if profile in profile_map:
            raise ConversionError(f"Multiple banks map to GBrain profile {profile!r}")
        profile_map[profile] = bank_id

    entities_by_bank: dict[str, list[dict[str, Any]]] = {}
    entity_records: list[tuple[str, str, dict[str, Any]]] = []
    for profile, bank_id in sorted(profile_map.items()):
        entities = require_items(backup_dir / "banks" / bank_id / "entities.json")
        unique_ids(entities, bank_id, "entity")
        entities_by_bank[bank_id] = entities
        entity_records.extend((bank_id, profile, item) for item in entities)
    entity_decisions, entity_quality_report = entity_quality_decisions(entity_records)

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.tmp-", dir=output_dir.parent))
    try:
        files: list[dict[str, Any]] = []
        supplemental_files: list[dict[str, Any]] = []
        bank_reports: list[dict[str, Any]] = []
        for profile, bank_id in sorted(profile_map.items()):
            bank_dir = backup_dir / "banks" / bank_id
            memories = require_items(bank_dir / "memories.json")
            entities = entities_by_bank[bank_id]
            directives = require_items(bank_dir / "directives.json")
            mental_models = require_items(bank_dir / "mental-models.json")
            with zipfile.ZipFile(bank_dir / "document-transfer.zip") as archive:
                documents = load_transfer_documents(archive, bank_id)
                transfer_observations = load_transfer_observations(archive, bank_id)

            # The transfer representation uniquely carries observation sources
            # and scopes, but no stable observation ID. Preserve the complete
            # list rather than guessing a correlation to memories.json records.
            observations_path = (
                temporary / "profiles" / profile / ".raw" / "hindsight-transfer-observations.json"
            )
            observations_path.parent.mkdir(parents=True, exist_ok=True)
            observations_raw = canonical_json(transfer_observations).encode("utf-8")
            observations_path.write_bytes(observations_raw)
            supplemental_files.append(
                {
                    "bank_id": bank_id,
                    "profile": profile,
                    "kind": "transfer_observations",
                    "path": observations_path.relative_to(temporary).as_posix(),
                    "sha256": sha256_bytes(observations_raw),
                    "records": len(transfer_observations),
                }
            )

            facts = [item for item in memories if item.get("fact_type") != "observation"]
            observations = [item for item in memories if item.get("fact_type") == "observation"]
            for kind, items in (
                ("document", documents),
                ("fact", facts),
                ("observation", observations),
                ("entity", entities),
                ("directive", directives),
                ("mental_model", mental_models),
            ):
                unique_ids(items, bank_id, kind)
                for item in sorted(items, key=lambda value: str(value["id"])):
                    write_artifact(
                        temporary,
                        profile=profile,
                        bank_id=bank_id,
                        kind=kind,
                        item=item,
                        files=files,
                        entity_quality=(
                            entity_decisions[(bank_id, str(item["id"]))]
                            if kind == "entity"
                            else None
                        ),
                    )
            bank_reports.append(
                {
                    "bank_id": bank_id,
                    "profile": profile,
                    "counts": {
                        "directives": len(directives),
                        "documents": len(documents),
                        "entities": len(entities),
                        "facts": len(facts),
                        "mental_models": len(mental_models),
                        "observations": len(observations),
                    },
                }
            )

        files.sort(key=lambda item: item["markdown_path"])
        supplemental_files.sort(key=lambda item: item["path"])
        manifest = {
            "schema_version": CONVERTER_SCHEMA_VERSION,
            "converter": "convert-hindsight-backup-to-gbrain.py",
            "gbrain_compatibility_ref": GBRAIN_REF,
            "source": {
                "backup_timestamp": validation.get("backup_timestamp"),
                "manifest_sha256": sha256_file(source_manifest_path),
                "validated_totals": validation.get("totals"),
            },
            "entity_quality": entity_quality_report,
            "banks": bank_reports,
            "files": files,
            "supplemental_files": supplemental_files,
        }
        (temporary / "manifest.json").write_text(canonical_json(manifest), encoding="utf-8")
        os.replace(temporary, output_dir)
        return manifest
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def summary(manifest: dict[str, Any], output_dir: Path) -> dict[str, Any]:
    totals = {
        "banks": len(manifest["banks"]),
        "markdown_files": len(manifest["files"]),
        "raw_files": len(manifest["files"]) + len(manifest["supplemental_files"]),
    }
    for bank in manifest["banks"]:
        for key, value in bank["counts"].items():
            totals[key] = totals.get(key, 0) + value
    return {"output_dir": str(output_dir.resolve()), "totals": totals}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Convert a validated Hindsight backup to a staged GBrain Markdown corpus"
    )
    parser.add_argument("--backup-dir", type=Path, required=True, help="Validated Hindsight backup directory")
    parser.add_argument("--output-dir", type=Path, required=True, help="New output directory; must not exist")
    parser.add_argument("--report", type=Path, help="Optional content-free JSON summary path")
    args = parser.parse_args()
    try:
        manifest = convert_backup(args.backup_dir, args.output_dir)
        report = summary(manifest, args.output_dir)
    except (ConversionError, OSError, zipfile.BadZipFile) as exc:
        print(f"Conversion failed: {exc}", file=sys.stderr)
        return 1
    rendered = canonical_json(report)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

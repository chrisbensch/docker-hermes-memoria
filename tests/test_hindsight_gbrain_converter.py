import hashlib
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_script(filename: str, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def write_json(path: Path, value):
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")


def make_backup(root: Path) -> Path:
    bank_id = "hermes-test"
    backup = root / "backup"
    bank = backup / "banks" / bank_id
    (bank / "documents").mkdir(parents=True)

    document = {
        "id": "doc/one",
        "created_at": "2026-09-24T01:00:00Z",
        "original_text": "A private-looking fixture value, not a real secret.",
        "facts": [],
        "chunks": [],
        "retain_params": {},
        "tags": ["fixture"],
    }
    fact = {
        "id": "fact:one",
        "document_id": "doc/one",
        "fact_type": "world",
        "state": "valid",
        "text": "The fixture service uses a test database.",
        "context": "Synthetic test context.",
        "tags": ["fixture"],
    }
    observation = {
        "id": "observation:one",
        "fact_type": "observation",
        "state": "valid",
        "text": "The synthetic migration was reviewed.",
        "proof_count": 1,
        "tags": [],
    }
    entity = {"id": "entity:one", "canonical_name": "Fixture Service", "mention_count": 2}
    directive = {"id": "directive:one", "name": "Fixture", "content": "Use fixture values only."}
    model = {"id": "model:one", "text": "A synthetic mental model."}

    archive_path = bank / "document-transfer.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr(
            "manifest.json",
            json.dumps(
                {
                    "schema_version": 1,
                    "source_bank_id": bank_id,
                    "archive_type": "documents",
                    "document_count": 1,
                    "fact_count": 1,
                    "observation_count": 1,
                }
            ),
        )
        archive.writestr("documents/000000.json", json.dumps(document))
        archive.writestr(
            "observations.json",
            json.dumps(
                [
                    {
                        "text": observation["text"],
                        "sources": [{"document_id": "doc/one"}],
                        "observation_scopes": ["fixture-scope"],
                    }
                ]
            ),
        )

    write_json(bank / "bank-config.json", {"version": "fixture"})
    write_json(bank / "memories.json", {"items": [observation, fact], "total": 2})
    write_json(bank / "entities.json", {"items": [entity], "total": 1})
    write_json(bank / "mental-models.json", {"items": [model]})
    write_json(bank / "directives.json", {"items": [directive]})
    write_json(bank / "documents.json", {"items": [{"id": document["id"]}], "total": 1})
    write_json(bank / "documents" / "doc-one.json", {"id": document["id"]})

    write_json(
        backup / "manifest.json",
        {
            "backup_timestamp": "2026-09-24T01:02:03Z",
            "api_url": "http://fixture.invalid",
            "total_banks": 1,
            "banks": [
                {
                    "bank_id": bank_id,
                    "sections": {
                        "memories.json": 2,
                        "entities.json": 1,
                        "documents.json": 1,
                        "document-transfer.zip": {
                            "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
                            "documents": 1,
                            "facts": 1,
                            "observations": 1,
                        },
                    },
                }
            ],
        },
    )
    return backup


class HindsightGBrainConverterTests(unittest.TestCase):
    def setUp(self):
        self.converter = load_script(
            "convert-hindsight-backup-to-gbrain.py", "hindsight_gbrain_converter"
        )

    def test_conversion_preserves_profiles_provenance_and_raw_payloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            backup = make_backup(root)
            output = root / "corpus"
            manifest = self.converter.convert_backup(backup, output)

            self.assertEqual(manifest["banks"][0]["profile"], "test")
            self.assertEqual(
                manifest["banks"][0]["counts"],
                {
                    "directives": 1,
                    "documents": 1,
                    "entities": 1,
                    "facts": 1,
                    "mental_models": 1,
                    "observations": 1,
                },
            )
            fact_entry = next(item for item in manifest["files"] if item["kind"] == "fact")
            fact_markdown = (output / fact_entry["markdown_path"]).read_text(encoding="utf-8")
            entity_entry = next(item for item in manifest["files"] if item["kind"] == "entity")
            entity_markdown = (output / entity_entry["markdown_path"]).read_text(
                encoding="utf-8"
            )
            raw_fact = json.loads((output / fact_entry["raw_path"]).read_text(encoding="utf-8"))
            observations_entry = manifest["supplemental_files"][0]
            transfer_observations = json.loads(
                (output / observations_entry["path"]).read_text(encoding="utf-8")
            )

            self.assertIn('hindsight_bank_id: "hermes-test"', fact_markdown)
            self.assertIn('type: "note"', fact_markdown)
            self.assertIn("The fixture service uses a test database.", fact_markdown)
            self.assertIn('title: "Fixture Service"', entity_markdown)
            self.assertIn('type: "entity"', entity_markdown)
            self.assertIn('hindsight_entity_status: "linkable"', entity_markdown)
            self.assertIn('hindsight_entity_quality_reason: "high_confidence"', entity_markdown)
            self.assertIn("# Fixture Service", entity_markdown)
            self.assertEqual(
                manifest["entity_quality"],
                {
                    "policy_version": 1,
                    "minimum_mention_count": 2,
                    "linkable": 1,
                    "suppressed": 0,
                    "ambiguous_name_groups": 0,
                    "reasons": {"high_confidence": 1},
                },
            )
            self.assertEqual(raw_fact["id"], "fact:one")
            self.assertEqual(len(manifest["files"]), 6)
            self.assertEqual(observations_entry["records"], 1)
            self.assertEqual(transfer_observations[0]["observation_scopes"], ["fixture-scope"])
            self.assertEqual(transfer_observations[0]["sources"], [{"document_id": "doc/one"}])

    def test_two_conversions_are_byte_identical(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            backup = make_backup(root)
            first = root / "first"
            second = root / "second"
            self.converter.convert_backup(backup, first)
            self.converter.convert_backup(backup, second)

            first_files = sorted(path.relative_to(first) for path in first.rglob("*") if path.is_file())
            second_files = sorted(path.relative_to(second) for path in second.rglob("*") if path.is_file())
            self.assertEqual(first_files, second_files)
            for relative in first_files:
                self.assertEqual((first / relative).read_bytes(), (second / relative).read_bytes())

    def test_existing_output_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            backup = make_backup(root)
            output = root / "corpus"
            output.mkdir()
            marker = output / "keep"
            marker.write_text("unchanged", encoding="utf-8")

            with self.assertRaisesRegex(self.converter.ConversionError, "Refusing to replace"):
                self.converter.convert_backup(backup, output)
            self.assertEqual(marker.read_text(encoding="utf-8"), "unchanged")

    def test_invalid_backup_is_rejected_without_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            backup = make_backup(root)
            (backup / "banks" / "hermes-test" / "document-transfer.zip").write_bytes(b"broken")
            output = root / "corpus"

            with self.assertRaisesRegex(self.converter.ConversionError, "validation failed"):
                self.converter.convert_backup(backup, output)
            self.assertFalse(output.exists())

    def test_entity_without_canonical_name_is_rejected_without_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            backup = make_backup(root)
            entities_path = backup / "banks" / "hermes-test" / "entities.json"
            write_json(
                entities_path,
                {"items": [{"id": "entity:one", "canonical_name": "   "}], "total": 1},
            )
            output = root / "corpus"

            with self.assertRaisesRegex(self.converter.ConversionError, "canonical name"):
                self.converter.convert_backup(backup, output)
            self.assertFalse(output.exists())

    def test_entity_quality_deduplicates_names_and_suppresses_generic_roles(self):
        records = [
            (
                "hermes-alpha",
                "alpha",
                {"id": "entity:alpha", "canonical_name": "Headroom proxy", "mention_count": 2},
            ),
            (
                "hermes-beta",
                "beta",
                {"id": "entity:beta", "canonical_name": "HEADROOM-PROXY", "mention_count": 5},
            ),
            (
                "hermes-alpha",
                "alpha",
                {"id": "entity:user", "canonical_name": "user", "mention_count": 20},
            ),
            (
                "hermes-alpha",
                "alpha",
                {"id": "entity:mcp", "canonical_name": "MCP", "mention_count": 6},
            ),
        ]

        decisions, report = self.converter.entity_quality_decisions(records)

        self.assertEqual(decisions[("hermes-beta", "entity:beta")]["reason"], "ambiguous_name")
        self.assertEqual(decisions[("hermes-alpha", "entity:alpha")]["reason"], "ambiguous_name")
        self.assertEqual(
            decisions[("hermes-alpha", "entity:user")]["reason"],
            "generic_single_token",
        )
        self.assertEqual(decisions[("hermes-alpha", "entity:mcp")]["reason"], "short_name")
        self.assertEqual(report["linkable"], 0)
        self.assertEqual(report["suppressed"], 4)
        self.assertEqual(report["ambiguous_name_groups"], 1)


if __name__ == "__main__":
    unittest.main()

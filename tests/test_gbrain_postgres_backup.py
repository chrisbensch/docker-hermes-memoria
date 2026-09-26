import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def load_validator():
    path = Path(__file__).parents[1] / "scripts" / "validate-gbrain-postgres-backup.py"
    spec = importlib.util.spec_from_file_location("gbrain_backup_validator", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GBrainBackupValidatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.validator = load_validator()

    def make_backup(self, root: Path) -> tuple[Path, Path]:
        archive = root / "gbrain-postgres.dump"
        archive.write_bytes(b"synthetic-custom-archive")
        metadata = Path(f"{archive}.json")
        metadata.write_text(
            json.dumps(
                {
                    "database": "gbrain",
                    "format": "postgresql-custom",
                    "archive": archive.name,
                    "bytes": archive.stat().st_size,
                    "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                }
            ),
            encoding="utf-8",
        )
        return archive, metadata

    def test_checksum_only_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, metadata = self.make_backup(Path(directory))
            result = self.validator.validate(archive, metadata, "unused", skip_catalog=True)
            self.assertTrue(result["valid"])
            self.assertIsNone(result["catalog_entries"])

    def test_tampered_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, metadata = self.make_backup(Path(directory))
            archive.write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "metadata mismatch"):
                self.validator.validate(archive, metadata, "unused", skip_catalog=True)

    def test_catalog_must_have_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, metadata = self.make_backup(root)
            fake = root / "pg_restore"
            fake.write_text("#!/bin/sh\nprintf '; archive header\\n1; 0 0 TABLE public facts gbrain\\n'\n", encoding="utf-8")
            fake.chmod(0o700)
            result = self.validator.validate(archive, metadata, str(fake))
            self.assertEqual(result["catalog_entries"], 1)

    def test_metabase_metadata_can_be_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, metadata = self.make_backup(Path(directory))
            payload = json.loads(metadata.read_text(encoding="utf-8"))
            payload["database"] = "metabase"
            metadata.write_text(json.dumps(payload), encoding="utf-8")
            result = self.validator.validate(
                archive, metadata, "unused", skip_catalog=True, database="metabase"
            )
            self.assertEqual(result["database"], "metabase")


if __name__ == "__main__":
    unittest.main()

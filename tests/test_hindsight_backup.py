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


def transfer_archive() -> bytes:
    with tempfile.TemporaryDirectory() as temporary:
        archive_path = Path(temporary) / "document-transfer.zip"
        manifest = {
            "schema_version": 1,
            "source_bank_id": "hermes-test",
            "archive_type": "documents",
            "document_count": 1,
            "fact_count": 1,
            "observation_count": 1,
        }
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr("manifest.json", json.dumps(manifest))
            archive.writestr("documents/000000.json", "{}")
            archive.writestr("observations.json", "[]")
        return archive_path.read_bytes()


class RecordingExportClient:
    def __init__(self, *, drift: bool = False):
        self.calls = []
        self.drift = drift
        self.bank_calls = 0

    def request_json(self, method, path):
        self.calls.append((method, path))
        bare_path = path.split("?", 1)[0]
        if method == "GET" and bare_path == "/health":
            return {"status": "healthy"}
        if method == "GET" and bare_path == "/version":
            return {"api_version": "0.8.4", "features": {"document_import_api": True}}
        if method == "GET" and bare_path == "/v1/default/banks":
            self.bank_calls += 1
            fact_count = 3 if self.drift and self.bank_calls > 1 else 2
            return {"banks": [{"bank_id": "hermes-test", "fact_count": fact_count}]}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/export":
            return {"bank_id": "hermes-test", "config": {}}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/memories/list":
            return {"items": [{"id": "fact-1"}, {"id": "observation-1"}], "total": 2}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/entities":
            offset = int(path.split("offset=", 1)[1])
            if offset == 0:
                return {"items": [{"id": str(index)} for index in range(100)], "total": 101}
            return {"items": [{"id": "100"}], "total": 101}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/documents":
            return {"items": [{"id": "doc-1"}], "total": 1}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/documents/doc-1":
            return {"id": "doc-1", "content": "document"}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/mental-models":
            return {"items": []}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/directives":
            return {"items": []}
        raise AssertionError(f"Unexpected request: {method} {path}")

    def request_bytes(self, method, path):
        self.calls.append((method, path))
        self.assert_equal(method, "GET")
        self.assert_equal(path, "/v1/default/banks/hermes-test/document-transfer?include_observations=true")
        return transfer_archive()

    def assert_equal(self, actual, expected):
        if actual != expected:
            raise AssertionError(f"Expected {expected!r}, got {actual!r}")


class HindsightBackupTests(unittest.TestCase):
    def setUp(self):
        self.backup = load_script("backup-hindsight-banks.py", "hindsight_backup")

    def test_export_paginates_preserves_observations_and_validates(self):
        client = RecordingExportClient()
        with tempfile.TemporaryDirectory() as temporary:
            report = self.backup.export_backup(client, Path(temporary), "backup")
            backup_dir = Path(temporary) / "backup"
            manifest = json.loads((backup_dir / "manifest.json").read_text(encoding="utf-8"))
            validation = self.backup.load_validator().validate_backup(backup_dir)

        self.assertEqual(validation["totals"], {"banks": 1, "documents": 1, "facts": 1, "observations": 1, "memories": 2})
        self.assertEqual(report["totals"], validation["totals"])
        self.assertIn(("GET", "/v1/default/banks/hermes-test/entities?limit=100&offset=100"), client.calls)
        self.assertEqual(manifest["banks"][0]["sections"]["document-transfer.zip"]["observations"], 1)

    def test_export_rejects_source_count_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(self.backup.BackupError, "changed during export"):
                self.backup.export_backup(RecordingExportClient(drift=True), Path(temporary), "backup")


if __name__ == "__main__":
    unittest.main()

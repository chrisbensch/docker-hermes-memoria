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


def make_backup(root: Path, *, include_observations: bool = True) -> Path:
    bank_id = "hermes-test"
    backup = root / "backup"
    bank_dir = backup / "banks" / bank_id
    documents_dir = bank_dir / "documents"
    documents_dir.mkdir(parents=True)
    (documents_dir / "doc-1.json").write_text("{}\n", encoding="utf-8")

    transfer_manifest = {
        "schema_version": 1,
        "source_bank_id": bank_id,
        "archive_type": "documents",
        "document_count": 1,
        "fact_count": 1,
        "observation_count": 1,
    }
    archive_path = bank_dir / "document-transfer.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr("manifest.json", json.dumps(transfer_manifest))
        archive.writestr("documents/000000.json", "{}")
        if include_observations:
            archive.writestr("observations.json", "[]")

    payloads = {
        "bank-config.json": {},
        "memories.json": {"items": [{}, {}], "total": 2, "limit": 100, "offset": 0},
        "entities.json": {"items": [], "total": 0, "limit": 100, "offset": 0},
        "mental-models.json": {"items": []},
        "directives.json": {"items": []},
        "documents.json": {"items": [{"id": "doc-1"}], "total": 1, "limit": 100, "offset": 0},
    }
    for filename, payload in payloads.items():
        (bank_dir / filename).write_text(json.dumps(payload) + "\n", encoding="utf-8")

    manifest = {
        "backup_timestamp": "2026-07-11T03:56:29Z",
        "api_url": "http://old.example:9149",
        "total_banks": 1,
        "banks": [
            {
                "bank_id": bank_id,
                "sections": {
                    "memories.json": 2,
                    "entities.json": 0,
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
    }
    (backup / "manifest.json").write_text(json.dumps(manifest) + "\n", encoding="utf-8")
    return backup


class RecordingClient:
    def __init__(self, *, operation_status: str = "completed"):
        self.calls = []
        self.operation_status = operation_status

    def request_json(self, method, path, payload=None):
        self.calls.append((method, path, payload))
        bare_path = path.split("?", 1)[0]
        if method == "GET" and bare_path == "/health":
            return {"status": "healthy"}
        if method == "GET" and bare_path == "/version":
            return {"api_version": "0.8.4", "features": {"document_import_api": True}}
        if method == "GET" and bare_path == "/openapi.json":
            return {
                "paths": {
                    "/v1/default/banks/{bank_id}": {"put": {}},
                    "/v1/default/banks/{bank_id}/document-transfer": {"post": {}},
                    "/v1/default/banks/{bank_id}/operations/{operation_id}": {"get": {}},
                }
            }
        if method == "GET" and bare_path == "/v1/default/banks":
            return {"banks": []}
        if method == "PUT" and bare_path == "/v1/default/banks/hermes-test":
            return {"bank_id": "hermes-test"}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/config":
            return {"bank_id": "hermes-test", "config": {}, "overrides": {}}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/operations/op-1":
            return {"operation_id": "op-1", "status": self.operation_status, "result_metadata": {}}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/documents":
            return {"items": [{"id": "doc-1"}], "total": 1, "limit": 100, "offset": 0}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/memories/list":
            return {"items": [{}, {}], "total": 2, "limit": 100, "offset": 0}
        if method == "GET" and bare_path == "/v1/default/banks/hermes-test/entities":
            return {"items": [], "total": 0, "limit": 100, "offset": 0}
        raise AssertionError(f"Unexpected request: {method} {path} {payload}")

    def request_multipart(self, method, path, field_name, file_path):
        self.calls.append((method, path, {field_name: str(file_path)}))
        assert file_path.name == "document-transfer.zip"
        return {"operation_id": "op-1"}


class BackupValidatorTests(unittest.TestCase):
    def setUp(self):
        self.validator = load_script("validate-hindsight-bank-backup.py", "hindsight_validator")

    def test_valid_backup_reports_expected_counts(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = self.validator.validate_backup(make_backup(Path(temporary)))
        self.assertEqual(report["totals"], {"banks": 1, "documents": 1, "facts": 1, "observations": 1, "memories": 2})

    def test_backup_without_observations_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(self.validator.ValidationError, "observations.json"):
                self.validator.validate_backup(make_backup(Path(temporary), include_observations=False))


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.restore = load_script("restore-hindsight-bank-backup.py", "hindsight_restore")

    def test_dry_run_uses_only_get_requests(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = RecordingClient()
            report = self.restore.run_restore(client, make_backup(Path(temporary)), apply=False, sleep_fn=lambda _: None)
        self.assertEqual(report["mode"], "dry-run")
        self.assertEqual({method for method, _, _ in client.calls}, {"GET"})

    def test_apply_snapshots_before_bank_creation_and_verifies_counts(self):
        with tempfile.TemporaryDirectory() as temporary:
            events = []
            client = RecordingClient()
            report = self.restore.run_restore(
                client,
                make_backup(Path(temporary)),
                apply=True,
                snapshotter=lambda _: events.append("snapshot"),
                sleep_fn=lambda _: None,
            )
        first_put = next(index for index, call in enumerate(client.calls) if call[0] == "PUT")
        self.assertEqual(events, ["snapshot"])
        self.assertEqual(report["banks"]["hermes-test"]["counts"], {"documents": 1, "memories": 2, "entities": 0})
        self.assertGreater(first_put, 0)

    def test_failed_operation_stops_restore(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(self.restore.RestoreError, "did not complete"):
                self.restore.run_restore(
                    RecordingClient(operation_status="failed"),
                    make_backup(Path(temporary)),
                    apply=True,
                    snapshotter=lambda _: None,
                    sleep_fn=lambda _: None,
                )


if __name__ == "__main__":
    unittest.main()

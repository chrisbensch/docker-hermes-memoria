import importlib.util
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "remove-hindsight-profile-config.py"
SPEC = importlib.util.spec_from_file_location("remove_hindsight", SCRIPT)
assert SPEC and SPEC.loader
remove_hindsight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(remove_hindsight)


class RemoveHindsightProfileConfigTests(unittest.TestCase):
    def test_removes_only_hindsight_mapping(self):
        source = (
            "mcp_servers:\n"
            "  hindsight:\n"
            "    url: http://hindsight-mcp:8888/mcp/test/\n"
            "    enabled: true\n"
            "  gbrain:\n"
            "    url: http://gbrain-mcp:3132/mcp/test\n"
            "  headroom:\n"
            "    enabled: true\n"
        )
        result, removed = remove_hindsight.remove_hindsight_block(source)
        self.assertTrue(removed)
        self.assertNotIn("hindsight", result)
        self.assertIn("gbrain:", result)
        self.assertIn("headroom:", result)

    def test_does_not_remove_unrelated_nested_hindsight_key(self):
        source = "other:\n  hindsight:\n    enabled: true\nmcp_servers:\n  gbrain:\n    enabled: true\n"
        result, removed = remove_hindsight.remove_hindsight_block(source)
        self.assertFalse(removed)
        self.assertEqual(result, source)

    def test_apply_creates_backup_manifest_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            data_dir = Path(temporary)
            config = data_dir / "profiles" / "research" / "config.yaml"
            config.parent.mkdir(parents=True)
            config.write_text(
                "mcp_servers:\n  hindsight:\n    enabled: true\n  gbrain:\n    enabled: true\n",
                encoding="utf-8",
            )
            fixed_time = datetime(2026, 9, 26, tzinfo=timezone.utc)
            remove_hindsight.migrate_profiles(data_dir, apply=True, now=fixed_time)
            self.assertNotIn("hindsight:", config.read_text(encoding="utf-8"))
            backup = data_dir / "migration-backups/remove-hindsight-20260926T000000Z"
            self.assertTrue((backup / "profiles/research/config.yaml").is_file())
            manifest = __import__("json").loads((backup / "manifest.json").read_text())
            entry = manifest["profiles/research/config.yaml"]
            self.assertEqual(
                __import__("hashlib").sha256(
                    (backup / entry["backup"]).read_bytes()
                ).hexdigest(),
                entry["before_sha256"],
            )
            self.assertEqual(remove_hindsight.migrate_profiles(data_dir, apply=True), [])


if __name__ == "__main__":
    unittest.main()

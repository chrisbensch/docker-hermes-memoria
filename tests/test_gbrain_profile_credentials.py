import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load_script():
    path = ROOT / "scripts" / "prepare-gbrain-profile-credentials.py"
    spec = importlib.util.spec_from_file_location("gbrain_profile_credentials", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class GBrainProfileCredentialTests(unittest.TestCase):
    def setUp(self):
        self.script = load_script()

    def handoff(self, root: Path, *, profile: str = "memory-writer") -> Path:
        path = root / "handoff.json"
        path.write_text(
            json.dumps(
                {
                    "version": 1,
                    "mcp_url": "http://127.0.0.1:3131/mcp",
                    "issuer_url": "http://127.0.0.1:3131",
                    "client_id": "client-example",
                    "client_secret": "secret-example",
                    "profile": profile,
                }
            ),
            encoding="utf-8",
        )
        path.chmod(0o600)
        return path

    def test_prepares_distinct_private_files_without_printing_secrets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "profiles"
            with mock.patch("secrets.token_hex", return_value="a" * 64):
                result = self.script.prepare_credentials("maestro", self.handoff(root), output)
            broker = Path(result["broker_file"])
            hermes = Path(result["hermes_token_file"])
            self.assertEqual(stat_mode(output), 0o700)
            self.assertEqual(stat_mode(broker), 0o600)
            self.assertEqual(stat_mode(hermes), 0o600)
            self.assertIn("GBRAIN_OAUTH_CLIENT_ID=client-example", broker.read_text())
            self.assertIn("GBRAIN_BROKER_TOKEN=" + "a" * 64, broker.read_text())
            self.assertEqual(hermes.read_text(), "GBRAIN_MCP_PROXY_TOKEN=" + "a" * 64 + "\n")
            self.assertNotIn("secret-example", json.dumps(result))

    def test_refuses_existing_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "profiles"
            output.mkdir(mode=0o700)
            (output / "maestro.env").write_text("keep", encoding="utf-8")
            with self.assertRaisesRegex(self.script.PreparationError, "already exists"):
                self.script.prepare_credentials("maestro", self.handoff(root), output)
            self.assertEqual((output / "maestro.env").read_text(), "keep")

    def test_rejects_insecure_or_overprivileged_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            handoff = self.handoff(root)
            handoff.chmod(0o644)
            with self.assertRaisesRegex(self.script.PreparationError, "mode 0600"):
                self.script.prepare_credentials("maestro", handoff, root / "profiles")
            handoff.chmod(0o600)
            unsafe = self.handoff(root, profile="full")
            with self.assertRaisesRegex(self.script.PreparationError, "memory-writer"):
                self.script.prepare_credentials("maestro", unsafe, root / "profiles")
            with self.assertRaisesRegex(self.script.PreparationError, "Profile must"):
                self.script.prepare_credentials("../bad", handoff, root / "profiles")


def stat_mode(path: Path) -> int:
    return path.stat().st_mode & 0o777


if __name__ == "__main__":
    unittest.main()

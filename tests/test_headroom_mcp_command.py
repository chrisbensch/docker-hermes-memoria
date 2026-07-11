import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load_script():
    path = ROOT / "scripts" / "fix-headroom-mcp-command.py"
    spec = importlib.util.spec_from_file_location("headroom_mcp_command", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class JsonYaml:
    @staticmethod
    def safe_load(stream):
        return json.load(stream)

    @staticmethod
    def safe_dump(value, stream, **_kwargs):
        json.dump(value, stream, indent=2)
        stream.write("\n")


class HeadroomMcpCommandTests(unittest.TestCase):
    def setUp(self):
        self.updater = load_script()

    def config(self, block=None):
        return {
            "model": {"provider": "custom", "secret": "keep-me"},
            "mcp_servers": {
                "other": {"command": "other-tool", "enabled": False},
                "headroom": block if block is not None else self.updater.old_block(),
            },
        }

    def write_profile(self, data_dir, profile, config):
        path = data_dir / "profiles" / profile / "config.yaml"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(config), encoding="utf-8")
        return path

    def run_profiles(self, data_dir, *, profiles=None, dry_run=False):
        return self.updater.process_data_dir(
            data_dir,
            profiles=profiles or [],
            dry_run=dry_run,
            timestamp="20260711T120000Z",
            yaml_module=JsonYaml,
        )

    def test_old_docker_command_is_rewritten_with_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            data_dir = Path(temporary)
            original = self.config()
            original["mcp_servers"]["headroom"].update({"enabled": False, "timeout": 45})
            path = self.write_profile(data_dir, "maestro", original)

            results = self.run_profiles(data_dir)

            self.assertEqual([result.status for result in results], ["changed"])
            updated = json.loads(path.read_text(encoding="utf-8"))
            expected = self.updater.new_block()
            expected["enabled"] = original["mcp_servers"]["headroom"]["enabled"]
            expected["timeout"] = original["mcp_servers"]["headroom"]["timeout"]
            self.assertEqual(updated["mcp_servers"]["headroom"], expected)
            self.assertEqual(updated["model"], original["model"])
            self.assertEqual(updated["mcp_servers"]["other"], original["mcp_servers"]["other"])
            backup = path.with_name("config.yaml.headroom-mcp-backup-20260711T120000Z")
            self.assertEqual(json.loads(backup.read_text(encoding="utf-8")), original)

    def test_dry_run_does_not_write_or_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            data_dir = Path(temporary)
            path = self.write_profile(data_dir, "maestro", self.config())
            before = path.read_bytes()

            results = self.run_profiles(data_dir, dry_run=True)

            self.assertEqual([result.status for result in results], ["changed"])
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(list(path.parent.glob("*.headroom-mcp-backup-*")), [])

    def test_malformed_yaml_failure_does_not_echo_contents(self):
        class FailingYaml(JsonYaml):
            @staticmethod
            def safe_load(_stream):
                raise ValueError("secret-token-from-config")

        with tempfile.TemporaryDirectory() as temporary:
            data_dir = Path(temporary)
            path = self.write_profile(data_dir, "maestro", self.config())

            results = self.updater.process_data_dir(
                data_dir,
                profiles=[],
                dry_run=False,
                timestamp="20260711T120000Z",
                yaml_module=FailingYaml,
            )

            self.assertEqual([result.status for result in results], ["failed"])
            self.assertNotIn("secret-token-from-config", results[0].detail)

    def test_new_sg_command_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            data_dir = Path(temporary)
            block = self.updater.new_block()
            block.update({"enabled": False, "timeout": 45})
            path = self.write_profile(data_dir, "maestro", self.config(block))
            before = path.read_bytes()

            first = self.run_profiles(data_dir)
            second = self.run_profiles(data_dir)

            self.assertEqual([result.status for result in first], ["already-correct"])
            self.assertEqual([result.status for result in second], ["already-correct"])
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(list(path.parent.glob("*.headroom-mcp-backup-*")), [])

    def test_custom_headroom_command_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            data_dir = Path(temporary)
            custom = {"command": "custom-wrapper", "args": ["serve"], "enabled": True, "timeout": 120}
            path = self.write_profile(data_dir, "maestro", self.config(custom))
            before = path.read_bytes()

            results = self.run_profiles(data_dir)

            self.assertEqual([result.status for result in results], ["failed"])
            self.assertIn("custom", results[0].detail)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(list(path.parent.glob("*.headroom-mcp-backup-*")), [])

    def test_selected_profiles_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            data_dir = Path(temporary)
            selected = self.write_profile(data_dir, "maestro", self.config())
            untouched = self.write_profile(data_dir, "research", self.config())
            untouched_before = untouched.read_bytes()

            results = self.run_profiles(data_dir, profiles=["maestro"])

            self.assertEqual([(result.profile, result.status) for result in results], [("maestro", "changed")])
            self.assertEqual(json.loads(selected.read_text())["mcp_servers"]["headroom"]["command"], "sg")
            self.assertEqual(untouched.read_bytes(), untouched_before)
            self.assertEqual(list(untouched.parent.glob("*.headroom-mcp-backup-*")), [])

    def test_missing_headroom_block_is_skipped(self):
        with tempfile.TemporaryDirectory() as temporary:
            data_dir = Path(temporary)
            config = self.config()
            del config["mcp_servers"]["headroom"]
            path = self.write_profile(data_dir, "maestro", config)
            before = path.read_bytes()

            results = self.run_profiles(data_dir)

            self.assertEqual([result.status for result in results], ["skipped"])
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(list(path.parent.glob("*.headroom-mcp-backup-*")), [])

    def test_host_mode_self_pipes_source_and_forwards_options(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary)
            (repo_root / ".env").write_text("APPDATA_DIR=./appdata\n", encoding="utf-8")
            self.updater.REPO_ROOT = repo_root
            completed = mock.Mock(returncode=0)

            with mock.patch.object(self.updater.subprocess, "run", return_value=completed) as run:
                status = self.updater.run_host(["maestro", "research"], True)

            self.assertEqual(status, 0)
            command = run.call_args.args[0]
            self.assertEqual(
                command[:10],
                [
                    "docker",
                    "compose",
                    "--env-file",
                    str(repo_root / ".env"),
                    "exec",
                    "-T",
                    "hermes",
                    "python",
                    "-",
                    "--inside-data-dir",
                ],
            )
            self.assertEqual(command[10:12], ["/opt/data", "--dry-run"])
            self.assertEqual(command[12:], ["--profile", "maestro", "--profile", "research"])
            self.assertTrue(run.call_args.kwargs["input"].startswith(b"#!/usr/bin/env python3"))
            self.assertEqual(run.call_args.kwargs["cwd"], repo_root)


if __name__ == "__main__":
    unittest.main()

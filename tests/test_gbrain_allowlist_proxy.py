#!/usr/bin/env python3
import json
import http.client
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "gbrain-allowlist-proxy"))
import server  # noqa: E402


class GBrainBrokerTests(unittest.TestCase):
    def write_profile(self, directory: Path, profile: str, token: str = "i" * 32) -> Path:
        path = directory / f"{profile}.env"
        path.write_text(
            "\n".join(
                (
                    f"GBRAIN_BROKER_TOKEN={token}",
                    f"GBRAIN_OAUTH_CLIENT_ID={profile}-client",
                    f"GBRAIN_OAUTH_CLIENT_SECRET={profile}-secret",
                )
            )
            + "\n",
            encoding="utf-8",
        )
        path.chmod(0o600)
        return path

    def test_policy_allows_protocol_basics_and_every_named_tool(self) -> None:
        for method in (
            "initialize",
            "notifications/initialized",
            "notifications/cancelled",
            "ping",
            "tools/list",
        ):
            self.assertEqual(server.allowed_request({"method": method}), (True, None))
        self.assertEqual(
            server.allowed_request(
                {"method": "tools/call", "params": {"name": "remember", "arguments": {}}}
            ),
            (True, None),
        )
        self.assertFalse(server.allowed_request({"method": "resources/list"})[0])
        self.assertFalse(server.allowed_request({"method": "tools/call", "params": {}})[0])

    def test_profile_path_is_deterministic_and_rejects_queries(self) -> None:
        self.assertEqual(server.parse_profile_path("/mcp/maestro"), "maestro")
        self.assertEqual(server.parse_profile_path("/mcp/team_one"), "team_one")
        self.assertIsNone(server.parse_profile_path("/mcp/maestro?profile=other"))
        self.assertIsNone(server.parse_profile_path("/mcp/../maestro"))
        self.assertIsNone(server.parse_profile_path("/mcp"))

    def test_bearer_parser_is_strict(self) -> None:
        self.assertEqual(server.bearer_token("Bearer " + "x" * 32), "x" * 32)
        for value in (None, "", "bearer token", "Bearer ", "Bearer two words"):
            self.assertIsNone(server.bearer_token(value))

    def test_authentication_requires_matching_route_and_uses_constant_time_compare(self) -> None:
        credentials = server.ProfileCredentials("maestro", "a" * 32, "id", "secret")
        upstream = server.UpstreamProfile(credentials, "http://gbrain/mcp", "http://gbrain/token")
        profiles = {"maestro": upstream}
        with mock.patch("hmac.compare_digest", wraps=server.hmac.compare_digest) as compare:
            self.assertIs(
                server.authenticate_profile("maestro", "a" * 32, profiles, "0" * 64), upstream
            )
            self.assertIsNone(
                server.authenticate_profile("other", "a" * 32, profiles, "0" * 64)
            )
            self.assertIsNone(
                server.authenticate_profile("maestro", "b" * 32, profiles, "0" * 64)
            )
        self.assertEqual(compare.call_count, 3)

    def test_http_boundary_denies_missing_wrong_and_unknown_profile_tokens(self) -> None:
        credentials = {
            "maestro": server.ProfileCredentials(
                "maestro", "a" * 32, "maestro-client", "maestro-secret"
            )
        }
        broker = server.BrokerServer(
            ("127.0.0.1", 0), credentials, "http://gbrain/mcp", "http://gbrain/token"
        )
        thread = threading.Thread(target=broker.serve_forever, daemon=True)
        thread.start()

        def post(path: str, authorization: str | None) -> tuple[int, bytes]:
            connection = http.client.HTTPConnection(*broker.server_address, timeout=2)
            headers = {"Content-Type": "application/json"}
            if authorization:
                headers["Authorization"] = authorization
            connection.request(
                "POST", path, body=b'{"jsonrpc":"2.0","id":1,"method":"ping"}', headers=headers
            )
            response = connection.getresponse()
            result = response.status, response.read()
            connection.close()
            return result

        try:
            missing = post("/mcp/maestro", None)
            wrong = post("/mcp/maestro", "Bearer " + "b" * 32)
            unknown = post("/mcp/unknown", "Bearer " + "a" * 32)
        finally:
            broker.shutdown()
            broker.server_close()
            thread.join(timeout=2)
        self.assertEqual(missing, (401, b'{"error":"unauthorized"}'))
        self.assertEqual(wrong, missing)
        self.assertEqual(unknown, missing)

    def test_loads_separate_profile_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            root.chmod(0o700)
            self.write_profile(root, "maestro", "a" * 32)
            self.write_profile(root, "research", "b" * 32)
            profiles = server.load_profile_credentials(str(root))
        self.assertEqual(set(profiles), {"maestro", "research"})
        self.assertEqual(profiles["maestro"].client_id, "maestro-client")
        self.assertEqual(profiles["research"].inbound_token, "b" * 32)

    def test_rejects_insecure_directory_and_file_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            root.chmod(0o755)
            self.write_profile(root, "maestro")
            with self.assertRaises(PermissionError):
                server.load_profile_credentials(str(root))

    def test_rejects_credentials_not_owned_by_broker_euid(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            root.chmod(0o700)
            credential = self.write_profile(root, "maestro")
            real_stat = Path.stat

            def wrong_owner(path: Path):
                result = real_stat(path)
                values = list(result)
                values[4] = os.geteuid() + 1
                return os.stat_result(values)

            with mock.patch.object(Path, "stat", wrong_owner):
                with self.assertRaises(PermissionError):
                    server.load_profile_credentials(str(root))

            real_lstat = Path.lstat

            def wrong_file_owner(path: Path):
                result = real_lstat(path)
                if path == credential:
                    values = list(result)
                    values[4] = os.geteuid() + 1
                    return os.stat_result(values)
                return result

            with mock.patch.object(Path, "lstat", wrong_file_owner):
                with self.assertRaises(PermissionError):
                    server.load_profile_credentials(str(root))
            root.chmod(0o700)
            (root / "maestro.env").chmod(0o640)
            with self.assertRaises(PermissionError):
                server.load_profile_credentials(str(root))

    def test_rejects_symlinks_unknown_fields_short_and_duplicate_tokens(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            root.chmod(0o700)
            target = self.write_profile(root, "maestro")
            os.symlink(target, root / "linked.env")
            with self.assertRaises(ValueError):
                server.load_profile_credentials(str(root))
            (root / "linked.env").unlink()
            target.write_text(target.read_text() + "EXTRA=value\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                server.load_profile_credentials(str(root))
            target.unlink()
            self.write_profile(root, "maestro", "short")
            with self.assertRaises(ValueError):
                server.load_profile_credentials(str(root))
            (root / "maestro.env").unlink()
            self.write_profile(root, "maestro", "z" * 32)
            self.write_profile(root, "research", "z" * 32)
            with self.assertRaises(ValueError):
                server.load_profile_credentials(str(root))

    def test_rejects_unsafe_filename_and_empty_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            root.chmod(0o700)
            with self.assertRaises(ValueError):
                server.load_profile_credentials(str(root))
            self.write_profile(root, "UPPER")
            with self.assertRaises(ValueError):
                server.load_profile_credentials(str(root))

    def test_url_validation(self) -> None:
        self.assertEqual(
            server.validate_upstream_url("http://gbrain:3131/mcp", "URL"),
            "http://gbrain:3131/mcp",
        )
        for url in ("gbrain:3131/mcp", "file:///secret", "http://user:pass@gbrain/mcp"):
            with self.assertRaises(ValueError):
                server.validate_upstream_url(url, "URL")

    def test_token_cache_is_per_profile(self) -> None:
        first = server.ProfileCredentials("first", "a" * 32, "first-id", "first-secret")
        second = server.ProfileCredentials("second", "b" * 32, "second-id", "second-secret")
        clients = [
            server.UpstreamProfile(first, "http://gbrain/mcp", "http://gbrain/token"),
            server.UpstreamProfile(second, "http://gbrain/mcp", "http://gbrain/token"),
        ]

        class Response:
            def __init__(self, token: str) -> None:
                self.payload = json.dumps({"access_token": token, "expires_in": 3600}).encode()

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, size: int = -1) -> bytes:
                if size == -1:
                    result, self.payload = self.payload, b""
                else:
                    result, self.payload = self.payload[:size], self.payload[size:]
                return result

        responses = iter((Response("upstream-first"), Response("upstream-second")))
        with mock.patch("urllib.request.urlopen", side_effect=lambda *_a, **_kw: next(responses)) as opened:
            self.assertEqual(clients[0].token(), "upstream-first")
            self.assertEqual(clients[0].token(), "upstream-first")
            self.assertEqual(clients[1].token(), "upstream-second")
        self.assertEqual(opened.call_count, 2)
        first_body = opened.call_args_list[0].args[0].data.decode()
        second_body = opened.call_args_list[1].args[0].data.decode()
        self.assertIn("client_id=first-id", first_body)
        self.assertIn("client_id=second-id", second_body)

    def test_upstream_401_refreshes_only_profile_token_and_retries_once(self) -> None:
        credentials = server.ProfileCredentials("maestro", "a" * 32, "id", "secret")
        client = server.UpstreamProfile(
            credentials, "http://gbrain/mcp", "http://gbrain/token"
        )
        client._token = "stale"
        client._token_expires_at = float("inf")
        attempts: list[str] = []

        def request_once(_method, _body, _headers, token):
            attempts.append(token)
            if token == "stale":
                return 401, "application/json", {}, b"unauthorized"
            return 200, "application/json", {}, b"ok"

        with (
            mock.patch.object(client, "_request_once", side_effect=request_once),
            mock.patch.object(client, "token", side_effect=("stale", "fresh")),
        ):
            result = client.request("POST", b"{}", {})
        self.assertEqual(attempts, ["stale", "fresh"])
        self.assertEqual(result[0], 200)
        self.assertEqual(client._token, "")

    def test_jsonrpc_error_is_sse(self) -> None:
        response = server.jsonrpc_error("write", "denied").decode()
        self.assertTrue(response.startswith("event: message\ndata: "))
        self.assertIn('"id":"write"', response)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "gbrain-allowlist-proxy"))
import server  # noqa: E402


class GBrainAllowlistProxyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.allowed = frozenset({"search"})

    def test_policy_allows_only_protocol_basics_and_search(self) -> None:
        self.assertEqual(server.allowed_request({"method": "initialize"}, self.allowed), (True, None))
        self.assertEqual(
            server.allowed_request(
                {"method": "tools/call", "params": {"name": "search", "arguments": {}}}, self.allowed
            ),
            (True, None),
        )
        self.assertFalse(
            server.allowed_request(
                {"method": "tools/call", "params": {"name": "put_page", "arguments": {}}}, self.allowed
            )[0]
        )
        self.assertFalse(server.allowed_request({"method": "resources/list"}, self.allowed)[0])

    def test_tools_list_filters_unallowlisted_tool_before_returning_it(self) -> None:
        upstream = {
            "jsonrpc": "2.0",
            "id": "tools",
            "result": {"tools": [{"name": "search"}, {"name": "put_page"}]},
        }
        filtered = server.filter_tools_list(
            f"event: message\ndata: {json.dumps(upstream)}\n\n".encode(), self.allowed
        ).decode()
        self.assertIn('"name":"search"', filtered)
        self.assertNotIn('"name":"put_page"', filtered)

    def test_blocked_request_uses_jsonrpc_error_sse(self) -> None:
        response = server.jsonrpc_error("write", "denied").decode()
        self.assertTrue(response.startswith("event: message\ndata: "))
        self.assertIn('"id":"write"', response)
        self.assertIn('"code":-32601', response)


if __name__ == "__main__":
    unittest.main()

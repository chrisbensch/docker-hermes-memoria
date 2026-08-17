#!/usr/bin/env python3
"""Minimal, policy-enforcing MCP proxy for the GBrain retrieval pilot.

The proxy is deliberately not a general MCP reverse proxy.  It permits the
small Phase 3 allowlist only, retrieves an upstream OAuth read token itself,
and filters tool discovery as well as tool calls.
"""

from __future__ import annotations

import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

MAX_REQUEST_BYTES = 1_048_576
SAFE_METHODS = frozenset({"initialize", "notifications/initialized", "ping", "tools/list"})


def sse_message(payload: dict[str, Any]) -> bytes:
    """Serialize one MCP response as a complete server-sent event."""
    return ("event: message\ndata: " + json.dumps(payload, separators=(",", ":")) + "\n\n").encode()


def jsonrpc_error(request_id: Any, message: str) -> bytes:
    return sse_message(
        {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": message}}
    )


def allowed_request(request: dict[str, Any], allowed_tools: frozenset[str]) -> tuple[bool, str | None]:
    """Return whether an MCP JSON-RPC request is within the local boundary."""
    method = request.get("method")
    if method in SAFE_METHODS:
        return True, None
    if method != "tools/call":
        return False, f"MCP method {method!r} is not permitted by the GBrain retrieval proxy"
    params = request.get("params")
    if not isinstance(params, dict):
        return False, "tools/call requires an object params value"
    tool_name = params.get("name")
    if tool_name not in allowed_tools:
        return False, f"GBrain tool {tool_name!r} is not permitted by the retrieval proxy"
    return True, None


def filter_tools_list(event_stream: bytes, allowed_tools: frozenset[str]) -> bytes:
    """Keep only allowlisted tools in GBrain's single-message SSE response."""
    lines = event_stream.decode("utf-8").splitlines()
    for line in lines:
        if not line.startswith("data: "):
            continue
        response = json.loads(line[6:])
        tools = response.get("result", {}).get("tools")
        if not isinstance(tools, list):
            raise ValueError("upstream tools/list response lacks result.tools")
        response["result"]["tools"] = [
            tool for tool in tools if isinstance(tool, dict) and tool.get("name") in allowed_tools
        ]
        return sse_message(response)
    raise ValueError("upstream tools/list response lacks an SSE data event")


def read_credentials(path: str) -> tuple[str, str]:
    values: dict[str, str] = {}
    with open(path, encoding="utf-8") as credential_file:
        for raw_line in credential_file:
            key, separator, value = raw_line.rstrip("\n").partition("=")
            if separator and key in {"GBRAIN_OAUTH_CLIENT_ID", "GBRAIN_OAUTH_CLIENT_SECRET"}:
                values[key] = value
    client_id = values.get("GBRAIN_OAUTH_CLIENT_ID", "")
    client_secret = values.get("GBRAIN_OAUTH_CLIENT_SECRET", "")
    if not client_id or not client_secret:
        raise ValueError("credentials file lacks GBrain OAuth client values")
    return client_id, client_secret


class Upstream:
    def __init__(self, mcp_url: str, token_url: str, credentials_file: str) -> None:
        self.mcp_url = mcp_url
        self.token_url = token_url
        self.client_id, self.client_secret = read_credentials(credentials_file)
        self._token = ""
        self._token_expires_at = 0.0
        self._lock = threading.Lock()

    def token(self) -> str:
        with self._lock:
            if self._token and time.monotonic() < self._token_expires_at:
                return self._token
            body = urllib.parse.urlencode(
                {
                    "grant_type": "client_credentials",
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                }
            ).encode()
            request = urllib.request.Request(self.token_url, data=body, method="POST")
            request.add_header("Content-Type", "application/x-www-form-urlencoded")
            with urllib.request.urlopen(request, timeout=10) as response:  # nosec B310 - deployment URL is fixed config
                token_response = json.load(response)
            token = token_response.get("access_token")
            if not isinstance(token, str) or not token:
                raise ValueError("upstream OAuth token response lacks access_token")
            expires_in = token_response.get("expires_in", 60)
            if not isinstance(expires_in, (int, float)):
                expires_in = 60
            self._token = token
            self._token_expires_at = time.monotonic() + max(1, expires_in - 15)
            return token

    def post(self, body: bytes) -> tuple[int, str, bytes]:
        request = urllib.request.Request(self.mcp_url, data=body, method="POST")
        request.add_header("Content-Type", "application/json")
        request.add_header("Accept", "application/json, text/event-stream")
        request.add_header("Authorization", f"Bearer {self.token()}")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:  # nosec B310 - deployment URL is fixed config
                return response.status, response.headers.get_content_type(), response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.headers.get_content_type(), error.read()


class Handler(BaseHTTPRequestHandler):
    server: "ProxyServer"
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/mcp":
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
            if length < 1 or length > MAX_REQUEST_BYTES:
                raise ValueError("request body exceeds proxy limit")
            raw_request = self.rfile.read(length)
            request = json.loads(raw_request)
            if not isinstance(request, dict):
                raise ValueError("MCP request must be a JSON object")
        except (ValueError, json.JSONDecodeError):
            self._send_sse(HTTPStatus.BAD_REQUEST, jsonrpc_error(None, "invalid MCP JSON-RPC request"))
            return

        permitted, reason = allowed_request(request, self.server.allowed_tools)
        if not permitted:
            self._send_sse(HTTPStatus.OK, jsonrpc_error(request.get("id"), reason or "request denied"))
            return
        try:
            status, content_type, upstream_body = self.server.upstream.post(raw_request)
            if request.get("method") == "tools/list" and status == HTTPStatus.OK:
                upstream_body = filter_tools_list(upstream_body, self.server.allowed_tools)
                content_type = "text/event-stream"
            self._send(status, content_type, upstream_body)
        except (OSError, ValueError, urllib.error.URLError, json.JSONDecodeError):
            self._send_sse(HTTPStatus.BAD_GATEWAY, jsonrpc_error(request.get("id"), "GBrain upstream is unavailable"))

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self.send_error(HTTPStatus.NOT_FOUND)

    def _send_sse(self, status: HTTPStatus, body: bytes) -> None:
        self._send(status, "text/event-stream", body)

    def _send(self, status: int | HTTPStatus, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        # Do not log request bodies or headers: either can carry sensitive data.
        return


class ProxyServer(ThreadingHTTPServer):
    def __init__(self, address: tuple[str, int], upstream: Upstream, allowed_tools: frozenset[str]) -> None:
        super().__init__(address, Handler)
        self.upstream = upstream
        self.allowed_tools = allowed_tools


def main() -> None:
    allowed_tools = frozenset(
        tool.strip() for tool in os.environ.get("GBRAIN_ALLOWED_TOOLS", "search").split(",") if tool.strip()
    )
    if not allowed_tools:
        raise SystemExit("GBRAIN_ALLOWED_TOOLS must contain at least one tool")
    upstream = Upstream(
        os.environ.get("GBRAIN_UPSTREAM_MCP_URL", "http://gbrain-http-test:3131/mcp"),
        os.environ.get("GBRAIN_UPSTREAM_TOKEN_URL", "http://gbrain-http-test:3131/token"),
        os.environ.get("GBRAIN_OAUTH_CREDENTIALS_FILE", "/run/gbrain-oauth/client.env"),
    )
    port = int(os.environ.get("PORT", "3132"))
    ProxyServer(("0.0.0.0", port), upstream, allowed_tools).serve_forever()


if __name__ == "__main__":
    main()

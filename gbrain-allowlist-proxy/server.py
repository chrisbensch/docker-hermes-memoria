#!/usr/bin/env python3
"""Authenticated, profile-aware MCP credential broker for shared GBrain."""

from __future__ import annotations

import hmac
import json
import os
import re
import stat
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Mapping

MAX_REQUEST_BYTES = 1_048_576
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,62}$")
MCP_POST_METHODS = frozenset(
    {
        "initialize",
        "notifications/initialized",
        "notifications/cancelled",
        "ping",
        "tools/list",
        "tools/call",
    }
)
FORWARDED_REQUEST_HEADERS = (
    "Accept",
    "MCP-Protocol-Version",
    "Mcp-Session-Id",
    "Last-Event-ID",
)
FORWARDED_RESPONSE_HEADERS = ("Mcp-Session-Id", "MCP-Protocol-Version")


def sse_message(payload: dict[str, Any]) -> bytes:
    """Serialize one JSON-RPC response as a complete server-sent event."""
    return ("event: message\ndata: " + json.dumps(payload, separators=(",", ":")) + "\n\n").encode()


def jsonrpc_error(request_id: Any, message: str) -> bytes:
    return sse_message(
        {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": message}}
    )


def allowed_request(request: Mapping[str, Any]) -> tuple[bool, str | None]:
    """Allow MCP lifecycle operations and every GBrain tool call.

    Tool authority belongs to the profile's GBrain OAuth client configuration,
    not to a second list maintained by this broker.
    """
    method = request.get("method")
    if method not in MCP_POST_METHODS:
        return False, f"MCP method {method!r} is not supported by the GBrain broker"
    if method == "tools/call":
        params = request.get("params")
        if not isinstance(params, dict) or not isinstance(params.get("name"), str):
            return False, "tools/call requires an object params value with a tool name"
    return True, None


def _read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    with path.open(encoding="utf-8") as credential_file:
        for line_number, raw_line in enumerate(credential_file, 1):
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            key, separator, value = line.partition("=")
            if not separator or not key or key in values:
                raise ValueError(f"invalid credentials entry in {path.name} at line {line_number}")
            values[key] = value
    return values


@dataclass(frozen=True)
class ProfileCredentials:
    profile: str
    inbound_token: str
    client_id: str
    client_secret: str


def load_profile_credentials(directory: str) -> dict[str, ProfileCredentials]:
    """Load one strictly permissioned ``<profile>.env`` file per profile."""
    root = Path(directory)
    root_stat = root.stat()
    if not stat.S_ISDIR(root_stat.st_mode):
        raise ValueError("GBrain credentials path is not a directory")
    if root_stat.st_uid != os.geteuid():
        raise PermissionError("GBrain credentials directory must be owned by the broker user")
    if root_stat.st_mode & 0o077:
        raise PermissionError("GBrain credentials directory must have mode 0700 or stricter")

    profiles: dict[str, ProfileCredentials] = {}
    inbound_tokens: list[str] = []
    for path in sorted(root.iterdir()):
        if path.suffix != ".env":
            continue
        profile = path.stem
        if not PROFILE_RE.fullmatch(profile):
            raise ValueError(f"unsafe profile credentials filename: {path.name}")
        file_stat = path.lstat()
        if not stat.S_ISREG(file_stat.st_mode) or path.is_symlink():
            raise ValueError(f"profile credentials must be a regular file: {path.name}")
        if file_stat.st_uid != os.geteuid():
            raise PermissionError(f"profile credentials must be owned by the broker user: {path.name}")
        if file_stat.st_mode & 0o077:
            raise PermissionError(f"profile credentials must have mode 0600 or stricter: {path.name}")
        values = _read_env_file(path)
        expected = {
            "GBRAIN_BROKER_TOKEN",
            "GBRAIN_OAUTH_CLIENT_ID",
            "GBRAIN_OAUTH_CLIENT_SECRET",
        }
        if set(values) != expected or any(not values[key] for key in expected):
            raise ValueError(f"profile credentials have missing, empty, or unknown fields: {path.name}")
        inbound_token = values["GBRAIN_BROKER_TOKEN"]
        if len(inbound_token) < 32:
            raise ValueError(f"GBRAIN_BROKER_TOKEN must contain at least 32 characters: {path.name}")
        if any(hmac.compare_digest(inbound_token, existing) for existing in inbound_tokens):
            raise ValueError("GBRAIN_BROKER_TOKEN values must be unique")
        inbound_tokens.append(inbound_token)
        profiles[profile] = ProfileCredentials(
            profile,
            inbound_token,
            values["GBRAIN_OAUTH_CLIENT_ID"],
            values["GBRAIN_OAUTH_CLIENT_SECRET"],
        )
    if not profiles:
        raise ValueError("GBrain credentials directory contains no profile .env files")
    return profiles


def validate_upstream_url(value: str, label: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError(f"{label} must be an absolute HTTP(S) URL")
    if parsed.username or parsed.password or parsed.fragment:
        raise ValueError(f"{label} must not contain user info or a fragment")
    return value


class UpstreamProfile:
    """GBrain client and independent OAuth token cache for one Hermes profile."""

    def __init__(self, credentials: ProfileCredentials, mcp_url: str, token_url: str) -> None:
        self.credentials = credentials
        self.mcp_url = mcp_url
        self.token_url = token_url
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
                    "client_id": self.credentials.client_id,
                    "client_secret": self.credentials.client_secret,
                }
            ).encode()
            request = urllib.request.Request(self.token_url, data=body, method="POST")
            request.add_header("Content-Type", "application/x-www-form-urlencoded")
            with urllib.request.urlopen(request, timeout=10) as response:  # nosec B310 - validated config URL
                token_response = json.load(response)
            token = token_response.get("access_token")
            if not isinstance(token, str) or not token:
                raise ValueError("upstream OAuth token response lacks access_token")
            expires_in = token_response.get("expires_in", 60)
            if not isinstance(expires_in, (int, float)) or isinstance(expires_in, bool):
                expires_in = 60
            self._token = token
            self._token_expires_at = time.monotonic() + max(1, float(expires_in) - 15)
            return token

    def request(
        self, method: str, body: bytes | None, headers: Mapping[str, str]
    ) -> tuple[int, str, dict[str, str], bytes]:
        token = self.token()
        result = self._request_once(method, body, headers, token)
        if result[0] == HTTPStatus.UNAUTHORIZED:
            # An OAuth 401 is rejected before the MCP call executes, so one
            # refresh and retry is safe even for write tools.
            self._invalidate_token(token)
            result = self._request_once(method, body, headers, self.token())
        return result

    def _invalidate_token(self, rejected_token: str) -> None:
        """Clear this profile's cache without clobbering a concurrent refresh."""
        with self._lock:
            if hmac.compare_digest(self._token, rejected_token):
                self._token = ""
                self._token_expires_at = 0.0

    def _request_once(
        self, method: str, body: bytes | None, headers: Mapping[str, str], token: str
    ) -> tuple[int, str, dict[str, str], bytes]:
        request = urllib.request.Request(self.mcp_url, data=body, method=method)
        if body is not None:
            request.add_header("Content-Type", "application/json")
        for name in FORWARDED_REQUEST_HEADERS:
            value = headers.get(name)
            if value:
                request.add_header(name, value)
        request.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request, timeout=120) as response:  # nosec B310 - validated config URL
                response_headers = {
                    name: response.headers[name]
                    for name in FORWARDED_RESPONSE_HEADERS
                    if response.headers.get(name)
                }
                return response.status, response.headers.get_content_type(), response_headers, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.headers.get_content_type(), {}, error.read()


def parse_profile_path(path: str) -> str | None:
    parsed = urllib.parse.urlsplit(path)
    if parsed.query or parsed.fragment:
        return None
    prefix = "/mcp/"
    profile = parsed.path[len(prefix) :] if parsed.path.startswith(prefix) else ""
    return profile if PROFILE_RE.fullmatch(profile) else None


def bearer_token(value: str | None) -> str | None:
    if not value or not value.startswith("Bearer "):
        return None
    token = value[7:]
    return token if token and not any(character.isspace() for character in token) else None


def authenticate_profile(
    profile: str | None,
    candidate: str | None,
    profiles: Mapping[str, "UpstreamProfile"],
    dummy_token: str,
) -> "UpstreamProfile | None":
    """Resolve a route and token without using an early-exit secret comparison."""
    upstream = profiles.get(profile or "")
    expected = upstream.credentials.inbound_token if upstream else dummy_token
    authenticated = candidate is not None and hmac.compare_digest(candidate, expected)
    return upstream if authenticated else None


class Handler(BaseHTTPRequestHandler):
    server: "BrokerServer"
    protocol_version = "HTTP/1.1"

    def _authenticate(self) -> UpstreamProfile | None:
        profile = parse_profile_path(self.path)
        candidate = bearer_token(self.headers.get("Authorization"))
        # Always perform a comparison for a syntactically valid token so unknown
        # profile routes do not become a useful token oracle.
        upstream = authenticate_profile(profile, candidate, self.server.profiles, self.server.dummy_token)
        if upstream is None:
            self.close_connection = True
            self._send(HTTPStatus.UNAUTHORIZED, "application/json", b'{"error":"unauthorized"}')
            return None
        return upstream

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        upstream = self._authenticate()
        if upstream is None:
            return
        request_id: Any = None
        try:
            length = int(self.headers.get("Content-Length", ""))
            if length < 1 or length > MAX_REQUEST_BYTES:
                raise ValueError("invalid request size")
            raw_request = self.rfile.read(length)
            request = json.loads(raw_request)
            if not isinstance(request, dict):
                raise ValueError("MCP request must be a JSON object")
            request_id = request.get("id")
        except (ValueError, json.JSONDecodeError):
            self._send_sse(HTTPStatus.BAD_REQUEST, jsonrpc_error(None, "invalid MCP JSON-RPC request"))
            return
        permitted, reason = allowed_request(request)
        if not permitted:
            self._send_sse(HTTPStatus.OK, jsonrpc_error(request_id, reason or "request denied"))
            return
        self._forward(upstream, "POST", raw_request, request_id)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        upstream = self._authenticate()
        if upstream is not None:
            self._forward(upstream, "GET", None, None)

    def do_DELETE(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        upstream = self._authenticate()
        if upstream is not None:
            self._forward(upstream, "DELETE", None, None)

    def _forward(
        self, upstream: UpstreamProfile, method: str, body: bytes | None, request_id: Any
    ) -> None:
        try:
            status, content_type, response_headers, response_body = upstream.request(
                method, body, self.headers
            )
            self._send(status, content_type, response_body, response_headers)
        except (OSError, ValueError, urllib.error.URLError, json.JSONDecodeError):
            self._send_sse(
                HTTPStatus.BAD_GATEWAY,
                jsonrpc_error(request_id, "GBrain upstream is unavailable"),
            )

    def _send_sse(self, status: int | HTTPStatus, body: bytes) -> None:
        self._send(status, "text/event-stream", body)

    def _send(
        self,
        status: int | HTTPStatus,
        content_type: str,
        body: bytes,
        headers: Mapping[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        # Intentionally silent: request headers and bodies contain credentials
        # and potentially private memories.
        return


class BrokerServer(ThreadingHTTPServer):
    def __init__(
        self,
        address: tuple[str, int],
        credentials: Mapping[str, ProfileCredentials],
        mcp_url: str,
        token_url: str,
    ) -> None:
        super().__init__(address, Handler)
        self.profiles = {
            profile: UpstreamProfile(profile_credentials, mcp_url, token_url)
            for profile, profile_credentials in credentials.items()
        }
        self.dummy_token = "0" * 64


def main() -> None:
    mcp_url = validate_upstream_url(
        os.environ.get("GBRAIN_UPSTREAM_MCP_URL", "http://gbrain:3131/mcp"),
        "GBRAIN_UPSTREAM_MCP_URL",
    )
    token_url = validate_upstream_url(
        os.environ.get("GBRAIN_UPSTREAM_TOKEN_URL", "http://gbrain:3131/token"),
        "GBRAIN_UPSTREAM_TOKEN_URL",
    )
    credentials = load_profile_credentials(
        os.environ.get("GBRAIN_PROFILE_CREDENTIALS_DIR", "/run/gbrain-oauth/profiles")
    )
    port = int(os.environ.get("PORT", "3132"))
    if not 1 <= port <= 65535:
        raise SystemExit("PORT must be between 1 and 65535")
    BrokerServer(("0.0.0.0", port), credentials, mcp_url, token_url).serve_forever()


if __name__ == "__main__":
    main()

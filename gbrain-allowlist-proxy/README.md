# GBrain Profile Credential Broker

This internal HTTP service gives each Hermes profile a deterministic identity
when it connects to one shared GBrain. Despite the legacy directory name, it
does not maintain a tool allowlist. GBrain's per-client `allowed_operations`
and configured starter surface are the authorization boundary.

For profile `maestro`, Hermes connects to:

```text
http://gbrain-mcp:3132/mcp/maestro
Authorization: Bearer <maestro broker token>
```

The broker verifies that static token with a constant-time comparison, selects
only `maestro`'s OAuth client, and obtains an upstream `client_credentials`
token. Each profile has its own locked token cache. Unknown routes, missing
headers, and invalid tokens receive the same fail-closed `401` response.

## Credential directory

Set `GBRAIN_PROFILE_CREDENTIALS_DIR` to the mounted credential directory
(default `/run/gbrain-oauth/profiles`). The directory must be owned by the
broker's effective UID and mode `0700` or stricter. It contains one
broker-owned, mode `0600` or stricter, non-symlink file named
`<profile>.env`:

```dotenv
GBRAIN_BROKER_TOKEN=<at-least-32-random-characters>
GBRAIN_OAUTH_CLIENT_ID=<GBrain-client-id-for-this-profile>
GBRAIN_OAUTH_CLIENT_SECRET=<GBrain-client-secret-for-this-profile>
```

Profile names must match `[a-z0-9][a-z0-9_-]{0,62}`. Broker tokens must be
unique. Unknown, duplicate, missing, or empty fields stop startup. Generate the
inbound token with a cryptographically secure tool (for example,
`openssl rand -hex 32`) and never place real credentials in Compose, `.env`,
Hermes templates, source control, command arguments, or logs.

The service also reads `GBRAIN_UPSTREAM_MCP_URL`,
`GBRAIN_UPSTREAM_TOKEN_URL`, and `PORT`. Both upstream locations must be
absolute HTTP(S) URLs without embedded credentials.

## Forwarded protocol

The broker forwards MCP initialization, initialized/cancelled notifications, ping,
`tools/list`, and every valid `tools/call`; it does not inspect or log tool
arguments or responses. Authenticated GET and DELETE requests are forwarded
for MCP session handling. MCP protocol/session headers are preserved, while
the inbound bearer credential is always replaced by the selected profile's
short-lived upstream OAuth token.

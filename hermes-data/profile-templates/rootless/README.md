# Hermes Profile: __PROFILE__ (Rootless)

This profile is scaffolded for the compose-managed rootless Hermes stack.

## Memory Wiring

- Hermes built-in memory stays profile-local in this directory.
- Hindsight bank ID: `__BANK_ID__`
- Hindsight MCP URL: `http://hindsight-mcp:8888/mcp/__BANK_ID__/`
- Headroom MCP is configured in `config.yaml` as a Docker-backed stdio server.
- Shared Obsidian vault inside Hermes: `__OBSIDIAN_VAULT_PATH__`
- This profile's Obsidian index: `__OBSIDIAN_VAULT_PATH__/Profiles/__PROFILE__/Index.md`

Use the Hindsight bank for deeper semantic memory. Use Headroom for compression,
retrieval of compressed content, and compression statistics. Use Obsidian for
durable notes, indexes, logs, and cross-profile knowledge.

## Hindsight Bank

The profile config pins Hindsight to `__BANK_ID__` by URL. The profile creation
script creates this bank automatically when the Hindsight API is reachable. To
retry manually from the Ubuntu host, call the loopback-published API:

```bash
curl -fsS -X PUT "http://127.0.0.1:8888/v1/default/banks/__BANK_ID__" \
  -H "content-type: application/json" \
  -d '{}'
```

Inside the Compose network, Hermes talks to Hindsight through the
`hindsight-mcp` service name.

## Obsidian Vault

The profile creation script creates a shared Obsidian-compatible vault at
`appdata/hermes/obsidian-memory-vault` on the host, mounted inside Hermes as
`__OBSIDIAN_VAULT_PATH__`.

Keep profile-specific notes under:

```text
__OBSIDIAN_VAULT_PATH__/Profiles/__PROFILE__/
```

Shared stack or architecture notes belong under:

```text
__OBSIDIAN_VAULT_PATH__/Shared/
```

Do not store secrets, API keys, or credentials in Obsidian notes.

## Headroom

Headroom is wired as:

```text
docker exec -i -e HEADROOM_PROXY_URL=http://headroom-proxy:8787 hermes-headroom-mcp headroom mcp serve
```

The long-running `headroom-proxy` Compose service must be running for proxy
stats and proxy-backed retrieval.

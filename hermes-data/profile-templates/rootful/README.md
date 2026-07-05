# Hermes Profile: __PROFILE__

This profile is scaffolded for the compose-managed Hermes stack.

## Memory Wiring

- Hermes built-in memory stays profile-local in this directory.
- Hindsight bank ID: `__BANK_ID__`
- Hindsight MCP URL: `http://127.0.0.1:8888/mcp/__BANK_ID__/`
- Headroom MCP is configured in `config.yaml` as a Docker-backed stdio server.

Use the Hindsight bank for deeper semantic memory. Use Headroom for compression,
retrieval of compressed content, and compression statistics.

## Hindsight Bank

The profile config pins Hindsight to `__BANK_ID__` by URL. The profile creation
script creates this bank automatically when the Hindsight API is reachable. If
you need to create or inspect banks manually, either call the local API:

```bash
curl -fsS -X PUT "http://127.0.0.1:8888/v1/default/banks/__BANK_ID__" \
  -H "content-type: application/json" \
  -d '{}'
```

or temporarily enable the commented `hindsight_admin` MCP entry in `config.yaml`,
then use Hindsight's bank-management tools from the multi-bank endpoint.

Keep the admin endpoint disabled during normal profile use so this profile stays
bound to its own bank.

## Headroom

Headroom is wired as:

```text
docker exec -i -e HEADROOM_PROXY_URL=http://headroom-proxy:8787 hermes-headroom-mcp headroom mcp serve
```

The long-running `headroom-proxy` Compose service must be running for proxy
stats and proxy-backed retrieval.

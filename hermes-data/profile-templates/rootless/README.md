# Hermes Profile: __PROFILE__ (Rootless)

This profile is scaffolded for the compose-managed rootless Hermes stack.

## Memory Wiring

- Hermes built-in memory stays profile-local in this directory.
- Hindsight bank ID: `__BANK_ID__`
- Hindsight MCP URL: `http://hindsight-mcp:8888/mcp/__BANK_ID__/`
- Headroom MCP is configured in `config.yaml` as a Docker-backed stdio server.

Use the Hindsight bank for deeper semantic memory. Use Headroom for compression,
retrieval of compressed content, and compression statistics.

## Hindsight Bank

The profile config pins Hindsight to `__BANK_ID__` by URL. From the Ubuntu host,
create or inspect the bank through the loopback-published API:

```bash
curl -fsS -X PUT "http://127.0.0.1:8888/v1/default/banks/__BANK_ID__" \
  -H "content-type: application/json" \
  -d '{}'
```

Inside the Compose network, Hermes talks to Hindsight through the
`hindsight-mcp` service name.

## Headroom

Headroom is wired as:

```text
docker exec -i -e HEADROOM_PROXY_URL=http://headroom-proxy:8787 hermes-headroom-mcp headroom mcp serve
```

The long-running `headroom-proxy` Compose service must be running for proxy
stats and proxy-backed retrieval.

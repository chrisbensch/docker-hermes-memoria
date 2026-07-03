# Hermes Agent Compose Stack

This bundle targets an Ubuntu Linux server or desktop where Hermes Agent is not installed directly on the host. Hermes and the long-running sidecars run through Docker Compose; Headroom MCP runs from the Headroom Docker image as a stdio container launched by Hermes.

For the shortest setup path, start with `QUICKSTART.md`.

## Layout

- `docker-compose.yml` runs one Hermes Agent container, the official Hindsight container, and a Headroom proxy sidecar used by Headroom MCP.
- `docker-compose.rootless.yml` is an override for rootless Docker deployments.
- `hermes-data/config.yaml` is mounted into Hermes as `/opt/data/config.yaml`.
- `hermes-data/config.rootless.yaml` is mounted as `/opt/data/config.yaml` by the rootless override.
- `hermes-data/profiles/_template/` is the template used for new profiles.
- `scripts/create-profile.sh` scaffolds additional profile directories with pinned Hindsight bank URLs and Headroom MCP config.
- `scripts/create-profile-rootless.sh` does the same for rootless Docker, using Compose service names instead of host loopback.
- `hermes-config-fragment.yaml` contains just the MCP block if you want to merge it into an existing config.
- `.env.example` contains Compose-level settings such as image names and ports.
- `hermes-data/.env.example` is for Hermes runtime provider secrets.

Hermes uses `network_mode: host`, matching the upstream Docker gateway pattern. Hindsight is an HTTP MCP server, while Headroom's MCP server is stdio-based. Hermes reaches them as:

```text
http://127.0.0.1:8888/mcp/hermes-default/
docker run --rm -i --network host --entrypoint headroom ghcr.io/chopratejas/headroom:latest mcp serve
```

The Hindsight container follows the upstream Docker recipe:

- Image: `ghcr.io/vectorize-io/hindsight:latest`
- API and MCP endpoint: `http://127.0.0.1:8888`
- Profile-pinned MCP endpoint pattern: `http://127.0.0.1:8888/mcp/hermes-<profile>/`
- UI/control plane: `http://127.0.0.1:9999`
- Data volume: `/home/hindsight/.pg0`

The Headroom container follows the repo's Docker image and proxy pattern:

- Image: `ghcr.io/chopratejas/headroom:latest`
- Proxy health endpoint: `http://127.0.0.1:8787/readyz`
- Proxy port: `http://127.0.0.1:8787`
- MCP transport: stdio via `headroom mcp serve`
- Shared Docker volume: `hermes-headroom-workspace`

Because Hermes is itself containerized, `docker-compose.yml` mounts `/var/run/docker.sock` into the Hermes container. This lets Hermes launch Headroom's stdio MCP server as a short-lived Docker container. Treat that socket mount as powerful host access and keep this stack on a machine/user boundary you trust.

## Memory Model

Each Hermes profile should keep its own local state and its own Hindsight bank:

```text
Hermes profile: research
Native memory: /opt/data/profiles/research/state.db
Session search: /opt/data/profiles/research/sessions/
Hindsight bank: hermes-research
Hindsight MCP:  http://127.0.0.1:8888/mcp/hermes-research/
```

The intended order is:

1. Hermes built-in memory first for hot facts, stable user preferences, and small operational notes.
2. Hermes session search for previous-conversation transcript recall.
3. Hindsight for deeper semantic memory, reflection, graph-style recall, and durable knowledge that should outlive a single session.
4. Headroom MCP for compression, retrieval, and compression statistics. Headroom is not the durable memory store.

The Hindsight MCP URL is intentionally single-bank per profile. For profile `research`, use bank `hermes-research` and URL `http://127.0.0.1:8888/mcp/hermes-research/`. This keeps profile memories from mixing unless you deliberately enable the commented multi-bank admin endpoint.

Compose service names are the stable names to use for internal addressing. Do
not depend on generated container names or container IP addresses. In rootless
mode, use service names such as `hindsight-mcp` and `headroom-proxy`; in the
rootful host-network mode, Hermes uses host loopback addresses because it is not
attached to the Compose bridge network.

## Fresh Ubuntu Setup

These steps assume you have copied this directory to a new Ubuntu server or desktop and Docker is already installed.

1. Enter the stack directory and confirm the Docker Compose plugin is available:

```bash
cd hermes-compose-mcp
docker compose version
```

If `docker compose` is missing, install the Compose plugin for your Docker installation before continuing.

2. Create the Compose env file:

```bash
cp .env.example .env
sed -i "s/^HERMES_UID=.*/HERMES_UID=$(id -u)/" .env
sed -i "s/^HERMES_GID=.*/HERMES_GID=$(id -g)/" .env
```

3. Edit `.env` and set `HINDSIGHT_API_LLM_API_KEY`, or change `HINDSIGHT_API_LLM_PROVIDER`, `HINDSIGHT_API_LLM_MODEL`, and `HINDSIGHT_API_LLM_BASE_URL` for another provider.

For LM Studio running on the Docker host, use the container-reachable host alias:

```bash
HINDSIGHT_API_LLM_PROVIDER=lmstudio
HINDSIGHT_API_LLM_MODEL=your-local-model
HINDSIGHT_API_LLM_BASE_URL=http://host.docker.internal:1234/v1
HINDSIGHT_API_LLM_API_KEY=
```

For DeepSeek-backed Hindsight:

```bash
HINDSIGHT_API_LLM_PROVIDER=deepseek
HINDSIGHT_API_LLM_MODEL=deepseek-chat
HINDSIGHT_API_LLM_API_KEY=sk-your-deepseek-key
```

4. If Hermes itself needs provider keys, create `/opt/data` runtime secrets from the host-mounted directory:

```bash
cp hermes-data/.env.example hermes-data/.env
```

Then edit `hermes-data/.env`.

For Hermes runtime providers, `hermes-data/.env.example` includes placeholders
for `DEEPSEEK_API_KEY`, `LM_BASE_URL`, and `LM_API_KEY`.

5. Make sure the profile scaffold script is executable:

```bash
chmod +x scripts/create-profile.sh scripts/create-profile-rootless.sh
```

6. Create each Hermes profile you want. The default bank name is `hermes-<profile>` and Headroom MCP is included automatically:

```bash
./scripts/create-profile.sh research
./scripts/create-profile.sh coder hermes-coder
```

7. Validate the Compose file:

```bash
docker compose --env-file .env config
```

8. Start the stack:

```bash
docker compose --env-file .env up -d
```

9. Check the sidecars:

```bash
curl -fsS http://127.0.0.1:8888/health
curl -fsS http://127.0.0.1:8787/readyz
```

10. Explicitly initialize each Hindsight bank. Hindsight can create banks on first use, but this makes a fresh server setup deterministic:

```bash
curl -fsS -X PUT "http://127.0.0.1:8888/v1/default/banks/hermes-research" \
  -H "content-type: application/json" \
  -d '{}'
```

Repeat that command for each bank, such as `hermes-default` or `hermes-coder`.

To include the local dashboard service:

```bash
docker compose --env-file .env --profile dashboard up -d
```

## Rootless Docker Setup

Use this path when the Ubuntu host runs the Docker daemon in rootless mode for
the deployment user.

1. Confirm your shell is talking to the rootless Docker daemon:

```bash
docker info
docker compose version
```

If needed, set:

```bash
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
```

2. Set the rootless socket path in `.env`:

```bash
sed -i "s|^DOCKER_SOCK=.*|DOCKER_SOCK=/run/user/$(id -u)/docker.sock|" .env
```

3. Create profiles with the rootless scaffold:

```bash
./scripts/create-profile-rootless.sh research
```

Rootless profile configs use:

```text
http://hindsight-mcp:8888/mcp/hermes-research/
docker run --network hermes-compose-mcp-rootless ... headroom mcp serve
```

Do not reuse configs generated by `create-profile.sh` for rootless profiles
unless you replace their `127.0.0.1` MCP URLs and Headroom network arguments.

4. Validate and start the rootless stack:

```bash
docker compose --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.rootless.yml \
  config

docker compose --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.rootless.yml \
  up -d
```

5. Check the sidecars from the Ubuntu host:

```bash
curl -fsS http://127.0.0.1:8888/health
curl -fsS http://127.0.0.1:8787/readyz
```

6. Initialize each Hindsight bank from the host:

```bash
curl -fsS -X PUT "http://127.0.0.1:8888/v1/default/banks/hermes-research" \
  -H "content-type: application/json" \
  -d '{}'
```

To include the dashboard in rootless mode:

```bash
docker compose --env-file .env --profile dashboard \
  -f docker-compose.yml \
  -f docker-compose.rootless.yml \
  up -d
```

The dashboard is then published on host loopback at
`http://127.0.0.1:${HERMES_DASHBOARD_HOST_PORT:-9119}`.

The rootless override publishes Hermes' API-server port on
`127.0.0.1:${HERMES_API_HOST_PORT:-8642}`, but Hermes only listens there when
you enable the API server with Hermes configuration such as `API_SERVER_KEY` or
`API_SERVER_ENABLED`. For webhook-style gateway platforms, add the needed
`ports:` entries to `docker-compose.rootless.yml` and configure those Hermes
platforms to bind `0.0.0.0` inside the container.

## Notes

- Hindsight multi-bank mode uses `http://127.0.0.1:8888/mcp/`. The profile configs use single-bank URLs like `http://127.0.0.1:8888/mcp/hermes-research/` to keep memory separated by profile.
- If you need to create, inspect, or delete banks manually, temporarily enable the commented `hindsight_admin` MCP server in the relevant profile config. Keep it disabled during normal profile use.
- If you change `HEADROOM_PROXY_HOST_PORT`, update `HEADROOM_PROXY_URL=http://127.0.0.1:8787` in `hermes-data/config.yaml` and each profile config.
- If you change `HEADROOM_IMAGE`, update the same image string in `hermes-data/config.yaml` and each profile config unless your Hermes config supports environment interpolation.
- In rootless mode, update the rootless config/template equivalents instead: `hermes-data/config.rootless.yaml` and `hermes-data/profiles/_template-rootless/config.yaml`.
- Headroom's upstream Compose stack also includes Qdrant and Neo4j for memory-oriented features. This bundle keeps the base stack lean; add those services later if you enable Headroom features that require them.
- Do not run a separate host-installed Hermes against the same `hermes-data` directory.
- Do not point two Hermes containers at the same `hermes-data` directory simultaneously.

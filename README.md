# Hermes Agent Compose Stack

This bundle targets an Ubuntu Linux server or desktop where Hermes Agent is not installed directly on the host. Hermes and the long-running sidecars run through Docker Compose; Headroom MCP runs from the Headroom Docker image as a stdio container launched by Hermes.

For the shortest setup path, run `./setup.sh` or start with `QUICKSTART.md`.
If a setup attempt gets messy, run `./reset.sh` to archive generated state and
start fresh.

## Layout

- `docker-compose.yml` runs Hermes Agent, Hindsight, Headroom, and the integrated Firecrawl/SearXNG/Camofox web access suite.
- `docker-compose.rootless.yml` is an override for rootless Docker deployments.
- `web-search/` contains tracked SearXNG/nginx templates; `web-search/searxng-settings.yml` is generated locally with a unique secret.
- `hermes-data/config.yaml` is the writable runtime config mounted into Hermes as `/opt/data/config.yaml`.
- `hermes-data/config.rootless.yaml` and `hermes-data/config.rootful.yaml` are blank base-profile seed configs for each deployment mode.
- `hermes-data/profile-templates/` contains the rootful and rootless templates used for new named profiles.
- `scripts/create-profile.sh` scaffolds additional profile directories with pinned Hindsight bank URLs and Headroom MCP config.
- `scripts/create-profile-rootless.sh` does the same for rootless Docker, using Compose service names instead of host loopback.
- `hermes-config-fragment.yaml` contains the web/browser and MCP blocks if you want to merge them into an existing config.
- `.env.example` contains Compose-level settings such as image names and ports.
- `hermes-data/.env.example` is for Hermes runtime provider secrets.

Hermes uses `network_mode: host`, matching the upstream Docker gateway pattern. Hindsight is an HTTP MCP server, while Headroom's MCP server is stdio-based. Hermes reaches them as:

```text
http://127.0.0.1:8888/mcp/hermes-research/
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

The web access suite follows the uploaded agent-web pattern, folded into this
Compose project:

- Firecrawl API: `http://127.0.0.1:3002`
- SearXNG test UI/API: `http://127.0.0.1:8889` to avoid Hindsight's `8888`
- Camofox browser service: `http://127.0.0.1:9377`
- Local Firecrawl source checkout: `.firecrawl-src/`, ignored by Git
- Generated SearXNG settings: `web-search/searxng-settings.yml`, ignored by Git

Rootful Hermes reaches Firecrawl and Camofox through host loopback. Rootless
Hermes reaches them on the Compose network as `http://firecrawl-api:3002` and
`http://camofox:9377`.

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

For guided setup, run:

```bash
./setup.sh
```

The script prompts for Docker mode, profile name, provider settings, UI exposure,
generates web-search secrets, clones the Firecrawl build source, configures
Hermes to use Firecrawl/Camofox, and prints the Compose command to run. Use the
manual steps below when you want to edit each file yourself.

To reset a failed or experimental setup:

```bash
./reset.sh
```

The reset script stops Compose services, archives generated files under
`reset-backups/`, keeps tracked templates and seed configs, and then points you
back to `./setup.sh`. Use `./reset.sh --hard --volumes` only when you also want
to permanently delete local runtime files and the Compose-managed Docker volumes.

1. Enter the stack directory and confirm the Docker Compose plugin is available:

```bash
cd hermes-compose-mcp
docker compose version
```

If `docker compose` is missing, install the Compose plugin for your Docker installation before continuing.

2. Create the Compose env file, seed the writable Hermes config, and prepare the
web-search assets:

```bash
cp .env.example .env
sed -i "s/^HERMES_UID=.*/HERMES_UID=$(id -u)/" .env
sed -i "s/^HERMES_GID=.*/HERMES_GID=$(id -g)/" .env
test -S /var/run/docker.sock
cp -n hermes-data/config.rootful.yaml hermes-data/config.yaml
cp web-search/searxng-settings.template.yml web-search/searxng-settings.yml
secret=$(openssl rand -hex 32)
sed -i "s/CHANGE-ME-TO-A-RANDOM-SECRET/$secret/" web-search/searxng-settings.yml
git clone --depth 1 https://github.com/firecrawl/firecrawl.git .firecrawl-src
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
For web access in rootful mode, set:

```bash
FIRECRAWL_API_URL=http://127.0.0.1:3002
CAMOFOX_URL=http://127.0.0.1:9377
```

5. Make sure the profile scaffold script is executable:

```bash
chmod +x scripts/create-profile.sh scripts/create-profile-rootless.sh
```

6. Create each Hermes profile you want. The first profile created becomes the
active Hermes profile by writing `hermes-data/active_profile` and gateway state
files so the first container start runs that profile. `default` is reserved by
Hermes for the base home and should not be used as a profile name. The default
bank name is `hermes-<profile>` and Headroom MCP is included automatically:

```bash
./scripts/create-profile.sh research
./scripts/create-profile.sh coder hermes-coder
```

Hindsight's `HINDSIGHT_API_LLM_*` values do not configure Hermes Agent's own
chat model. To make Hermes use LM Studio, also set the runtime model in the
active profile config, for example `hermes-data/profiles/research/config.yaml`:

```yaml
model:
  provider: lmstudio
  default: your-local-model
  base_url: http://host.docker.internal:1234/v1
```

For LM Studio on another LAN machine, use that machine's IP address instead of
`host.docker.internal`.

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
curl -fsS http://127.0.0.1:3002/v0/health/liveness
curl -fsS "http://127.0.0.1:8889/search?q=test&format=json"
curl -fsS http://127.0.0.1:9377/health
```

10. Explicitly initialize each Hindsight bank. Hindsight can create banks on first use, but this makes a fresh server setup deterministic:

```bash
curl -fsS -X PUT "http://127.0.0.1:8888/v1/default/banks/hermes-research" \
  -H "content-type: application/json" \
  -d '{}'
```

Repeat that command for each bank, such as `hermes-coder`.

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
test -S "/run/user/$(id -u)/docker.sock"
```

If that socket check fails, your shell is not using a rootless Docker daemon for
this user; start rootless Docker or set `DOCKER_SOCK` to the real socket before
starting the stack.

3. Seed the writable base config and create profiles with the rootless scaffold:

```bash
cp -n hermes-data/config.rootless.yaml hermes-data/config.yaml
./scripts/create-profile-rootless.sh research
```

The scaffold writes `research` to `hermes-data/active_profile` and seeds gateway
state when no active profile exists yet, so the first gateway start uses the
named profile instead of the base `default` profile.

Rootless profile configs use:

```text
http://hindsight-mcp:8888/mcp/hermes-research/
docker run --network hermes-compose-mcp-rootless ... headroom mcp serve
```

Do not reuse configs generated by `create-profile.sh` for rootless profiles
unless you replace their `127.0.0.1` MCP URLs and Headroom network arguments.
For rootless web access, set these in `hermes-data/.env`:

```bash
FIRECRAWL_API_URL=http://firecrawl-api:3002
CAMOFOX_URL=http://camofox:9377
```

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
curl -fsS http://127.0.0.1:3002/v0/health/liveness
curl -fsS "http://127.0.0.1:8889/search?q=test&format=json"
curl -fsS http://127.0.0.1:9377/health
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

## Remote UI Access

By default, published ports bind to `127.0.0.1` so the services are local-only.
To reach selected UIs from another machine on your LAN, set bind hosts in
`.env`, then recreate the stack:

```bash
HERMES_DASHBOARD_BIND_HOST=0.0.0.0
HINDSIGHT_UI_BIND_HOST=0.0.0.0

# Optional and more sensitive: exposes the Headroom proxy/stat endpoints.
HEADROOM_PROXY_BIND_HOST=0.0.0.0
```

Then restart:

```bash
docker compose --env-file .env --profile dashboard \
  -f docker-compose.yml \
  -f docker-compose.rootless.yml \
  up -d --force-recreate
```

Use the server's LAN IP in a browser:

```text
Hermes Dashboard:        http://<server-ip>:9119/login?next=%2F
Hindsight Control Plane: http://<server-ip>:9999
Headroom stats:          http://<server-ip>:8787/stats
Headroom history:        http://<server-ip>:8787/stats-history
```

Hermes Dashboard refuses non-loopback binds until dashboard auth is configured.
Set `dashboard.basic_auth.username` and `dashboard.basic_auth.password_hash` in
the base runtime config, `hermes-data/config.yaml`, then use the explicit
`/login?next=%2F` URL for
username/password auth. The dashboard root can first auto-redirect through the
OAuth route, which may return an internal server error when only basic auth is
configured. Alternatively, use an SSH/Tailscale tunnel and keep the bind host at
`127.0.0.1`. Hindsight logs currently report no API key configured, and the
Headroom port is an LLM proxy as well as a stats endpoint, so expose them only
on a trusted network or behind a firewall.

The rootless override publishes Hermes' API-server port on
`${HERMES_API_BIND_HOST:-127.0.0.1}:${HERMES_API_HOST_PORT:-8642}`, but Hermes
only listens there when you enable the API server with Hermes configuration
such as `API_SERVER_KEY` or `API_SERVER_ENABLED`. For webhook-style gateway
platforms, add the needed `ports:` entries to `docker-compose.rootless.yml` and
configure those Hermes platforms to bind `0.0.0.0` inside the container.

## Notes

- Hindsight multi-bank mode uses `http://127.0.0.1:8888/mcp/`. The profile configs use single-bank URLs like `http://127.0.0.1:8888/mcp/hermes-research/` to keep memory separated by profile.
- If you need to create, inspect, or delete banks manually, temporarily enable the commented `hindsight_admin` MCP server in the relevant profile config. Keep it disabled during normal profile use.
- If you change `HEADROOM_PROXY_HOST_PORT`, update the matching `HEADROOM_PROXY_URL` in each profile config or template that should use it.
- If you change `HEADROOM_IMAGE`, update the same image string in each profile config or template unless your Hermes config supports environment interpolation.
- Keep `hermes-data/config.rootless.yaml` and `hermes-data/config.rootful.yaml` as reusable blank base-profile seed configs. Make day-to-day agent setup changes in the active profile config under `hermes-data/profiles/<name>/config.yaml`.
- Hermes still exposes `default` as its built-in base `HERMES_HOME`; this stack keeps that base blank and makes the quickstart-created named profile active.
- Headroom's upstream Compose stack also includes Qdrant and Neo4j for memory-oriented features. This bundle keeps the base stack lean; add those services later if you enable Headroom features that require them.
- Do not run a separate host-installed Hermes against the same `hermes-data` directory.
- Do not point two Hermes containers at the same `hermes-data` directory simultaneously.

# Quickstart

This is the short path for getting the Compose stack running. Use `research`
as the example profile name, or replace it with your own.

For a guided setup that prompts for profile, model provider, UI
exposure, prepares Firecrawl/SearXNG/Camofox, configures Hermes web backends,
and then prints the exact Compose command, run:

```bash
./setup.sh
```

To inspect a clone without writing files, run:

```bash
./setup.sh --check
```

To clear generated state after a failed setup or manual experimentation, run:

```bash
./reset.sh
```

By default it archives old files under `reset-backups/` and leaves the repo ready
for another `./setup.sh` run.

Headroom's MCP container and HTTP proxy/stats service start with the base stack.
On minimal QEMU/virtual CPU profiles, the published Headroom proxy image can
exit with `SIGILL`. Use host CPU passthrough and verify it with
`curl -fsS http://127.0.0.1:8787/readyz`.

## Rootless Docker Workflow

Use this when Docker is running in rootless mode for your deployment user.

1. Create and edit the environment files:

```bash
cp .env.example .env
sed -i "s/^HERMES_UID=.*/HERMES_UID=$(id -u)/" .env
sed -i "s/^HERMES_GID=.*/HERMES_GID=$(id -g)/" .env
sed -i "s|^DOCKER_SOCK=.*|DOCKER_SOCK=/run/user/$(id -u)/docker.sock|" .env
test -S "/run/user/$(id -u)/docker.sock"
mkdir -p appdata/hermes/obsidian-memory-vault appdata/hindsight appdata/headroom appdata/firecrawl-redis appdata/firecrawl-rabbitmq appdata/firecrawl-postgres
cp hermes-data/.env.example appdata/hermes/.env
cp -n hermes-data/config.rootless.yaml appdata/hermes/config.yaml
cp web-search/searxng-settings.template.yml web-search/searxng-settings.yml
secret=$(openssl rand -hex 32)
sed -i "s/CHANGE-ME-TO-A-RANDOM-SECRET/$secret/" web-search/searxng-settings.yml
git clone --depth 1 https://github.com/firecrawl/firecrawl.git .firecrawl-src
```

Set `HINDSIGHT_API_LLM_*` in `.env` for Hindsight. Add Hermes runtime provider
keys, such as `DEEPSEEK_API_KEY`, to `appdata/hermes/.env` if needed.
For rootless web access, also set `FIRECRAWL_API_URL=http://firecrawl-api:3002`
and `CAMOFOX_URL=http://camofox:9377` in `appdata/hermes/.env`. Also set
`OBSIDIAN_VAULT_PATH=/opt/data/obsidian-memory-vault`. `./setup.sh` does this
automatically.
If the socket check fails, start rootless Docker for this user or set
`DOCKER_SOCK` to the actual socket before continuing.

2. Create the profile. The first profile created becomes the active
Hermes profile by writing `appdata/hermes/active_profile` and seeding gateway state
so the first container start runs that profile; do not create a profile named
`default`.

```bash
chmod +x scripts/create-profile.sh scripts/create-profile-rootless.sh
./scripts/create-profile.sh research
```

If Hindsight is already running, the script also creates the matching bank. If
not, it prints the curl command to retry after startup.

Hindsight and Hermes use separate model settings. To run Hermes Agent itself
through LM Studio, set `LM_BASE_URL` in `appdata/hermes/.env`, then add a runtime
model block to `appdata/hermes/profiles/research/config.yaml`:

```yaml
model:
  provider: lmstudio
  default: your-local-model
  base_url: http://host.docker.internal:1234/v1
```

3. Validate and start the stack:

```bash
docker compose --env-file .env config

docker compose --env-file .env up -d

./scripts/normalize-appdata-permissions.sh
```

Confirm Hermes sees the provider:

```bash
docker compose --env-file .env exec hermes hermes profile list
docker compose --env-file .env exec hermes hermes status
```

4. Check services and initialize the Hindsight bank if the profile script
reported that bank creation was skipped:

```bash
curl -fsS http://127.0.0.1:8888/health
curl -fsS http://127.0.0.1:8787/readyz
curl -fsS http://127.0.0.1:3002/v0/health/liveness
curl -fsS "http://127.0.0.1:8889/search?q=test&format=json"
curl -fsS http://127.0.0.1:9377/health
curl -fsS -X PUT "http://127.0.0.1:8888/v1/default/banks/hermes-research" \
  -H "content-type: application/json" \
  -d '{}'
```

5. Optional: review UI exposure. Services bind to loopback by default. Before
binding a UI to a trusted LAN, configure dashboard authentication and review the
Hindsight and Headroom exposure warnings in [OPERATIONS.md](OPERATIONS.md).

## Next Steps

- Migrating a host-installed Hermes deployment: follow the inventory, dry-run,
  apply, cron, Memory Vault, and profile checks in [OPERATIONS.md](OPERATIONS.md).
- Configuring or resetting dashboard authentication: use the dashboard auth and
  direct login verification procedure in [OPERATIONS.md](OPERATIONS.md).
- Enabling daily logical and weekly raw Restic backups: configure the external
  Restic environment, then install and inspect the user timers as documented in
  [OPERATIONS.md](OPERATIONS.md).
- Proving recovery: restore a snapshot into an isolated directory and run the
  Hindsight validation and pilot-bank workflow in [OPERATIONS.md](OPERATIONS.md).

For architecture, provider examples, ports, and profile wiring, see
[README.md](README.md). Contributor and automation-agent conventions are in
[AGENTS.md](AGENTS.md).

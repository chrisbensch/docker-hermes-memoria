# Quickstart

This is the short path for getting the Compose stack running. The bundled
`research` profile is an optional reference example; replace it with your own
profile name if it does not fit your deployment.

For a guided setup that prompts for profile, model provider, UI
exposure, prepares Firecrawl/SearXNG/Camofox, configures Hermes web backends,
and then prints the exact Compose command, run:

```bash
sudo apt-get install -y acl
./setup.sh
```

The `acl` package supplies `setfacl`, which setup uses to keep the Obsidian
vault writable by both container Hermes and the host deployment user.

The shared GBrain profile is optional and initialized separately after the base
setup. Its default path uses an existing self-hosted OpenAI-compatible
embedding server and validates the model's real vector width before touching
the database:

```bash
./setup.sh --gbrain
```

For an existing stack migrated from local Hindsight, review the profile changes
first, then make timestamped copies and remove the retired MCP entries:

```bash
docker compose --env-file .env exec -T hermes python3 - \
  < scripts/remove-hindsight-profile-config.py
docker compose --env-file .env exec -T hermes python3 - --apply \
  < scripts/remove-hindsight-profile-config.py
```

The backup copies are stored under `appdata/hermes/migration-backups/`. The
migration preserves GBrain and other MCP entries. See
[the GBrain guide](docs/gbrain-compose.md#per-profile-access) to provision
GBrain credentials for new profiles.

Use `./setup.sh --gbrain --no-embedding` for keyless keyword-only retrieval.
No LAN endpoint or provider credential is committed; see
[the GBrain guide](docs/gbrain-compose.md) for the secret-file layout.

To add the optional read-only Metabase visualization layer after GBrain is
initialized:

```bash
./setup.sh --gbrain-metabase
```

The public default is `http://127.0.0.1:3000`. Set `METABASE_BIND_HOST` in the
ignored `.env` to the host's trusted LAN address before setup when remote
browser access is required. Complete the first-run datasource connection using
[the Metabase guide](docs/gbrain-metabase.md).

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
The MCP container normally sleeps until Hermes starts its stdio command; this
is healthy and does not require another Docker socket or an HTTP MCP URL.
On minimal QEMU/virtual CPU profiles, the published Headroom proxy image can
exit with `SIGILL`. Use host CPU passthrough and verify it with
`curl -fsS http://127.0.0.1:8787/readyz`.
The official proxy image uses the torch-free ONNX Kompress backend. A cold
`ready=false`, `status=degraded`, `backend=null` Kompress health result is not
by itself a failure: the optional model loads when eligible content first
reaches the compressor. Use the eligible tool-result probe in
[OPERATIONS.md](OPERATIONS.md#headroom-kompress-verification) before replacing
the image or adding PyTorch.

New deployments use the explicitly pinned sidecar versions from `.env.example`.
Keep those tags when copying the file; do not change them to `latest`. For a
controlled upgrade, follow the [image version update procedure](OPERATIONS.md#image-version-updates).

## Rootless Docker Workflow

Use this when Docker is running in rootless mode for your deployment user.

1. Create and edit the environment files:

```bash
cp .env.example .env
sed -i "s/^HERMES_UID=.*/HERMES_UID=$(id -u)/" .env
sed -i "s/^HERMES_GID=.*/HERMES_GID=$(id -g)/" .env
sed -i "s|^DOCKER_SOCK=.*|DOCKER_SOCK=/run/user/$(id -u)/docker.sock|" .env
test -S "/run/user/$(id -u)/docker.sock"
mkdir -p appdata/hermes/obsidian-memory-vault appdata/headroom appdata/firecrawl-redis appdata/firecrawl-rabbitmq appdata/firecrawl-postgres
cp hermes-data/.env.example appdata/hermes/.env
cp -n hermes-data/config.rootless.yaml appdata/hermes/config.yaml
cp -n hermes-data/AGENTS.md appdata/hermes/AGENTS.md
cp web-search/searxng-settings.template.yml web-search/searxng-settings.yml
secret=$(openssl rand -hex 32)
sed -i "s/CHANGE-ME-TO-A-RANDOM-SECRET/$secret/" web-search/searxng-settings.yml
git clone --depth 1 https://github.com/firecrawl/firecrawl.git .firecrawl-src
```

Add Hermes runtime provider keys, such as `DEEPSEEK_API_KEY`, to
`appdata/hermes/.env` if needed.
For rootless web access, also set `FIRECRAWL_API_URL=http://firecrawl-api:3002`
and `CAMOFOX_URL=http://camofox:9377` in `appdata/hermes/.env`. Also set
`OBSIDIAN_VAULT_PATH=/opt/data/obsidian-memory-vault`. `./setup.sh` does this
automatically.
If the socket check fails, start rootless Docker for this user or set
`DOCKER_SOCK` to the actual socket before continuing.

2. Create the profile. The first profile created becomes the active CLI and
Dashboard selection through `appdata/hermes/active_profile`. The default gateway
serves it after startup; do not create a profile named `default`. This command
uses the optional bundled `research` example; replace it with your own profile
name as needed.

```bash
chmod +x scripts/create-profile.sh scripts/create-profile-rootless.sh
./scripts/create-profile.sh research
```

The stack uses one default Hermes gateway process. If Telegram is enabled for
multiple profiles, configure a different bot token for each profile; the
gateway routes each bot to its matching profile. Do not copy one bot token into
multiple profiles. For an existing deployment with profile gateways, follow
the backed-up migration in [OPERATIONS.md](OPERATIONS.md#telegram-gateway-migration).

To run Hermes Agent through LM Studio, set `LM_BASE_URL` in
`appdata/hermes/.env`, then add a runtime
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

Normalization applies the same `hermes:root`, setgid, and default-ACL vault
policy used automatically by setup and migration. See
[OPERATIONS.md](OPERATIONS.md#obsidian-vault-permissions) for diagnosis or a
direct repair with `scripts/fix-obsidian-vault-permissions.sh`.

Confirm Hermes sees the provider:

```bash
docker compose --env-file .env exec hermes hermes profile list
docker compose --env-file .env exec hermes hermes status
```

Confirm the active profile can start Headroom MCP through the rootless socket:

```bash
docker compose --env-file .env exec -T hermes \
  /package/admin/s6/command/s6-setuidgid hermes \
  hermes -p research mcp test headroom
```

For profiles copied from an older deployment, run the updater dry-run before
applying it. It creates timestamped backups when changes are written:

```bash
python3 scripts/fix-headroom-mcp-command.py --dry-run
python3 scripts/fix-headroom-mcp-command.py
```

See [OPERATIONS.md](OPERATIONS.md#headroom-mcp-stdio-and-socket-access) for
selected-profile updates and socket diagnostics.

4. Check services:

```bash
curl -fsS http://127.0.0.1:8787/readyz
curl -fsS http://127.0.0.1:3002/v0/health/liveness
curl -fsS "http://127.0.0.1:8889/search?q=test&format=json"
curl -fsS http://127.0.0.1:9377/health
```

5. Optional: review UI exposure. Services bind to loopback by default. New
installs enable the bundled `basic` dashboard-auth plugin, but it remains
inactive until credentials are configured. Before binding a UI to a trusted
LAN, configure dashboard authentication and review the Headroom
exposure warnings in [OPERATIONS.md](OPERATIONS.md).

## Next Steps

- Migrating a host-installed Hermes deployment: follow the inventory, dry-run,
  apply, cron, Memory Vault, and profile checks in [OPERATIONS.md](OPERATIONS.md).
- Configuring or resetting dashboard authentication: use the dashboard auth and
  direct login verification procedure in [OPERATIONS.md](OPERATIONS.md).
- Enabling daily logical Restic backups: configure the external
  Restic environment, then install and inspect the user timer as documented in
  [OPERATIONS.md](OPERATIONS.md).
- Proving recovery: restore a snapshot into an isolated directory and run the
  GBrain validation workflow in [OPERATIONS.md](OPERATIONS.md).

For architecture, provider examples, ports, and profile wiring, see
[README.md](README.md). Contributor and automation-agent conventions are in
[AGENTS.md](AGENTS.md).

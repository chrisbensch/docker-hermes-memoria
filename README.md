# Hermes Agent Compose Stack

This bundle targets an Ubuntu Linux server or desktop where Hermes Agent is not installed directly on the host. Hermes and the long-running sidecars run through Docker Compose; Headroom MCP runs inside a Compose-managed Headroom container and Hermes connects to it with `docker exec`.

For the shortest setup path, run `./setup.sh` or start with [QUICKSTART.md](QUICKSTART.md).
If a setup attempt gets messy, run `./reset.sh` to archive generated state and
start fresh.

## Guide Map

- [QUICKSTART.md](QUICKSTART.md) is the shortest path from a fresh clone to a
  healthy stack.
- [OPERATIONS.md](OPERATIONS.md) is the day-two runbook for health checks,
  migration, dashboard authentication, backups, and recovery.
- [AGENTS.md](AGENTS.md) defines repository conventions, tests, and safety rules
  for contributors and automation agents.
- [`docs/superpowers/`](docs/superpowers/) contains the design and implementation
  history behind major changes.

## Layout

- `docker-compose.yml` runs the rootless Hermes Agent, Hindsight, Headroom, and integrated Firecrawl/SearXNG/Camofox web access suite.
- `web-search/` contains tracked SearXNG/nginx templates; `web-search/searxng-settings.yml` is generated locally with a unique secret.
- `appdata/` is generated locally and stores portable Hermes runtime data plus sidecar data for Hindsight, Headroom, Redis, RabbitMQ, and Firecrawl Postgres.
- `appdata/hermes/obsidian-memory-vault/` is the shared Obsidian-compatible vault for durable notes across profiles; inside Hermes it is `/opt/data/obsidian-memory-vault`.
- `appdata/hermes/config.yaml` is the writable base runtime config mounted into Hermes as `/opt/data/config.yaml`; `./setup.sh` mirrors the selected Hermes runtime model there for dashboard fallback paths.
- `hermes-data/config.rootless.yaml` is the minimal base-profile seed config.
- `hermes-data/profile-templates/` contains the rootless template used for new named profiles.
- `hermes-data/profile-overrides/` contains optional per-profile template overrides, such as the research-specific `SOUL.md`; start new migrations from `hermes-data/profile-overrides/_TEMPLATE/SOUL.md`.
- `scripts/create-profile.sh` scaffolds additional rootless profile directories with pinned Hindsight bank URLs and Headroom MCP config.
- `scripts/create-profile-rootless.sh` is a compatibility wrapper for the same rootless profile scaffold.
- `hermes-config-fragment.yaml` contains the web/browser and MCP blocks if you want to merge them into an existing config.
- `.env.example` contains Compose-level settings such as image names and ports.
- `hermes-data/.env.example` is copied to `appdata/hermes/.env` for Hermes runtime provider secrets.

In the default rootless stack, Hermes runs on the Compose bridge network. Hindsight
is an HTTP MCP server, while Headroom's MCP server is stdio-based. Hermes reaches
them as:

```text
http://hindsight-mcp:8888/mcp/hermes-research/
docker exec -i hermes-headroom-mcp headroom mcp serve
```

The Hindsight container follows the upstream Docker recipe:

- Image: `ghcr.io/vectorize-io/hindsight:latest`
- API and MCP endpoint: `http://127.0.0.1:8888`
- Profile-pinned MCP endpoint pattern: `http://127.0.0.1:8888/mcp/hermes-<profile>/`
- UI/control plane: `http://127.0.0.1:9999`
- Data directory: `appdata/hindsight`

The Headroom MCP container follows the repo's Docker image and stdio MCP pattern:

- Image: `ghcr.io/chopratejas/headroom:0.27.0`
- Compose container: `hermes-headroom-mcp`
- MCP transport: stdio via `headroom mcp serve`
- Shared data directory: `appdata/headroom`

The Headroom proxy starts with the base Compose stack. Headroom's `/stats`,
`/stats-history`, and `/readyz` HTTP endpoints are available on
`http://127.0.0.1:8787` by default. Some minimal virtual CPUs, including QEMU
CPU profiles without AVX, can crash the published Headroom proxy images with
`SIGILL`; use host CPU passthrough on those hosts.

The web access suite follows the uploaded agent-web pattern, folded into this
Compose project:

- Firecrawl API: `http://127.0.0.1:3002`
- SearXNG test UI/API: `http://127.0.0.1:8889` to avoid Hindsight's `8888`
- Camofox browser service: `http://127.0.0.1:9377`
- Local Firecrawl source checkout: `.firecrawl-src/`, ignored by Git
- Generated SearXNG settings: `web-search/searxng-settings.yml`, ignored by Git
- Hermes runtime and sidecar data: `appdata/`, ignored by Git

Hermes reaches Firecrawl and Camofox on the Compose network as
`http://firecrawl-api:3002` and `http://camofox:9377`.

In rootless Docker, `./setup.sh` prepares `appdata/hindsight` ownership through
a short one-off container so Hindsight's unprivileged UID can write its embedded
Postgres data without requiring host-side `sudo chown`.

Because Hermes is itself containerized, `docker-compose.yml` mounts the Docker socket into the Hermes container. This lets Hermes run `docker exec -i hermes-headroom-mcp headroom mcp serve` for Headroom's stdio MCP server. Treat that socket mount as powerful host access and keep this stack on a machine/user boundary you trust.

## Memory Model

Each Hermes profile should keep its own local state and its own Hindsight bank:

```text
Hermes profile: research
Native memory: /opt/data/profiles/research/state.db
Session search: /opt/data/profiles/research/sessions/
Hindsight bank: hermes-research
Hindsight MCP:  http://hindsight-mcp:8888/mcp/hermes-research/
Obsidian:       /opt/data/obsidian-memory-vault/Profiles/research/
```

The intended order is:

1. Hermes built-in memory first for hot facts, stable user preferences, and small operational notes.
2. Hermes session search for previous-conversation transcript recall.
3. Hindsight for deeper semantic memory, reflection, graph-style recall, and durable knowledge that should outlive a single session.
4. The shared Obsidian vault for durable notes, indexes, logs, and cross-profile knowledge.
5. Headroom MCP for compression, retrieval, and compression statistics. Headroom is not the durable memory store.

The Hindsight MCP URL is intentionally single-bank per profile. For profile
`research`, use bank `hermes-research` and URL
`http://hindsight-mcp:8888/mcp/hermes-research/`. This keeps profile memories
from mixing unless you deliberately enable the commented multi-bank admin
endpoint.

The profile creation scripts create the matching Hindsight bank through
`http://127.0.0.1:8888` when the Hindsight API is reachable. Set
`HERMES_CREATE_HINDSIGHT_BANK=0` to skip that step, or
`HERMES_REQUIRE_HINDSIGHT_BANK=1` to make an unreachable Hindsight API fail the
profile creation.

The same scripts also create the shared Obsidian vault skeleton and a profile
index at `appdata/hermes/obsidian-memory-vault/Profiles/<profile>/Index.md`.
`./setup.sh` exports `OBSIDIAN_VAULT_PATH=/opt/data/obsidian-memory-vault` into
the Hermes runtime env and the generated profile env.

## Reusable Profile SOULs

When migrating a `SOUL.md` from another Hermes install, keep the profile's role,
workflow, style, tool preferences, and guardrails, but replace deployment
details with render placeholders:

```text
__PROFILE__
__BANK_ID__
__OBSIDIAN_VAULT_PATH__
```

Use `hermes-data/profile-overrides/_TEMPLATE/SOUL.md` as the starting point for
new overrides. Put the finished file at
`hermes-data/profile-overrides/<profile>/SOUL.md`; `scripts/create-profile.sh`
uses that override automatically when creating the matching profile.

Do not carry over machine-specific paths such as `/home/hermes/Memory_Vault`,
hardcoded Hindsight bank names, or secrets from another deployment. See
`hermes-data/profile-overrides/README.md` for the migration checklist.

Compose service names are the stable names to use for internal addressing. Do
not depend on generated container names or container IP addresses. Use service
names such as `hindsight-mcp`, `headroom-proxy`, `firecrawl-api`, and `camofox`.

## Fresh Setup

Use the guided setup for a new rootless deployment:

```bash
./setup.sh
```

It prepares the local Compose environment, Firecrawl source, generated SearXNG
settings, Hermes web-service URLs, profile scaffold, and rootless bind-mount
ownership. Use `./setup.sh --check` for a read-only preflight. The complete
first-run sequence and service checks are in [QUICKSTART.md](QUICKSTART.md);
ongoing stack and dashboard commands are in [OPERATIONS.md](OPERATIONS.md).

`./reset.sh` archives generated state before preparing another setup attempt.
Treat `./reset.sh --hard` as destructive because it removes local runtime data.

## Host Migration

The migration tools preserve all named profiles by default, merge the old
Memory Vault into `appdata/hermes/obsidian-memory-vault`, retain previous host
configs as `config.host-migration.yaml`, and rewrite known host-only paths and
old web-service URLs for the integrated Firecrawl, Camofox, and SearXNG stack.

Inventory the old host first, then dry-run the copy from the new checkout:

```bash
HERMES_HOST_HOME=/path/to/.hermes \
HERMES_MEMORY_VAULT=/path/to/Memory_Vault \
  ./scripts/collect-host-migration-inventory.sh

OLD_HERMES_HOME=/path/to/.hermes \
OLD_MEMORY_VAULT=/path/to/Memory_Vault \
  ./scripts/migrate-host-hermes-data.sh --dry-run
```

Do not replace or delete copied `appdata/` content without a timestamped copy
or verified Restic snapshot. See [OPERATIONS.md](OPERATIONS.md) for the apply
command, permission normalization, cron review, integrated URL checks, and
post-migration validation.

## Hindsight Bank Restore

Use the guarded restore utilities when migrating a Hindsight document-transfer
backup into a new, empty Hindsight instance. Validate the manifest, checksums,
and preserved observations before contacting the target API:

```bash
python3 scripts/validate-hindsight-bank-backup.py \
  --backup-dir tmp/hindsight-bank-backups/<backup-name> \
  --report tmp/hindsight-bank-backups/<backup-name>/validation-report.json

python3 scripts/restore-hindsight-bank-backup.py \
  --backup-dir tmp/hindsight-bank-backups/<backup-name> \
  --api-url http://127.0.0.1:8888
```

The restore command defaults to a read-only target preflight and refuses banks
that already exist. The write-enabled `--apply` path creates a timestamped raw
Hindsight archive first, preserves observations, and verifies imported counts.
Restore one pilot bank before all banks, and verify LLM connectivity before
requeueing consolidation. See [OPERATIONS.md](OPERATIONS.md) for the complete
preflight, pilot, all-bank, and post-restore sequence.

## Restic Backups

The rootless backup jobs use Restic with repository credentials kept outside
this Git checkout. Use an SFTP or rest-server backend on the NAS; do not place
the repository on a locally mounted CIFS/SMB share. The daily job at **07:45 JST** backs up Hermes profile data,
the Memory Vault, configuration, Headroom, Firecrawl Postgres, and a validated
logical Hindsight export. It deliberately excludes Firecrawl Redis/RabbitMQ,
runtime caches, logs, images, and generic `tmp` data.

The weekly raw Hindsight checkpoint runs Saturday at 08:00 JST. It briefly
stops only `hindsight-mcp`, captures its raw `.pg0` state, and starts the
service again before uploading to Restic.

Install the persistent user timers after configuring
`~/.config/hermes-backup/restic.env` and its password file:

```bash
sudo loginctl enable-linger "$USER"
./scripts/install-backup-timers.sh
```

Manual runs use the same workflows as the timers:

```bash
./scripts/backup-hermes-data.sh --mode daily
./scripts/backup-hermes-data.sh --mode weekly-raw
```

Load that environment to inspect snapshots, restorable data size, physical
repository size, and repository integrity:

```bash
set -a
source ~/.config/hermes-backup/restic.env
set +a
restic snapshots --tag hermes
restic stats --mode restore-size <snapshot-id>
restic stats --mode raw-data
restic check
```

See [OPERATIONS.md](OPERATIONS.md) for manual daily and weekly jobs, timer logs,
snapshot browsing, isolated restores, and the tested recovery order. Recovery
testing must restore into a separate directory or Compose checkout; never
overwrite live `appdata/` as a test.

## Rootless Runtime Guarantees

The supported deployment path is rootless Docker for the deployment user.
`DOCKER_SOCK` must point to `/run/user/<uid>/docker.sock`, and Compose commands
must load `.env`. Bind-mounted runtime state can have user-namespace mapped
numeric owners; that is expected and must not be "fixed" recursively from the
host. Use `scripts/normalize-appdata-permissions.sh` when host group readability
needs repair.

The rootless profile scaffold pins Hindsight to `hermes-<profile>`, uses
Compose service names for Hindsight, Headroom, Firecrawl, Camofox, and SearXNG,
and makes the first named profile active. [QUICKSTART.md](QUICKSTART.md) owns the
setup commands; [OPERATIONS.md](OPERATIONS.md) owns status and repair commands.

## Remote UI Access

By default, published ports bind to `127.0.0.1` so the services are local-only.
Hermes Dashboard refuses a non-loopback bind until basic authentication is
configured. Hindsight's control plane and Headroom's proxy/statistics endpoint
also require a trusted network boundary; the Headroom port is an LLM proxy, not
just a read-only dashboard. Prefer an SSH or Tailscale tunnel when practical.

See [OPERATIONS.md](OPERATIONS.md) for password-hash generation, direct login
verification, bind settings, and force recreation. Use the explicit
`http://<server-ip>:9119/login?next=%2F` path for dashboard basic auth.

The default rootless stack publishes Hermes' API-server port on
`${HERMES_API_BIND_HOST:-127.0.0.1}:${HERMES_API_HOST_PORT:-8642}`, but Hermes
only listens there when you enable the API server with Hermes configuration
such as `API_SERVER_KEY` or `API_SERVER_ENABLED`. For webhook-style gateway
platforms, add the needed `ports:` entries to `docker-compose.yml` and
configure those Hermes platforms to bind `0.0.0.0` inside the container.

## Notes

- Hindsight multi-bank mode uses `http://127.0.0.1:8888/mcp/`. The profile configs use single-bank URLs like `http://127.0.0.1:8888/mcp/hermes-research/` to keep memory separated by profile.
- If you need to create, inspect, or delete banks manually, temporarily enable the commented `hindsight_admin` MCP server in the relevant profile config. Keep it disabled during normal profile use.
- If you change `HEADROOM_PROXY_HOST_PORT`, update the matching `HEADROOM_PROXY_URL` in each profile config or template that should use it.
- If you change `HEADROOM_IMAGE`, update the same image string in each profile config or template unless your Hermes config supports environment interpolation.
- Keep `hermes-data/config.rootless.yaml` as the reusable base-profile seed config. Make Hindsight, Headroom, and profile-specific agent setup changes in the active profile config under `appdata/hermes/profiles/<name>/config.yaml`.
- Hermes still exposes `default` as its built-in base `HERMES_HOME`; this stack makes the quickstart-created named profile active, but mirrors the selected runtime model into the base config because some dashboard model/session routes are not fully profile-scoped.
- Headroom's upstream Compose stack also includes Qdrant and Neo4j for memory-oriented features. This bundle keeps the base stack lean; add those services later if you enable Headroom features that require them.
- Do not run a separate host-installed Hermes against the same `appdata/hermes` directory.
- Do not point two Hermes containers at the same `appdata/hermes` directory simultaneously.

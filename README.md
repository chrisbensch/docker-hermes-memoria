# Hermes Agent Compose Stack

This repository deploys Hermes Agent as a rootless Docker Compose stack. It
includes isolated Hermes profiles, Hindsight semantic memory, Headroom
compression tools, and Firecrawl, SearXNG, and Camofox for web access. Hermes
is not installed on the host.

Start a new deployment with [QUICKSTART.md](QUICKSTART.md). Use
[OPERATIONS.md](OPERATIONS.md) for health checks, authentication, migration,
backup, restore, and recovery procedures.

## Documentation

- [QUICKSTART.md](QUICKSTART.md) — first deployment and service verification.
- [OPERATIONS.md](OPERATIONS.md) — day-two operation and recovery runbook.
- [AGENTS.md](AGENTS.md) — repository conventions and safety requirements.
- [`docs/superpowers/`](docs/superpowers/) — approved design and implementation
  records.

## What Runs

`docker-compose.yml` defines these Compose services:

| Service | Purpose |
| --- | --- |
| `hermes` | Hermes gateway and supervised Dashboard in one container. |
| `hindsight-mcp` | Hindsight API, HTTP MCP endpoints, and control plane. |
| `headroom-proxy` | Headroom LLM proxy and statistics API. |
| `headroom-mcp` | Intentionally sleeping container that runs Headroom MCP on demand over stdio. |
| `firecrawl-api` and dependencies | Firecrawl extraction and search services. |
| `searxng` and `searxng-core` | Local SearXNG endpoint used by Firecrawl. |
| `camofox` | Browser service used by Hermes. |

The default host bindings are loopback-only:

| Endpoint | Default URL |
| --- | --- |
| Hermes API (when enabled) | `http://127.0.0.1:8642` |
| Hermes Dashboard | `http://127.0.0.1:9119` |
| Hindsight API / MCP | `http://127.0.0.1:8888` |
| Hindsight UI | `http://127.0.0.1:9999` |
| Headroom proxy / stats | `http://127.0.0.1:8787` |
| Firecrawl | `http://127.0.0.1:3002` |
| SearXNG | `http://127.0.0.1:8889` |
| Camofox | `http://127.0.0.1:9377` |

Container-to-container configuration must use Compose service names, not host
ports, container IPs, or generated container names. For example, Hermes uses
`http://hindsight-mcp:8888`, `http://firecrawl-api:3002`, and
`http://camofox:9377`.

## Local State And Configuration

Tracked files are templates and automation. Runtime state and generated local
configuration stay outside Git:

- `.env` is the local Compose configuration, copied from `.env.example`. It
  selects host bindings, images, the rootless Docker socket, and sidecar
  settings, including Hindsight's LLM configuration.
- `appdata/` is ignored runtime state. It holds Hermes profiles, SQLite data,
  the shared Obsidian vault, Hindsight data, Headroom data, and Firecrawl
  PostgreSQL data.
- `appdata/hermes/.env` holds Hermes provider credentials and runtime variables.
  Keep provider keys here, not in tracked files.
- `web-search/searxng-settings.yml` is generated from its tracked template with
  a unique local secret.
- `.firecrawl-src/` is the ignored local Firecrawl source checkout used to
  build the required `nuq-postgres` image.

`./setup.sh` prepares these inputs interactively. `./setup.sh --check` performs
a read-only readiness check.

## Profiles And Memory

Create a named profile with:

```bash
./scripts/create-profile.sh <profile-name>
```

Profile names use lowercase letters, numbers, underscores, and hyphens.
`default` is reserved. Each profile gets its own Hermes state and a dedicated
Hindsight bank named `hermes-<profile>`.

The repository includes `research` as an optional reference profile. It
demonstrates a role-specific `SOUL.md`, profile overrides, and the memory
wiring; it is not required by the stack or by other profiles. Create it with
`./scripts/create-profile.sh research`, or choose a name that fits your own
deployment. For the optional `research` example, the resulting memory wiring
is:

```text
Hermes state:    /opt/data/profiles/research/
Hindsight bank:  hermes-research
Hindsight MCP:   http://hindsight-mcp:8888/mcp/hermes-research/
Obsidian notes:  /opt/data/obsidian-memory-vault/Profiles/research/
```

The profile creation script creates the bank when the Hindsight API is
available. The generated profile config pins MCP to that one bank, preventing
normal profile work from mixing memories. The optional multi-bank admin MCP
endpoint remains disabled unless it is needed temporarily for bank management.

Use the memory layers for distinct jobs:

1. Hermes built-in memory for hot facts and small operational notes.
2. Hermes session search for transcript recall.
3. Hindsight for semantic memory, reflection, and durable knowledge.
4. The shared Obsidian vault for durable notes, indexes, logs, and
   cross-profile material.
5. Headroom for compression, compressed-content retrieval, and statistics; it
   is not the durable memory store.

Profile templates live in `hermes-data/profile-templates/rootless/`. Optional
role-specific `SOUL.md` overrides belong in
`hermes-data/profile-overrides/<profile>/`; use placeholders rather than
machine paths, secrets, or copied bank IDs.

## Headroom MCP: Rootless Stdio Only

Headroom MCP is deliberately not an HTTP endpoint. The long-running
`headroom-proxy` service provides LLM proxy and statistics APIs. Hermes invokes
the MCP server only over stdio in the sleeping `hermes-headroom-mcp` container:

```text
sg hostdocker -c 'exec docker exec -i -e HEADROOM_PROXY_URL=http://headroom-proxy:8787 hermes-headroom-mcp headroom mcp serve'
```

The rootless Docker socket configured by `DOCKER_SOCK` is mounted into the
Hermes container. `sg hostdocker -c` is required because some
Hermes execution paths drop supplementary groups before starting MCP
subprocesses. Do not add another socket mount, hard-code a socket GID, or point
the MCP configuration at `headroom-proxy`.

Test the configured path with Hermes, replacing `<profile>` with a real profile:

```bash
docker compose --env-file .env exec -T hermes \
  /package/admin/s6/command/s6-setuidgid hermes \
  hermes -p <profile> mcp test headroom
```

For profiles copied from an older deployment, preview and then apply the
targeted config migration:

```bash
python3 scripts/fix-headroom-mcp-command.py --dry-run
python3 scripts/fix-headroom-mcp-command.py
```

See the [Headroom operations procedure](OPERATIONS.md#headroom-mcp-stdio-and-socket-access)
for diagnostics and rollback.

## Rootless Data Ownership

Run Compose as the same unprivileged user that owns the rootless Docker daemon.
Set `DOCKER_SOCK` to that user's socket, normally
`/run/user/$(id -u)/docker.sock`. Numeric ownership shown on bind-mounted
runtime data can differ from the host user because of user-namespace mapping;
that is expected.

The shared Obsidian vault needs a deliberate write policy. Inside Hermes it is
owned by `hermes:root`; setgid directories and POSIX ACLs allow both the
container identity and the deployment user to create files. Install Ubuntu's
`acl` package, then use only the canonical repair helper when needed:

```bash
./scripts/fix-obsidian-vault-permissions.sh
```

Do not recursively `chown` `appdata/`, guess a subordinate UID, or run host
`sudo chown` against a container path. The helper is run by setup and migration
when they create or import the vault.

## Operating The Stack

Run commands from the repository root with the explicit environment file:

```bash
docker compose --env-file .env config --quiet
docker compose --env-file .env up -d
docker compose --env-file .env ps
```

The Compose validation needs `.env`, `.firecrawl-src/apps/nuq-postgres`, and
the generated SearXNG settings file. It verifies rendered configuration only;
use the endpoint and profile checks in [OPERATIONS.md](OPERATIONS.md) to verify
runtime health.

`./reset.sh` archives generated state before another setup attempt. Its `--hard`
option removes local runtime state, so make and verify a backup first.

Dashboard, Hindsight UI, and Headroom proxy ports are local-only by default.
Before exposing any of them, configure Dashboard basic authentication and use a
trusted network boundary such as an SSH or Tailscale tunnel. The Headroom port
is an LLM proxy, not a read-only dashboard.

## Migration, Backup, And Restore

Migration from a host-installed Hermes deployment begins with an inventory and
a dry run. The migration script preserves the old configuration under
`host-migration/`, backs up existing destination data under
`migration-backups/`, and migrates all profiles unless explicitly narrowed.
Follow the complete [host migration procedure](OPERATIONS.md#host-install-migration);
never replace `appdata/` without a verified timestamped copy or Restic snapshot.

Backups use Restic credentials stored outside this checkout. The daily job
creates logical application exports, including a validated Hindsight bank
export; the weekly raw job briefly stops Hindsight to capture its `.pg0` state.
Install the user timers with:

```bash
./scripts/install-backup-timers.sh
```

Use `scripts/validate-hindsight-bank-backup.py` before any bank restore.
`scripts/restore-hindsight-bank-backup.py --apply` writes to the target service
and requires its preflight and pre-restore checkpoint. The
[backup and recovery runbook](OPERATIONS.md#restic-backups) covers credentials,
manual jobs, timer logs, isolated restores, and the recovery sequence.

Never commit `.env`, `appdata/`, generated SearXNG settings, `.firecrawl-src/`,
Restic credentials, backup contents, or copied provider secrets.

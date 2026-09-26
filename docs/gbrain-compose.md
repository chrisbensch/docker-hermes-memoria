# Shared GBrain Compose Integration

The opt-in `gbrain` Compose profile runs one shared GBrain instance for every
Hermes profile. It is a migration target: starting it does not import a
Hindsight export, change Hermes configuration, or disable Hindsight.

The source is pinned to GBrain commit
`31f257a0a7b218b40e03d302bc6913c99f26f0ec` (release `v0.54.1.1`). Change the
pin only after reviewing and testing another full commit SHA.

## Architecture and boundaries

The profile adds three internal services:

- `gbrain-postgres` is Postgres 16 with pgvector. It joins only the isolated
  `gbrain-db` network and publishes no port.
- `gbrain` joins `gbrain-db` to reach Postgres and the ordinary application
  network to serve HTTP MCP. Its HTTP port binds to loopback by default; set
  an explicit trusted LAN address when you need the authenticated `/admin`
  dashboard.
- `gbrain-mcp` is the Hermes-facing authenticated broker on the ordinary
  application network. It has no database route or database credential.

Hermes also remains on only the ordinary application network. It cannot route
to `gbrain-postgres` and receives neither the database password nor GBrain's
owner bootstrap token. The GBrain container receives those two values from
read-only files; they are not stored in Compose environment values. No GBrain
service mounts Hindsight state, the Obsidian vault, or the Docker socket.

GBrain starts with the explicit `--surface full` server ceiling. Normal Hermes
profiles should receive the `memory-writer` grant profile and its `starter`
surface. That combination supplies the normal read/write agent operations
without granting operator administration, delegated-agent authority, or every
maintenance operation. A wider server ceiling does not widen a client grant.

Dynamic Client Registration (DCR) is disabled: the Compose command deliberately
omits both `--enable-dcr` flags. Provision each profile through the protected
owner-admin path so GBrain records a distinct OAuth client identity. Separate
clients provide attribution and revocation, not data isolation: profiles still
read and write the same shared brain.

## Prepare private storage and secrets

Create all bind-mount targets before the first Compose run. `create_host_path:
false` makes a missing or misspelled path fail instead of silently creating a
root-owned directory.

```bash
mkdir -p appdata/gbrain/shared appdata/gbrain/postgres \
  appdata/gbrain/secrets/profiles
umask 077
openssl rand -hex 32 > appdata/gbrain/secrets/postgres-password.txt
openssl rand -hex 32 > appdata/gbrain/secrets/admin-token.txt
chmod 0700 appdata/gbrain/secrets appdata/gbrain/secrets/profiles
chmod 0600 appdata/gbrain/secrets/postgres-password.txt \
  appdata/gbrain/secrets/admin-token.txt
```

The database password must contain only letters, digits, `_`, or `-`; the hex
command satisfies that restriction. The entrypoint rejects other characters
instead of interpolating an unsafe connection URL. Keep the admin token stable:
it is the protected owner credential used to create, inspect, and revoke OAuth
clients. Never put either value in `.env`, a command argument, or version
control.

Upstream `gbrain init` writes its effective database URL to `config.json`.
This image's entrypoint removes that redundant field after initialization and
before every later command because it reconstructs the URL from the mounted
password file. Treat `appdata/gbrain/shared` as private operational state even
though the database credential is scrubbed.

If paths differ, set these non-secret file locations in `.env`:

```dotenv
GBRAIN_POSTGRES_PASSWORD_FILE=./appdata/gbrain/secrets/postgres-password.txt
GBRAIN_ADMIN_TOKEN_FILE=./appdata/gbrain/secrets/admin-token.txt
GBRAIN_PROFILE_CREDENTIALS_DIR=./appdata/gbrain/secrets/profiles
```

## Initialize the Postgres brain

The recommended public setup is self-hosted-first. Run the guided initializer
and provide an OpenAI-compatible base URL (including `/v1`), its exact model
ID, vector dimension, and an API key. Put the key in the ignored `.env` value
`GBRAIN_EMBEDDING_API_KEY`; setup copies it into the mounted mode-0600 secret
file. Leave it blank when the local server does not require authentication:

```bash
./setup.sh --gbrain
```

Before Postgres is started or initialized, setup sends a real request to
`/v1/embeddings` and refuses an unreachable endpoint, malformed response, or
vector width different from the declared dimension. The endpoint, model, and
key are read from ignored `.env`; the key is synchronized into its mode-0600
file and mounted read-only. The tracked template contains no deployment
address or credential.

For a low-resource or temporarily unavailable provider, initialize lexical
retrieval without any model or key:

```bash
./setup.sh --gbrain --no-embedding
```

This is a deliberate deferred mode. Choose the model and dimension together
before importing data; changing them after data exists requires GBrain's
embedding migration workflow, not a normal config edit.

The commands below are the equivalent manual path. Prefer the guided flow for
new deployments because it enforces provider validation first.

Start the database, then initialize GBrain non-interactively from the private
password file. The entrypoint constructs `GBRAIN_DATABASE_URL` only inside the
GBrain process.

```bash
docker compose --env-file .env --profile gbrain up -d gbrain-postgres
docker compose --env-file .env --profile gbrain run --rm gbrain \
  init --non-interactive --no-embedding
docker compose --env-file .env --profile gbrain run --rm gbrain doctor --json
```

`--no-embedding` keeps initial migration and retrieval deterministic and avoids
introducing a provider secret. Enable a reviewed embedding provider later if
semantic retrieval is required; do not put its key in Compose source.

## Optional self-hosted reasoning

Reasoning may use a different OpenAI-compatible gateway through GBrain's
`litellm:` adapter. Keep its token in an ignored file and put only non-secret
settings in `.env`:

```dotenv
GBRAIN_LITELLM_BASE_URL=http://your-gateway.example:4000/v1
GBRAIN_LITELLM_API_KEY_FILE=./appdata/gbrain/secrets/litellm-api-key.txt
GBRAIN_CHAT_MODEL=litellm:auto/offline
GBRAIN_EXPANSION_MODEL=litellm:auto/offline
GBRAIN_MODEL_DISCOVERY=off
```

Use a gateway route appropriate to the deployment. An offline/local route is
the self-hosted-first policy; a pinned model or stable gateway alias is more
reproducible. Hosted Codex, OpenAI, Anthropic, or other LiteLLM-supported models
remain opt-in alternatives. After starting GBrain, set the engine-backed
default and test both reasoning touchpoints:

```bash
docker compose --env-file .env --profile gbrain run --rm gbrain \
  config set models.default 'litellm:auto/offline'
docker compose --env-file .env --profile gbrain run --rm gbrain \
  config set models.dream.extract_atoms 'litellm:auto/offline'
docker compose --env-file .env --profile gbrain run --rm gbrain \
  providers test --touchpoint chat
docker compose --env-file .env --profile gbrain run --rm gbrain \
  models doctor --skip=openai --json
```

Test embeddings separately because their `openai:` adapter intentionally uses
the dedicated embedding endpoint and credential. The explicit atom-extraction
override is required because that upstream call path otherwise retains its own
hosted-model default instead of inheriting `models.default`.

## Start the database and GBrain

```bash
docker compose --env-file .env --profile gbrain up -d --build \
  gbrain-postgres gbrain
docker compose --env-file .env --profile gbrain ps \
  gbrain-postgres gbrain
docker compose --env-file .env --profile gbrain logs --tail=100 \
  gbrain-postgres gbrain
```

The GBrain health probe is `http://gbrain:3131/health` from the application
network. The upstream MCP endpoint is `http://gbrain:3131/mcp`; a profile named
`maestro` uses only `http://gbrain-mcp:3132/mcp/maestro`.

To view the admin dashboard from a trusted LAN, set these private `.env`
values to the host's LAN address and restart GBrain:

```dotenv
GBRAIN_HTTP_BIND_HOST=192.0.2.10
GBRAIN_HTTP_HOST_PORT=3131
```

Then open `http://192.0.2.10:3131/admin/` and authenticate with the owner
bootstrap token from `appdata/gbrain/secrets/admin-token.txt`. Keep this port on
a trusted network; the dashboard exposes client and activity administration.

## Per-profile access

Create one GBrain OAuth client per Hermes profile with the `memory-writer`
profile and source `default`. Keep DCR disabled. The following local-engine
command uses the private Postgres network, writes the one-time credential
handoff to an owner-only directory, and does not print its secret:

```bash
mkdir -m 0700 -p appdata/gbrain/shared/handoffs
docker compose --env-file .env --profile gbrain exec -T gbrain \
  /usr/local/bin/gbrain mcp grant hermes-maestro \
  --harness generic --profile memory-writer --source default \
  --skills memory-only --url http://127.0.0.1:3131/mcp \
  --credentials-out /var/lib/gbrain/home/handoffs/maestro.json --json
```

Repeat with the actual profile name. Previewing with `--dry-run` does not
create a client and does not produce a credential file. Never reuse one
handoff for multiple profiles. The handoff appears on the host at
`appdata/gbrain/shared/handoffs/maestro.json`; keep that directory mode 0700.

Convert each private handoff into the broker file and a separate Hermes token
fragment. The helper refuses insecure inputs and existing destinations and
prints paths only:

```bash
python3 scripts/prepare-gbrain-profile-credentials.py \
  --profile maestro \
  --credentials appdata/gbrain/shared/handoffs/maestro.json \
  --output-dir appdata/gbrain/secrets/profiles
```

The resulting mode-0600, non-symlink
`appdata/gbrain/secrets/profiles/<profile>.env` contains these exact fields:

```dotenv
GBRAIN_BROKER_TOKEN=<unique-random-value-at-least-32-characters>
GBRAIN_OAUTH_CLIENT_ID=<that-profile-client-id>
GBRAIN_OAUTH_CLIENT_SECRET=<that-profile-client-secret>
```

Keep the containing `profiles` directory mode 0700. The broker maps the route
and static inbound token to that profile's OAuth client, then mints and caches
an upstream client-credentials token. This lets GBrain audit the originating
profile without giving Hermes the upstream client secret.

Each Hermes profile then uses the same endpoint with its own ignored secret:

```yaml
mcp_servers:
  gbrain:
    url: "http://gbrain-mcp:3132/mcp/maestro"
    headers:
      Authorization: "Bearer ${GBRAIN_MCP_PROXY_TOKEN}"
    enabled: true
    connect_timeout: 10
    timeout: 120
```

Set `GBRAIN_MCP_PROXY_TOKEN` in that Hermes profile's mode-0600 `.env` to the
value in the generated `<profile>.broker-token` fragment. Merge the fragment
through the profile's normal secret-management path; do not source it into an
interactive shell or print it. Do not reuse it across profiles.

After at least one profile credential exists, start and inspect the broker:

```bash
docker compose --env-file .env --profile gbrain up -d --build gbrain-mcp
docker compose --env-file .env --profile gbrain ps gbrain-postgres gbrain gbrain-mcp
```

Keep Hindsight enabled during comparison and rollback testing.
Registering clients and changing Hermes profile files are separate write
operations and are not performed by starting this Compose profile.

## Backup and rollback

The authoritative memory is now Postgres, not `appdata/gbrain/shared`. Before a
production cutover, add a logical `pg_dump` of `gbrain-postgres` to the normal
verified backup workflow; a live filesystem copy of its data directory is not
a logical backup.

Stop in dependency order:

```bash
docker compose --env-file .env --profile gbrain stop \
  gbrain-mcp gbrain gbrain-postgres
```

Preserve `appdata/gbrain/postgres`, `appdata/gbrain/shared`, and all credential
files through the rollback window. Never remove, replace, or recursively change
ownership of those paths without a verified timestamped copy or Restic
snapshot. Removing the Compose profile does not migrate data back to Hindsight.

# Self-hosted Honcho Compose Integration

Honcho is the relationship-memory layer for user preferences, goals, working
context, and communication style. GBrain remains the separate source-backed
knowledge store. Hermes uses Honcho through its built-in memory provider and
uses GBrain through its existing profile-scoped MCP broker.

The base Compose stack runs Honcho v3.2.2 from the official
multi-architecture GHCR image, with a private PostgreSQL/pgvector database and
Redis. The API has no published host port. Hermes, Honcho's API, and its deriver
share a dedicated application network; only Honcho's API and deriver can reach
its internal-only database network. Nothing is shared with GBrain's database.

## Configure and start Honcho

Copy the image and setting entries from `.env.example` into the ignored local
`.env` if they are not already present. Generate a Postgres password and add an
OpenAI-compatible provider key for Honcho's background reasoning:

```bash
openssl rand -hex 32
```

Set the resulting hex value as `HONCHO_POSTGRES_PASSWORD`, the provider token
as `HONCHO_LLM_OPENAI_API_KEY`, and the optional OpenAI-compatible base URL as
`HONCHO_LLM_OPENAI_BASE_URL` in `.env`. `HONCHO_LLM_MODEL` selects the model
for Honcho's deriver, summaries, reasoning, and dreamer. Embeddings use a
separate model and optional endpoint through `HONCHO_EMBEDDING_MODEL` and
`HONCHO_EMBEDDING_BASE_URL`. Set `HONCHO_EMBEDDING_VECTOR_DIMENSIONS` to match
the existing pgvector columns and `HONCHO_EMBEDDING_DIMENSIONS_MODE=always`
when the embedding provider must receive an explicit `dimensions` request.
Verify the endpoint returns that many values before starting Honcho; changing
the configured dimension alone does not migrate existing database columns.
GPT-6 Luna supports function calls through Chat
Completions when `reasoning_effort` is `none`, so the stack sets that effort
for Honcho's model tasks by default. Keep credentials private. The hex
password format avoids URL-encoding issues in Honcho's database URI.

`./setup.sh` creates the persistent bind-mount directories and generates a
Postgres password for new installations. For an existing manual deployment,
create the directories before starting the services:

```bash
mkdir -p appdata/honcho/postgres appdata/honcho/redis
docker compose --env-file .env up -d
docker compose --env-file .env ps
docker compose --env-file .env logs --tail=100 honcho-api honcho-deriver
```

Honcho is configured with authentication disabled because its API is not
published and only Hermes, the API, and deriver join the dedicated app network.
Do not publish port 8000 or attach unrelated containers to `honcho-app` without
first enabling Honcho authentication and configuring a workspace-scoped JWT in
Hermes.

## Enable the Hermes provider

The initial rollout enables Honcho in Maestro only. To configure a new Maestro
installation, run its memory setup command and choose the local/self-hosted
server URL `http://honcho-api:8000` when prompted:

```bash
docker compose --env-file .env exec hermes hermes -p maestro memory setup honcho
```

The setup wizard stores the Honcho connection settings in that profile's
`honcho.json` and activates the Honcho memory provider in its `config.yaml`.
Choose `hybrid` recall mode to enable both automatic context injection and
Honcho tools. Keep automatic writeback enabled. The default `async` write
frequency lets Hermes continue while messages are saved in the background.

For a single-user gateway, map the operator's platform identity to one stable
Honcho peer when prompted. Leave other users on distinct peers. Avoid pinning
every gateway user to one peer if the bot serves multiple people.

Check the active profile and provider:

```bash
docker compose --env-file .env exec hermes hermes -p maestro memory status
docker compose --env-file .env exec hermes hermes -p maestro honcho status
```

Maestro should send conversation messages and receive relationship context.
Use it for stable preferences, goals, communication style, and durable
relationship context. Keep credentials and incidental sensitive disclosures
out. Treat generated Honcho context as personalization, not evidence. Use
GBrain when an answer needs source-backed claims; do not copy all Honcho memory
into GBrain.

Honcho may use external LLM and embedding APIs, depending on the provider
configured in `.env`. The API key stays in the ignored `.env`; do not place it
in tracked templates or Hermes profile files.

With Hermes' default `saveMessages: true`, writeback sends the conversation
messages themselves to Honcho, not only the extracted profile facts. Honcho
stores and processes those messages in its own database. Avoid sending secrets
or material you do not want retained; if raw message retention is unacceptable,
disable `saveMessages` in the profile's `honcho.json` and reassess whether the
remaining memory behavior meets your needs.

Daily Restic backups include an online, checked custom-format dump of Honcho
PostgreSQL. See the [backup and restore runbook](../OPERATIONS.md#restic-backups)
before replacing or restoring its data.

## Version pin

The Compose fallback pins `ghcr.io/plastic-labs/honcho:v3.2.2` by its GHCR
multi-architecture manifest digest. Update the version and digest together
after reviewing the upstream release and its registry metadata.

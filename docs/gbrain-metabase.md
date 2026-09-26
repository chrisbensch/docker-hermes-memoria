# GBrain Metabase Analytics

Metabase is an optional visualization layer for the shared GBrain deployment.
It runs under the `gbrain-viz` Compose profile, stores its users and dashboards
in a separate `metabase` PostgreSQL database, and connects to GBrain with a
dedicated read-only account.

The tracked default binds the UI to `127.0.0.1:3000`. For a trusted LAN, set
`METABASE_BIND_HOST` in the ignored `.env` to the host's LAN address. PostgreSQL
remains unpublished in either case.

## Initialize And Start

Initialize GBrain first, then provision Metabase:

```bash
./setup.sh --gbrain
./setup.sh --gbrain-metabase
docker compose --env-file .env --profile gbrain-viz ps
```

The Metabase setup is idempotent. It generates two private password files and
a stable `METABASE_ENCRYPTION_SECRET_KEY` in the ignored `.env`, creates the
application database, installs reporting views, verifies the access boundary,
and starts the UI. Preserve the encryption key during recovery; without it,
Metabase cannot decrypt stored datasource credentials.

On first visit, create the Metabase administrator through its browser wizard.
Add GBrain as a PostgreSQL datasource with:

```text
Host: gbrain-postgres
Port: 5432
Database: gbrain
Username: gbrain_metabase_reader
Password: contents of METABASE_READER_PASSWORD_FILE
Schemas: metabase_reporting only
```

Metabase authentication is independent of GBrain's `/admin` bootstrap token.
Do not enter the GBrain database-owner password or owner token in Metabase.

## Reporting Surface

The reader can query only these aggregate views:

- `overview`: corpus, embedding, relationship, client, and activity totals.
- `profile_inventory`: pages, chunks, tags, links, and timeline counts by migrated profile.
- `content_inventory`: page counts by profile and migration classification.
- `mcp_activity_daily`: request counts and latency by agent, operation, and status.
- `ingestion_activity_daily`: ingestion run and updated-page counts.
- `relationship_inventory`: relationship counts between profiles.
- `client_health`: active and deleted OAuth-client totals.

The default surface does not expose memory bodies, chunk text, embeddings,
timeline detail, request parameters or errors, OAuth client rows or secrets,
or ingestion summaries. Add any content-bearing view only as a deliberate local
customization after reviewing who can access Metabase.

## Operations And Backups

```bash
docker compose --env-file .env --profile gbrain-viz up -d metabase
docker compose --env-file .env logs --tail=200 metabase
curl -fsS "http://${METABASE_BIND_HOST:-127.0.0.1}:${METABASE_HOST_PORT:-3000}/api/health"
```

Daily Restic staging includes both `gbrain-postgres.dump` and, after Metabase
has been initialized, `metabase-postgres.dump`. The second archive contains
Metabase users, questions, dashboards, and settings. GBrain content remains in
the first archive. Both dumps are checked with `pg_restore --list` when made.

After restoring a Restic snapshot to an isolated directory, validate the
Metabase archive and metadata together:

```bash
python3 scripts/validate-gbrain-postgres-backup.py \
  --database metabase \
  --backup /path/to/metabase-postgres.dump
```

Before upgrading the pinned `METABASE_IMAGE`, create a daily backup, retain the
old image reference, change the pin in the ignored `.env`, and let Metabase run
its application-database migrations. Confirm `/api/health` and dashboard access
before removing the old image.

To rotate either database password, place a new 64-character hexadecimal value
in its configured private file and rerun `./setup.sh --gbrain-metabase`.
Rotating the application-database password recreates the Metabase container;
rotating only the reader password also requires updating the saved datasource
password in Metabase.

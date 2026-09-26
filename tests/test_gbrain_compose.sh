#!/usr/bin/env bash
set -euo pipefail

hermes_block=$(sed -n '/^  hermes:$/,/^  hindsight-mcp:/p' docker-compose.yml)
postgres_block=$(sed -n '/^  gbrain-postgres:$/,/^  gbrain:$/p' docker-compose.yml)
server_block=$(sed -n '/^  gbrain:$/,/^  gbrain-mcp:$/p' docker-compose.yml)
broker_block=$(sed -n '/^  gbrain-mcp:$/,/^  metabase:/p' docker-compose.yml)
metabase_block=$(sed -n '/^  metabase:$/,/^  firecrawl-api:/p' docker-compose.yml)
gbrain_block=$(sed -n '/^  gbrain-postgres:$/,/^  firecrawl-api:/p' docker-compose.yml)

# One opt-in shared service backed by a private pgvector/Postgres engine.
grep -Fq 'profiles: ["gbrain", "gbrain-viz"]' <<< "$postgres_block"
grep -Fq 'image: ${GBRAIN_POSTGRES_IMAGE:-pgvector/pgvector:pg16}' <<< "$postgres_block"
grep -Fq 'POSTGRES_PASSWORD_FILE: /run/gbrain-secrets/postgres-password' <<< "$postgres_block"
grep -Fq 'source: ${APPDATA_DIR:-./appdata}/gbrain/postgres' <<< "$postgres_block"
grep -Fq 'target: /var/lib/postgresql/data' <<< "$postgres_block"
grep -A2 -F 'networks:' <<< "$postgres_block" | grep -Fq -- '- gbrain-db'
! grep -Fq -- '- default' <<< "$postgres_block"
! grep -Fq 'ports:' <<< "$postgres_block"

# Metabase is opt-in, publishes only its UI, and receives neither GBrain's
# database-owner password nor its dashboard owner token.
grep -Fq 'profiles: ["gbrain-viz"]' <<< "$metabase_block"
grep -Fq 'image: ${METABASE_IMAGE:-metabase/metabase:v0.58.34@sha256:' <<< "$metabase_block"
grep -Fq 'MB_DB_USER: gbrain_metabase_app' <<< "$metabase_block"
grep -Fq 'MB_DB_PASS_FILE: /run/metabase-secrets/app-db-password' <<< "$metabase_block"
grep -Fq 'METABASE_BIND_HOST:-127.0.0.1' <<< "$metabase_block"
grep -Fq -- '- default' <<< "$metabase_block"
grep -Fq -- '- gbrain-db' <<< "$metabase_block"
! grep -Fq 'postgres-password' <<< "$metabase_block"
! grep -Fq 'admin-token' <<< "$metabase_block"

grep -Fq 'GBRAIN_REF: ${GBRAIN_REF:-31f257a0a7b218b40e03d302bc6913c99f26f0ec}' <<< "$server_block"
grep -Fq 'GBRAIN_HOME: /var/lib/gbrain/home' <<< "$server_block"
grep -Fq 'GBRAIN_DATABASE_PASSWORD_FILE: /run/gbrain-secrets/postgres-password' <<< "$server_block"
grep -Fq 'GBRAIN_ADMIN_BOOTSTRAP_TOKEN_FILE: /run/gbrain-secrets/admin-token' <<< "$server_block"
grep -Fq 'GBRAIN_EMBEDDING_API_KEY_FILE: /run/gbrain-secrets/embedding-api-key' <<< "$server_block"
grep -Fq '"${GBRAIN_HTTP_BIND_HOST:-127.0.0.1}:${GBRAIN_HTTP_HOST_PORT:-3131}:3131"' <<< "$server_block"
grep -Fq 'GBRAIN_EMBEDDING_BASE_URL_CONFIG: ${GBRAIN_EMBEDDING_BASE_URL:-}' <<< "$server_block"
grep -Fq 'GBRAIN_LITELLM_API_KEY_FILE: /run/gbrain-secrets/litellm-api-key' <<< "$server_block"
grep -Fq 'GBRAIN_LITELLM_BASE_URL_CONFIG: ${GBRAIN_LITELLM_BASE_URL:-}' <<< "$server_block"
grep -Fq 'command: ["serve", "--http", "--surface", "full"' <<< "$server_block"
! grep -Fq -- '--enable-dcr' <<< "$server_block"
grep -Fq 'source: ${APPDATA_DIR:-./appdata}/gbrain/shared' <<< "$server_block"
grep -Fq 'target: /var/lib/gbrain/home' <<< "$server_block"
grep -Fq -- '- default' <<< "$server_block"
grep -Fq -- '- gbrain-db' <<< "$server_block"
grep -Fq 'ports:' <<< "$server_block"
grep -Fq 'GBRAIN_HTTP_BIND_HOST:-127.0.0.1' <<< "$server_block"

# Hermes and its broker cannot route to Postgres and receive no DB/owner secret.
! grep -Fq 'gbrain-db' <<< "$hermes_block"
! grep -Fq 'gbrain-secrets' <<< "$hermes_block"
! grep -Fq 'gbrain-db' <<< "$broker_block"
! grep -Fq 'postgres-password' <<< "$broker_block"
! grep -Fq 'admin-token' <<< "$broker_block"
! grep -Fq 'ports:' <<< "$broker_block"
grep -Fq 'user: "0:0"' <<< "$broker_block"
grep -Fq 'GBRAIN_PROFILE_CREDENTIALS_DIR: /run/gbrain-oauth/profiles' <<< "$broker_block"
grep -Fq 'source: ${GBRAIN_PROFILE_CREDENTIALS_DIR:-./appdata/gbrain/secrets/profiles}' <<< "$broker_block"
grep -Fq 'target: /run/gbrain-oauth/profiles' <<< "$broker_block"
! grep -Eq 'GBRAIN_(OAUTH_CREDENTIALS_FILE|ALLOWED_TOOLS)' <<< "$broker_block"
grep -A2 '^  gbrain-db:' docker-compose.yml | grep -Fq 'internal: true'

# No provider key value, live vault, or Docker socket is present in Compose.
! grep -Eq '(OPENAI_API_KEY:|ANTHROPIC_API_KEY:|obsidian|hindsight|docker.sock)' <<< "$gbrain_block"
grep -Fq 'source: ${GBRAIN_EMBEDDING_API_KEY_FILE:-/dev/null}' <<< "$server_block"
grep -Fq 'target: /run/gbrain-secrets/embedding-api-key' <<< "$server_block"
grep -Fq 'source: ${GBRAIN_LITELLM_API_KEY_FILE:-/dev/null}' <<< "$server_block"
grep -Fq 'target: /run/gbrain-secrets/litellm-api-key' <<< "$server_block"

grep -Fq 'GBRAIN_REF=31f257a0a7b218b40e03d302bc6913c99f26f0ec' .env.example
grep -Fq 'GBRAIN_POSTGRES_IMAGE=pgvector/pgvector:pg16' .env.example
grep -Fq 'GBRAIN_POSTGRES_PASSWORD_FILE=./appdata/gbrain/secrets/postgres-password.txt' .env.example
grep -Fq 'GBRAIN_ADMIN_TOKEN_FILE=./appdata/gbrain/secrets/admin-token.txt' .env.example
grep -Fq 'GBRAIN_PROFILE_CREDENTIALS_DIR=./appdata/gbrain/secrets/profiles' .env.example
grep -Fq 'GBRAIN_EMBEDDING_BASE_URL=' .env.example
grep -Fq 'GBRAIN_EMBEDDING_MODEL=' .env.example
grep -Fq 'GBRAIN_EMBEDDING_DIMENSIONS=1024' .env.example
grep -Fq 'GBRAIN_EMBEDDING_API_KEY=' .env.example
grep -Fq 'GBRAIN_EMBEDDING_API_KEY_FILE=./appdata/gbrain/secrets/embedding-api-key.txt' .env.example
grep -Fq 'GBRAIN_LITELLM_BASE_URL=' .env.example
grep -Fq 'GBRAIN_LITELLM_API_KEY_FILE=./appdata/gbrain/secrets/litellm-api-key.txt' .env.example
grep -Fq 'METABASE_IMAGE=metabase/metabase:v0.58.34@sha256:' .env.example
grep -Fq 'METABASE_BIND_HOST=127.0.0.1' .env.example
grep -Fq 'METABASE_APP_DB_PASSWORD_FILE=./appdata/gbrain/secrets/metabase-app-db-password.txt' .env.example
grep -Fq 'METABASE_READER_PASSWORD_FILE=./appdata/gbrain/secrets/metabase-reader-password.txt' .env.example
! grep -Eq '10\.[0-9]+\.[0-9]+\.[0-9]+' .env.example
! grep -Fq 'GBRAIN_OAUTH_CREDENTIALS_FILE' .env.example
! grep -Eq 'GBRAIN_(HTTP_TEST|ALLOWLIST_TEST)' .env.example

grep -Fq 'v0.54.1.1' docs/gbrain-compose.md
grep -Fq 'memory-writer' docs/gbrain-compose.md
grep -Fq 'DCR) is disabled' docs/gbrain-compose.md
grep -Fq 'http://gbrain-mcp:3132/mcp/maestro' docs/gbrain-compose.md

grep -Fq 'git checkout --detach "$GBRAIN_REF"' gbrain/Dockerfile
grep -Fq 'FROM oven/bun:1.3.11-alpine' gbrain/Dockerfile
grep -Fq 'bun install --frozen-lockfile --production' gbrain/Dockerfile
! grep -Fq 'pglite-after-http-shutdown' gbrain/Dockerfile
[[ ! -e gbrain/patches/0001-close-pglite-after-http-shutdown.patch ]]
grep -Fq 'GBRAIN_DATABASE_PASSWORD_FILE' gbrain/entrypoint.sh
grep -Fq 'GBRAIN_ADMIN_BOOTSTRAP_TOKEN_FILE' gbrain/entrypoint.sh
grep -Fq 'GBRAIN_EMBEDDING_API_KEY_FILE' gbrain/entrypoint.sh
grep -Fq 'GBRAIN_LITELLM_API_KEY_FILE' gbrain/entrypoint.sh
grep -Fq 'scrub_persisted_database_url' gbrain/entrypoint.sh
grep -Fq 'delete config.database_url' gbrain/entrypoint.sh
grep -Fq 'exec bun /opt/gbrain/src/cli.ts "$@"' gbrain/entrypoint.sh
grep -Fq 'prepare-gbrain-profile-credentials.py' docs/gbrain-compose.md
grep -Fq 'GBRAIN_MCP_PROXY_TOKEN' docs/gbrain-compose.md
grep -Fq -- '--gbrain [--no-embedding]' setup.sh
grep -Fq -- '--gbrain-metabase' setup.sh
grep -Fq 'scripts/configure-gbrain-metabase.sh' setup.sh
grep -Fq 'scripts/configure-gbrain.sh' setup.sh
grep -Fq 'GBRAIN_EMBEDDING_API_KEY' setup.sh
grep -Fq 'Validating the embedding endpoint before database initialization' scripts/configure-gbrain.sh
grep -Fq 'validate-gbrain-embedding-provider.py' scripts/configure-gbrain.sh
grep -Fq -- '--embedding-model "openai:$embedding_model"' scripts/configure-gbrain.sh
grep -Fq -- 'init --non-interactive --no-embedding' scripts/configure-gbrain.sh
[[ -x scripts/configure-gbrain.sh ]]
[[ -x scripts/validate-gbrain-embedding-provider.py ]]
[[ -x scripts/configure-gbrain-metabase.sh ]]
grep -Fq 'condition: service_healthy' <<< "$broker_block"
grep -Fq 'GBRAIN_REF = "31f257a0a7b218b40e03d302bc6913c99f26f0ec"' \
  scripts/convert-hindsight-backup-to-gbrain.py

for removed in \
  docs/gbrain-pilot.md \
  gbrain/pilot-include.example \
  gbrain/http-test-corpus/architecture.md \
  scripts/prepare-gbrain-pilot-corpus.sh \
  scripts/run-gbrain-allowlist-test.sh \
  scripts/run-gbrain-http-test.sh \
  scripts/run-gbrain-pilot.sh \
  scripts/verify-gbrain-http-read-client.sh \
  tests/test_gbrain_pilot.sh; do
  [[ ! -e $removed ]]
done

! rg -q 'gbrain-pilot|gbrain-http-test|gbrain-proxy-test|gbrain-mcp-allowlist-test' \
  --glob '!tests/test_gbrain_compose.sh' \
  docker-compose.yml .env.example README.md docs gbrain gbrain-allowlist-proxy scripts tests

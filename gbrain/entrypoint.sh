#!/bin/sh
set -eu

: "${GBRAIN_HOME:=/var/lib/gbrain/home}"
mkdir -p "$GBRAIN_HOME"

scrub_persisted_database_url() {
  config_path="$GBRAIN_HOME/.gbrain/config.json"
  [ -f "$config_path" ] || return 0

  GBRAIN_CONFIG_PATH="$config_path" bun -e '
    import { chmodSync, readFileSync, renameSync, writeFileSync } from "node:fs";
    const path = process.env.GBRAIN_CONFIG_PATH;
    const config = JSON.parse(readFileSync(path, "utf8"));
    if (Object.hasOwn(config, "database_url")) {
      delete config.database_url;
      const temporaryPath = `${path}.tmp.${process.pid}`;
      writeFileSync(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
      renameSync(temporaryPath, path);
      chmodSync(path, 0o600);
    }
  '
}

# Keep database and owner credentials out of the Compose environment. The
# Postgres password is restricted to URI-safe characters by the deployment
# guide so it can be inserted into this private, process-local connection URL.
if [ -n "${GBRAIN_DATABASE_PASSWORD_FILE:-}" ]; then
  test -r "$GBRAIN_DATABASE_PASSWORD_FILE" || {
    echo "gbrain: database password file is not readable" >&2
    exit 1
  }
  database_password=$(tr -d '\r\n' < "$GBRAIN_DATABASE_PASSWORD_FILE")
  case "$database_password" in
    ''|*[!A-Za-z0-9_-]*)
      echo "gbrain: database password must use only A-Z, a-z, 0-9, _ or -" >&2
      exit 1
      ;;
  esac
  export GBRAIN_DATABASE_URL="postgresql://gbrain:${database_password}@gbrain-postgres:5432/gbrain"
  unset database_password
fi

if [ -n "${GBRAIN_ADMIN_BOOTSTRAP_TOKEN_FILE:-}" ]; then
  test -r "$GBRAIN_ADMIN_BOOTSTRAP_TOKEN_FILE" || {
    echo "gbrain: admin bootstrap token file is not readable" >&2
    exit 1
  }
  GBRAIN_ADMIN_BOOTSTRAP_TOKEN=$(tr -d '\r\n' < "$GBRAIN_ADMIN_BOOTSTRAP_TOKEN_FILE")
  test "${#GBRAIN_ADMIN_BOOTSTRAP_TOKEN}" -ge 32 || {
    echo "gbrain: admin bootstrap token must be at least 32 characters" >&2
    exit 1
  }
  export GBRAIN_ADMIN_BOOTSTRAP_TOKEN
fi

# Provider credentials use the same file-only boundary as database credentials.
# An empty file is intentional for keyless self-hosted OpenAI-compatible APIs.
if [ -n "${GBRAIN_EMBEDDING_API_KEY_FILE:-}" ]; then
  test -r "$GBRAIN_EMBEDDING_API_KEY_FILE" || {
    echo "gbrain: embedding API key file is not readable" >&2
    exit 1
  }
  OPENAI_API_KEY=$(tr -d '\r\n' < "$GBRAIN_EMBEDDING_API_KEY_FILE")
  if [ -n "$OPENAI_API_KEY" ]; then
    export OPENAI_API_KEY
  else
    unset OPENAI_API_KEY
  fi
fi

# Export public, non-secret provider settings only when setup configured them.
# Omitting them preserves GBrain's own persisted-config/.env resolution for
# existing deployments upgraded from an earlier version of this stack.
if [ -n "${GBRAIN_EMBEDDING_BASE_URL_CONFIG:-}" ]; then
  export OPENAI_BASE_URL="$GBRAIN_EMBEDDING_BASE_URL_CONFIG"
fi
if [ -n "${GBRAIN_EMBEDDING_MODEL_CONFIG:-}" ]; then
  export GBRAIN_EMBEDDING_MODEL="openai:$GBRAIN_EMBEDDING_MODEL_CONFIG"
fi
if [ -n "${GBRAIN_EMBEDDING_DIMENSIONS_CONFIG:-}" ]; then
  export GBRAIN_EMBEDDING_DIMENSIONS="$GBRAIN_EMBEDDING_DIMENSIONS_CONFIG"
fi

# Reasoning may use a different OpenAI-compatible gateway through GBrain's
# LiteLLM adapter. Keep its bearer token out of Compose environment values and
# leave every setting optional for embedding-only installations.
if [ -n "${GBRAIN_LITELLM_API_KEY_FILE:-}" ]; then
  test -r "$GBRAIN_LITELLM_API_KEY_FILE" || {
    echo "gbrain: LiteLLM API key file is not readable" >&2
    exit 1
  }
  LITELLM_API_KEY=$(tr -d '\r\n' < "$GBRAIN_LITELLM_API_KEY_FILE")
  if [ -n "$LITELLM_API_KEY" ]; then
    export LITELLM_API_KEY
  else
    unset LITELLM_API_KEY
  fi
fi
if [ -n "${GBRAIN_LITELLM_BASE_URL_CONFIG:-}" ]; then
  export LITELLM_BASE_URL="$GBRAIN_LITELLM_BASE_URL_CONFIG"
fi
if [ -n "${GBRAIN_CHAT_MODEL_CONFIG:-}" ]; then
  export GBRAIN_CHAT_MODEL="$GBRAIN_CHAT_MODEL_CONFIG"
fi
if [ -n "${GBRAIN_EXPANSION_MODEL_CONFIG:-}" ]; then
  export GBRAIN_EXPANSION_MODEL="$GBRAIN_EXPANSION_MODEL_CONFIG"
fi
if [ -n "${GBRAIN_MODEL_DISCOVERY_CONFIG:-}" ]; then
  export GBRAIN_MODEL_DISCOVERY="$GBRAIN_MODEL_DISCOVERY_CONFIG"
fi

# GBrain init persists its effective database URL in config.json. The Compose
# entrypoint always reconstructs that URL from the mounted password file, so
# remove the redundant credential before every command and after init writes
# the file. Keep the init exit status while still scrubbing partial runs.
scrub_persisted_database_url
if [ "${1:-}" = "init" ]; then
  set +e
  bun /opt/gbrain/src/cli.ts "$@"
  command_status=$?
  set -e
  scrub_persisted_database_url
  exit "$command_status"
fi

# Invoke the checked-out CLI directly rather than through a package script.
exec bun /opt/gbrain/src/cli.ts "$@"

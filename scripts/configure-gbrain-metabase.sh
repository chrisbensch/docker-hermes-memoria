#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
readonly ENV_FILE="$REPO_ROOT/.env"

usage() {
  cat <<'EOF'
Usage: ./setup.sh --gbrain-metabase

Provision Metabase's private application database and a least-privilege GBrain
reporting account, install curated aggregate views, and start the optional UI.
GBrain must already be initialized.
EOF
}

get_env_value() {
  local file=$1 key=$2
  [[ -f $file ]] || return 1
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); found=1} END {if (!found) exit 1}' "$file"
}

env_default() {
  local value
  value=$(get_env_value "$1" "$2" 2>/dev/null || true)
  printf '%s\n' "${value:-$3}"
}

set_env_var() {
  local file=$1 key=$2 value=$3 tmp
  tmp="$file.tmp.$$"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ "^" key "=" { print key "=" value; done = 1; next }
    { print }
    END { if (!done) print key "=" value }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    ./*) printf '%s/%s\n' "$REPO_ROOT" "${1#./}" ;;
    *) printf '%s/%s\n' "$REPO_ROOT" "$1" ;;
  esac
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    printf '\n'
  fi
}

ensure_secret_file() {
  local destination=$1
  mkdir -p "$(dirname -- "$destination")"
  chmod 0700 "$(dirname -- "$destination")"
  if [[ ! -e $destination ]]; then
    generate_secret > "$destination"
  fi
  [[ -f $destination && ! -L $destination ]] || {
    printf 'Secret path must be a regular, non-symlink file: %s\n' "$destination" >&2
    exit 1
  }
  chmod 0600 "$destination"
  local secret
  secret=$(tr -d '\r\n' < "$destination")
  [[ $secret =~ ^[0-9a-f]{64}$ ]] || {
    printf 'Expected a 64-character hexadecimal secret in %s\n' "$destination" >&2
    exit 1
  }
}

compose() {
  docker compose --env-file "$ENV_FILE" --profile gbrain-viz "$@"
}

[[ $# -eq 0 ]] || {
  case ${1:-} in
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
}

for command_name in docker awk; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Required command is unavailable: %s\n' "$command_name" >&2
    exit 1
  }
done
docker compose version >/dev/null 2>&1 || {
  printf 'The Docker Compose plugin is unavailable.\n' >&2
  exit 1
}
[[ -f $ENV_FILE ]] || {
  printf 'Missing %s; run ./setup.sh first.\n' "$ENV_FILE" >&2
  exit 1
}
[[ -f $REPO_ROOT/gbrain/metabase-reporting.sql ]] || {
  printf 'Missing reporting view definition.\n' >&2
  exit 1
}

app_password_setting=$(env_default "$ENV_FILE" METABASE_APP_DB_PASSWORD_FILE ./appdata/gbrain/secrets/metabase-app-db-password.txt)
reader_password_setting=$(env_default "$ENV_FILE" METABASE_READER_PASSWORD_FILE ./appdata/gbrain/secrets/metabase-reader-password.txt)
app_password_path=$(resolve_path "$app_password_setting")
reader_password_path=$(resolve_path "$reader_password_setting")
ensure_secret_file "$app_password_path"
ensure_secret_file "$reader_password_path"

encryption_key=$(get_env_value "$ENV_FILE" METABASE_ENCRYPTION_SECRET_KEY 2>/dev/null || true)
if [[ -z $encryption_key ]]; then
  encryption_key=$(generate_secret)
  set_env_var "$ENV_FILE" METABASE_ENCRYPTION_SECRET_KEY "$encryption_key"
fi
[[ $encryption_key =~ ^[0-9a-f]{64}$ ]] || {
  printf 'METABASE_ENCRYPTION_SECRET_KEY must be a 64-character hexadecimal value.\n' >&2
  exit 1
}
unset encryption_key

set_env_var "$ENV_FILE" METABASE_APP_DB_PASSWORD_FILE "$app_password_setting"
set_env_var "$ENV_FILE" METABASE_READER_PASSWORD_FILE "$reader_password_setting"
set_env_var "$ENV_FILE" METABASE_IMAGE "${METABASE_IMAGE:-$(env_default "$ENV_FILE" METABASE_IMAGE metabase/metabase:v0.58.34@sha256:abd7e4d9162e4dff67d5958d29e55b1e79de8029c51fddfdc12d9903ad126873)}"
set_env_var "$ENV_FILE" METABASE_BIND_HOST "${METABASE_BIND_HOST:-$(env_default "$ENV_FILE" METABASE_BIND_HOST 127.0.0.1)}"
set_env_var "$ENV_FILE" METABASE_HOST_PORT "${METABASE_HOST_PORT:-$(env_default "$ENV_FILE" METABASE_HOST_PORT 3000)}"

compose config --quiet
compose up -d gbrain-postgres

provision_sql=$(mktemp)
trap 'rm -f -- "$provision_sql"' EXIT
app_password=$(tr -d '\r\n' < "$app_password_path")
reader_password=$(tr -d '\r\n' < "$reader_password_path")
cat > "$provision_sql" <<SQL
\\set ON_ERROR_STOP on
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gbrain_metabase_app') THEN
    CREATE ROLE gbrain_metabase_app LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gbrain_reporting') THEN
    CREATE ROLE gbrain_reporting NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gbrain_metabase_reader') THEN
    CREATE ROLE gbrain_metabase_reader LOGIN;
  END IF;
END
\$\$;
ALTER ROLE gbrain_metabase_app PASSWORD '$app_password';
ALTER ROLE gbrain_metabase_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE gbrain_metabase_reader PASSWORD '$reader_password';
ALTER ROLE gbrain_metabase_reader LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE gbrain_reporting NOLOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE gbrain_metabase_reader CONNECTION LIMIT 5;
ALTER ROLE gbrain_metabase_reader SET default_transaction_read_only = on;
ALTER ROLE gbrain_metabase_reader SET statement_timeout = '30s';
ALTER ROLE gbrain_metabase_reader SET lock_timeout = '2s';
GRANT gbrain_reporting TO gbrain_metabase_reader;
GRANT CONNECT ON DATABASE gbrain TO gbrain_metabase_reader;
SQL
unset app_password reader_password

compose exec -T gbrain-postgres psql --username=gbrain --dbname=gbrain < "$provision_sql"
if ! compose exec -T gbrain-postgres psql --username=gbrain --dbname=postgres -Atqc \
  "SELECT 1 FROM pg_database WHERE datname = 'metabase'" | grep -qx 1; then
  compose exec -T gbrain-postgres createdb --username=gbrain --owner=gbrain_metabase_app \
    --encoding=UTF8 --template=template0 metabase
fi
compose exec -T gbrain-postgres psql --username=gbrain --dbname=postgres -v ON_ERROR_STOP=1 \
  -c 'ALTER DATABASE metabase OWNER TO gbrain_metabase_app' >/dev/null
compose exec -T gbrain-postgres psql --username=gbrain --dbname=gbrain \
  < "$REPO_ROOT/gbrain/metabase-reporting.sql"

privileges=$(compose exec -T gbrain-postgres psql --username=gbrain --dbname=gbrain -Atqc \
  "SELECT has_table_privilege('gbrain_metabase_reader','public.pages','SELECT')::text || '|' || has_table_privilege('gbrain_metabase_reader','metabase_reporting.overview','SELECT')::text")
[[ $privileges == 'false|true' ]] || {
  printf 'Reporting privilege validation failed: %s\n' "$privileges" >&2
  exit 1
}

compose up -d metabase
printf '\nMetabase provisioning is complete.\n'
printf 'UI: http://%s:%s\n' \
  "$(env_default "$ENV_FILE" METABASE_BIND_HOST 127.0.0.1)" \
  "$(env_default "$ENV_FILE" METABASE_HOST_PORT 3000)"
printf 'GBrain datasource: host=gbrain-postgres port=5432 database=gbrain user=gbrain_metabase_reader schema=metabase_reporting\n'
printf 'Reader password file: %s\n' "$reader_password_path"

#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
env_file=${HERMES_ENV_FILE:-$repo_dir/.env}
service=${HERMES_DASHBOARD_SERVICE:-hermes-dashboard}
username=${HERMES_DASHBOARD_USERNAME:-admin}
recreate=1
dry_run=0

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: scripts/set-dashboard-password.sh [--username USER] [--no-recreate] [--dry-run]

Generates a Hermes dashboard password hash inside the dashboard container,
backs up the base runtime config, writes dashboard.basic_auth settings, and
recreates the dashboard service unless --no-recreate is passed.

Environment:
  DASH_PASSWORD              New password. If unset, prompt securely.
  HERMES_ENV_FILE            Compose env file. Defaults to ./.env.
  HERMES_DASHBOARD_SERVICE   Compose service. Defaults to hermes-dashboard.
  HERMES_DASHBOARD_USERNAME  Dashboard username. Defaults to admin.
USAGE
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --username)
      [ "$#" -ge 2 ] || fail "--username requires a value"
      username=$2
      shift 2
      ;;
    --no-recreate)
      recreate=0
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[ -f "$env_file" ] || fail "Environment file not found: $env_file"
command -v docker >/dev/null 2>&1 || fail "docker is required"
[ -n "$username" ] || fail "Username must not be empty"
case $username in
  *$'\n'*|*$'\r'*) fail "Username must not contain newlines" ;;
esac

password_was_set=0
if [ "${DASH_PASSWORD+x}" = x ]; then
  password_was_set=1
else
  read -rsp 'New dashboard password: ' DASH_PASSWORD
  printf '\n'
  export DASH_PASSWORD
fi

cleanup() {
  if [ "$password_was_set" -eq 0 ]; then
    unset DASH_PASSWORD
  fi
}
trap cleanup EXIT

[ -n "$DASH_PASSWORD" ] || fail "Password must not be empty"

dashboard_hash=$(
  docker compose --env-file "$env_file" exec -T -e DASH_PASSWORD "$service" \
    python -c 'import os; from plugins.dashboard_auth.basic import hash_password; print(hash_password(os.environ["DASH_PASSWORD"]))'
)
[ -n "$dashboard_hash" ] || fail "Dashboard hash generation returned an empty value"

if [ "$dry_run" -eq 1 ]; then
  printf 'DRY RUN: generated dashboard password hash for user %s; no config changed.\n' "$username"
  exit 0
fi

backup_path=$(
  docker compose --env-file "$env_file" exec -T "$service" sh -lc '
    set -eu
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    src=/opt/data/config.yaml
    dst=/opt/data/config.yaml.dashboard-auth-backup-$ts
    cp "$src" "$dst"
    printf "%s\n" "$dst"
  '
)

docker compose --env-file "$env_file" exec -T "$service" \
  /opt/hermes/.venv/bin/hermes -p default config set dashboard.basic_auth.username "$username"
docker compose --env-file "$env_file" exec -T "$service" \
  /opt/hermes/.venv/bin/hermes -p default config set dashboard.basic_auth.password_hash "$dashboard_hash"

printf 'Updated dashboard credentials in /opt/data/config.yaml\n'
printf 'Backup: %s\n' "$backup_path"

if [ "$recreate" -eq 1 ]; then
  docker compose --env-file "$env_file" up -d --force-recreate "$service"
  docker compose --env-file "$env_file" logs --tail=100 "$service"
else
  printf 'Dashboard was not recreated. Run this before logging in:\n'
  printf '  docker compose --env-file %s up -d --force-recreate %s\n' "$env_file" "$service"
fi

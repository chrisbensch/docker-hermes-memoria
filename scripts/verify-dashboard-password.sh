#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
env_file=${HERMES_ENV_FILE:-$repo_dir/.env}
service=${HERMES_DASHBOARD_SERVICE:-hermes-dashboard}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: scripts/verify-dashboard-password.sh

Verifies a dashboard password against the hash in Hermes' base runtime config.

Environment:
  DASH_PASSWORD              Password to verify. If unset, prompt securely.
  HERMES_ENV_FILE            Compose env file. Defaults to ./.env.
  HERMES_DASHBOARD_SERVICE   Compose service. Defaults to hermes-dashboard.
USAGE
}

case ${1:-} in
  -h|--help)
    usage
    exit 0
    ;;
  '')
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

[ -f "$env_file" ] || fail "Environment file not found: $env_file"
command -v docker >/dev/null 2>&1 || fail "docker is required"

password_was_set=0
if [ "${DASH_PASSWORD+x}" = x ]; then
  password_was_set=1
else
  read -rsp 'Dashboard password to verify: ' DASH_PASSWORD
  printf '\n'
  export DASH_PASSWORD
fi

cleanup() {
  if [ "$password_was_set" -eq 0 ]; then
    unset DASH_PASSWORD
  fi
}
trap cleanup EXIT

result=$(
  docker compose --env-file "$env_file" exec -T -e DASH_PASSWORD "$service" \
    python - <<'PY'
import os
from hermes_cli.config import cfg_get, load_config
from plugins.dashboard_auth.basic import _verify_password

encoded = cfg_get(load_config(), "dashboard", "basic_auth", "password_hash")
print("MATCH" if _verify_password(os.environ["DASH_PASSWORD"], encoded) else "NO MATCH")
PY
)

printf '%s\n' "$result"
[ "$result" = MATCH ]

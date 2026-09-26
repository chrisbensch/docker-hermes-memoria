#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
stack_dir=$(cd "$script_dir/.." && pwd)
mode=${1:---dry-run}

case "$mode" in
  --dry-run) ;;
  --apply) ;;
  *)
    printf 'Usage: %s [--dry-run|--apply]\n' "$0" >&2
    exit 2
    ;;
esac

version=$(docker compose --env-file "$stack_dir/.env" exec -T hermes hermes --version)
if [[ ! $version =~ Hermes\ Agent\ v([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  printf 'Could not determine the Hermes version; migration requires v0.21.5 or newer.\n' >&2
  exit 1
fi
if (( ${BASH_REMATCH[1]} == 0 && (${BASH_REMATCH[2]} < 21 || (${BASH_REMATCH[2]} == 21 && ${BASH_REMATCH[3]} < 5)) )); then
  printf 'Hermes v0.21.5 or newer is required for multiplex migration.\n' >&2
  exit 1
fi

docker compose --env-file "$stack_dir/.env" exec -T hermes \
  hermes gateway migrate --multiplex --dry-run
if [[ "$mode" == --dry-run ]]; then
  exit 0
fi

# Preserve the profile and root configuration before the migration can fold
# profile gateway settings into the shared gateway. The archive stays in the
# ignored Hermes runtime data directory and is checked before applying.
docker compose --env-file "$stack_dir/.env" exec -T hermes sh -eu -c '
  umask 077
  data=/opt/data
  backup_dir="$data/migration-backups"
  mkdir -p "$backup_dir"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  archive="$backup_dir/telegram-gateway-multiplex-$stamp.tar.gz"
  list="$backup_dir/.telegram-gateway-multiplex-$stamp.list"
  find "$data/profiles" -type f \( -name config.yaml -o -name .env -o -name gateway_state.json \) -print > "$list"
  if [ -f "$data/config.yaml" ]; then printf "%s\n" "$data/config.yaml" >> "$list"; fi
  if [ -f "$data/gateway_state.json" ]; then printf "%s\n" "$data/gateway_state.json" >> "$list"; fi
  if [ -f "$data/active_profile" ]; then printf "%s\n" "$data/active_profile" >> "$list"; fi
  [ -s "$list" ] || { echo "No Hermes configuration files found to back up." >&2; exit 1; }
  tar -czf "$archive" -T "$list"
  tar -tzf "$archive" >/dev/null
  rm -f "$list"
  printf "Verified pre-migration backup: %s\n" "$archive"
'

docker compose --env-file "$stack_dir/.env" exec -T hermes \
  hermes gateway migrate --multiplex --yes

#!/usr/bin/env sh
set -eu

hermes_container=${HERMES_CONTAINER:-hermes-compose-mcp-hermes-1}
hindsight_container=${HINDSIGHT_CONTAINER:-hermes-compose-mcp-hindsight-mcp-1}

normalize_tree() {
  container=$1
  path=$2

  if ! docker exec "$container" test -d "$path" >/dev/null 2>&1; then
    printf 'Skipping %s:%s; container or path is unavailable.\n' "$container" "$path" >&2
    return 0
  fi

  docker exec -u 0 "$container" sh -c '
    path=$1
    chgrp -R 0 "$path"
    find "$path" -type d -exec chmod g+rx {} +
    find "$path" -type f -exec chmod g+r {} +
    find "$path" -type d -exec chmod o-rwx {} +
    find "$path" -type f -exec chmod o-rwx {} +
  ' sh "$path"
}

normalize_tree "$hermes_container" /opt/data
normalize_tree "$hindsight_container" /home/hindsight/.pg0

printf 'Normalized Hermes and Hindsight appdata for host group access.\n'
printf 'Database-owned Firecrawl/Postgres, RabbitMQ, and Redis internals were left unchanged.\n'

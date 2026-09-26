#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

usage() {
  cat <<'EOF'
Usage: backup-gbrain-postgres.sh --output FILE [--metadata FILE]

Creates an online, logical custom-format backup of the GBrain PostgreSQL
database and validates that pg_restore can read its catalog. The database
container must already be running.
EOF
}

output=
metadata=
while [[ $# -gt 0 ]]; do
  case $1 in
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      output=$2
      shift 2
      ;;
    --metadata)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      metadata=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n $output ]] || { usage >&2; exit 2; }
metadata=${metadata:-$output.json}
mkdir -p "$(dirname -- "$output")" "$(dirname -- "$metadata")"
[[ ! -e $output && ! -e $metadata ]] || {
  printf 'Refusing to overwrite an existing backup or metadata file.\n' >&2
  exit 1
}

compose() {
  docker compose --env-file "$REPO_ROOT/.env" "$@"
}

container_id=$(compose ps --status running -q gbrain-postgres)
[[ -n $container_id ]] || {
  printf 'gbrain-postgres is not running; no backup was created.\n' >&2
  exit 1
}

temporary="$output.partial"
trap 'rm -f -- "$temporary"' EXIT
compose exec -T gbrain-postgres pg_dump \
  --username=gbrain \
  --dbname=gbrain \
  --format=custom \
  --no-owner \
  --no-privileges > "$temporary"

[[ -s $temporary ]] || { printf 'GBrain database backup is empty.\n' >&2; exit 1; }
compose exec -T gbrain-postgres pg_restore --list < "$temporary" >/dev/null
mv -- "$temporary" "$output"
trap - EXIT

python3 - "$output" "$metadata" <<'PY'
import datetime
import hashlib
import json
import sys
from pathlib import Path

archive = Path(sys.argv[1])
metadata = Path(sys.argv[2])
digest = hashlib.sha256()
with archive.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)

payload = {
    "backup_timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "database": "gbrain",
    "format": "postgresql-custom",
    "archive": archive.name,
    "bytes": archive.stat().st_size,
    "sha256": digest.hexdigest(),
}
metadata.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

printf 'GBrain backup created and validated: %s\n' "$output"

#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

usage() {
  cat <<'EOF'
Usage: restore-gbrain-postgres-backup.sh --backup FILE [--metadata FILE] [--apply]

Validates a logical GBrain backup and checks that the target database contains
no user tables. Without --apply this is a read-only preflight. With --apply,
GBrain is stopped, the archive is restored with fail-fast semantics, and
GBrain is started again. A non-empty target is always refused.
EOF
}

backup=
metadata=
apply=no
while [[ $# -gt 0 ]]; do
  case $1 in
    --backup)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      backup=$2
      shift 2
      ;;
    --metadata)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      metadata=$2
      shift 2
      ;;
    --apply)
      apply=yes
      shift
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

[[ -n $backup ]] || { usage >&2; exit 2; }
metadata=${metadata:-$backup.json}

compose() {
  docker compose --env-file "$REPO_ROOT/.env" "$@"
}

container_id=$(compose ps --status running -q gbrain-postgres)
[[ -n $container_id ]] || {
  printf 'gbrain-postgres must be running for restore preflight.\n' >&2
  exit 1
}

python3 "$REPO_ROOT/scripts/validate-gbrain-postgres-backup.py" \
  --backup "$backup" \
  --metadata "$metadata" \
  --skip-catalog >/dev/null
compose exec -T gbrain-postgres pg_restore --list < "$backup" >/dev/null

user_tables=$(compose exec -T gbrain-postgres psql \
  --username=gbrain --dbname=gbrain --tuples-only --no-align \
  --command="SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema');")
user_tables=${user_tables//$'\r'/}
[[ $user_tables =~ ^[0-9]+$ ]] || { printf 'Could not determine target table count.\n' >&2; exit 1; }
[[ $user_tables == 0 ]] || {
  printf 'Refusing restore: target GBrain database contains %s user tables.\n' "$user_tables" >&2
  exit 1
}

if [[ $apply != yes ]]; then
  printf 'Preflight passed: archive is readable and target database is empty. Re-run with --apply to restore.\n'
  exit 0
fi

gbrain_was_running=no
if [[ -n $(compose ps --status running -q gbrain) ]]; then
  gbrain_was_running=yes
  compose stop gbrain
fi

restart_gbrain() {
  status=$?
  if [[ $gbrain_was_running == yes ]]; then
    compose start gbrain >/dev/null || true
  fi
  exit "$status"
}
trap restart_gbrain EXIT

compose exec -T gbrain-postgres pg_restore \
  --exit-on-error \
  --no-owner \
  --no-privileges \
  --username=gbrain \
  --dbname=gbrain < "$backup"

printf 'GBrain database restore completed.\n'

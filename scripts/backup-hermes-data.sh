#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
readonly STATE_ROOT=${HERMES_BACKUP_STATE_ROOT:-/home/sysadmin/.local/state/hermes-backup}
readonly CONFIG_FILE=${HERMES_BACKUP_RESTIC_ENV:-/home/sysadmin/.config/hermes-backup/restic.env}

usage() {
  cat <<'EOF'
Usage: backup-hermes-data.sh --mode daily|weekly-raw

Creates Restic backups for the rootless Hermes Compose stack. Daily mode stages
Hermes, logical Hindsight, Headroom, Firecrawl Postgres, and deployment config.
Weekly raw mode additionally creates a brief quiesced raw Hindsight checkpoint.
EOF
}

mode=
while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      mode=$2
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

[[ $mode == daily || $mode == weekly-raw ]] || { usage >&2; exit 2; }

compose() {
  docker compose --env-file "$REPO_ROOT/.env" "$@"
}

mkdir -p "$STATE_ROOT/staging"
exec 9>"$STATE_ROOT/backup.lock"
flock -n 9 || { printf 'Backup already running.\n' >&2; exit 1; }

[[ -r $CONFIG_FILE ]] || { printf 'Missing Restic configuration: %s\n' "$CONFIG_FILE" >&2; exit 1; }
config_mode=$(stat -c '%a' "$CONFIG_FILE")
[[ $config_mode == 400 || $config_mode == 600 ]] || {
  printf 'Restic configuration must be mode 0400 or 0600: %s\n' "$CONFIG_FILE" >&2
  exit 1
}

set -a
source "$CONFIG_FILE"
set +a
[[ -n ${RESTIC_REPOSITORY:-} ]] || { printf 'RESTIC_REPOSITORY is not configured.\n' >&2; exit 1; }
[[ -n ${RESTIC_PASSWORD_FILE:-} && -r ${RESTIC_PASSWORD_FILE:-} ]] || {
  printf 'RESTIC_PASSWORD_FILE is missing or unreadable.\n' >&2
  exit 1
}

timestamp=$(date -u +%Y%m%d-%H%M%SZ)
staging="$STATE_ROOT/staging/$mode-$timestamp"
mkdir -m 700 "$staging"
success=no
raw_stopped=no

finish() {
  status=$?
  if [[ $raw_stopped == yes ]]; then
    compose start hindsight-mcp >/dev/null || true
  fi
  if [[ $status -eq 0 && $success == yes ]]; then
    rm -rf "$staging"
  else
    printf 'Backup staging retained: %s\n' "$staging" >&2
  fi
  exit "$status"
}
trap finish EXIT

stage_metadata() {
  cp "$REPO_ROOT/.env" "$staging/compose.env"
  cp "$REPO_ROOT/web-search/searxng-settings.yml" "$staging/searxng-settings.yml"
  python3 - "$staging/metadata.json" "$REPO_ROOT" "$mode" "$timestamp" <<'PY'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

output = Path(sys.argv[1])
root = Path(sys.argv[2])
mode = sys.argv[3]
timestamp = sys.argv[4]

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
payload = {
    "backup_timestamp": timestamp,
    "mode": mode,
    "git_revision": revision,
    "files": {
        "compose.env": sha256(root / ".env"),
        "searxng-settings.yml": sha256(root / "web-search" / "searxng-settings.yml"),
    },
}
output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

stage_daily() {
  compose exec -T hermes tar \
    --exclude=./logs \
    --exclude=./.cache \
    --exclude=./audio_cache \
    --exclude=./image_cache \
    --exclude=./lazy-packages \
    -C /opt/data -czf - . > "$staging/hermes-data.tar.gz"
  compose exec -T headroom-proxy tar -C /home/nonroot -czf - .headroom > "$staging/headroom-data.tar.gz"
  compose exec -T firecrawl-nuq-postgres sh -lc 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > "$staging/firecrawl-postgres.sql"
  python3 "$REPO_ROOT/scripts/backup-hindsight-banks.py" \
    --api-url http://127.0.0.1:8888 \
    --output-dir "$staging" \
    --backup-name hindsight-logical \
    --report "$staging/hindsight-export-report.json"
  python3 "$REPO_ROOT/scripts/validate-hindsight-bank-backup.py" \
    --backup-dir "$staging/hindsight-logical" \
    --report "$staging/hindsight-validation.json"
}

stage_raw_hindsight() {
  compose stop hindsight-mcp
  raw_stopped=yes
  compose run --rm --no-deps --entrypoint tar hindsight-mcp \
    -C /home/hindsight -czf - .pg0 > "$staging/hindsight-raw.tar.gz"
  compose start hindsight-mcp
  raw_stopped=no
}

stage_metadata
if [[ $mode == daily ]]; then
  stage_daily
  tags=(--tag hermes --tag daily --tag logical)
else
  stage_raw_hindsight
  tags=(--tag hermes --tag weekly --tag raw)
fi

restic backup "${tags[@]}" "$staging"
restic forget --prune --keep-daily 14 --keep-weekly 8 --keep-monthly 12
restic snapshots --tag hermes --latest 1
success=yes

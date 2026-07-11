#!/usr/bin/env bash
set -euo pipefail

script=scripts/backup-hermes-data.sh

bash -n "$script"
grep -Fq 'flock' "$script"
grep -Fq 'backup-hindsight-banks.py' "$script"
grep -Fq 'validate-hindsight-bank-backup.py' "$script"
grep -Fq 'firecrawl-nuq-postgres' "$script"
grep -Fq 'headroom-proxy' "$script"
grep -Fq -- '--exclude=./logs' "$script"
grep -Fq -- '--exclude=./.cache' "$script"
grep -Fq -- '--exclude=./audio_cache' "$script"
grep -Fq -- '--exclude=./image_cache' "$script"
grep -Fq -- '--exclude=./lazy-packages' "$script"
grep -Fq -- "--exclude='./profiles/*/state.db*'" "$script"
grep -Fq 'export-sqlite-database.py' "$script"
grep -Fq 'source.backup(target' scripts/export-sqlite-database.py
grep -Fq -- '--tag daily --group-by host,tags' "$script"
grep -Fq -- '--tag weekly --group-by host,tags' "$script"
grep -Fq -- '--keep-daily 14 --keep-weekly 8 --keep-monthly 12' "$script"
grep -Fq -- '--keep-weekly 8 --keep-monthly 12' "$script"
! grep -Fq 'restic backup appdata' "$script"
! grep -Fq 'firecrawl-redis' "$script"
! grep -Fq 'firecrawl-rabbitmq' "$script"

"$script" --help | grep -Fq 'daily|weekly-raw'

grep -Fq 'OnCalendar=*-*-* 07:45:00 Asia/Tokyo' systemd/hermes-backup.timer
grep -Fq 'OnCalendar=Sat *-*-* 08:00:00 Asia/Tokyo' systemd/hermes-hindsight-raw-backup.timer
grep -Fq 'Persistent=true' systemd/hermes-backup.timer
grep -Fq 'Persistent=true' systemd/hermes-hindsight-raw-backup.timer
grep -Fq 'Linger=yes' scripts/install-backup-timers.sh
grep -Fq 'scripts/install-backup-timers.sh' README.md
grep -Fq 'restic check' README.md
grep -Fq '07:45 JST' README.md
grep -Fq 'weekly raw Hindsight' README.md

sqlite_test_dir=$(mktemp -d)
trap 'rm -rf "$sqlite_test_dir"' EXIT
python3 - "$sqlite_test_dir/source.db" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute("CREATE TABLE backup_test (value TEXT NOT NULL)")
    connection.execute("INSERT INTO backup_test VALUES ('consistent')")
PY
python3 scripts/export-sqlite-database.py "$sqlite_test_dir/source.db" > "$sqlite_test_dir/backup.db"
python3 - "$sqlite_test_dir/backup.db" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    assert connection.execute("PRAGMA integrity_check").fetchone() == ("ok",)
    assert connection.execute("SELECT value FROM backup_test").fetchone() == ("consistent",)
PY

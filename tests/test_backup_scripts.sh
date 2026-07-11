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
! grep -Fq 'restic backup appdata' "$script"
! grep -Fq 'firecrawl-redis' "$script"
! grep -Fq 'firecrawl-rabbitmq' "$script"

"$script" --help | grep -Fq 'daily|weekly-raw'

grep -Fq 'OnCalendar=*-*-* 07:45:00 Asia/Tokyo' systemd/hermes-backup.timer
grep -Fq 'OnCalendar=Sat *-*-* 08:00:00 Asia/Tokyo' systemd/hermes-hindsight-raw-backup.timer
grep -Fq 'Persistent=true' systemd/hermes-backup.timer
grep -Fq 'Persistent=true' systemd/hermes-hindsight-raw-backup.timer
grep -Fq 'Linger=yes' scripts/install-backup-timers.sh

#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
readonly UNIT_DIR="$HOME/.config/systemd/user"

if ! loginctl show-user "$USER" -p Linger | grep -qx 'Linger=yes'; then
  printf 'Enable linger first: sudo loginctl enable-linger %s\n' "$USER" >&2
  exit 1
fi

for unit in \
  hermes-backup.service \
  hermes-backup.timer \
  hermes-hindsight-raw-backup.service \
  hermes-hindsight-raw-backup.timer; do
  install -D -m 0644 "$REPO_ROOT/systemd/$unit" "$UNIT_DIR/$unit"
done

systemctl --user daemon-reload
systemctl --user enable --now hermes-backup.timer hermes-hindsight-raw-backup.timer
systemctl --user list-timers --all --no-pager | grep -E 'hermes-backup|hermes-hindsight-raw-backup' || true

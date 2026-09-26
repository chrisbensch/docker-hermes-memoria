#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

data_dir="$tmp_dir/hermes"
vault_dir="$tmp_dir/vault"
mkdir -p "$data_dir/profiles"
printf 'legacy root state\n' > "$data_dir/gateway_state.json"
mkdir -p "$data_dir/profiles/legacy"
printf 'legacy profile state\n' > "$data_dir/profiles/legacy/gateway_state.json"

HERMES_DATA_DIR="$data_dir" \
HERMES_APPDATA_DIR="$tmp_dir" \
HERMES_OBSIDIAN_VAULT_DIR="$vault_dir" \
HERMES_CREATE_HINDSIGHT_BANK=0 \
HERMES_PROFILE_ACTIVATE=1 \
  "$repo_dir/scripts/create-profile.sh" telegram-check >/dev/null

[[ $(cat "$data_dir/active_profile") == telegram-check ]]
[[ $(cat "$data_dir/gateway_state.json") == 'legacy root state' ]]
[[ $(cat "$data_dir/profiles/legacy/gateway_state.json") == 'legacy profile state' ]]
[[ ! -e "$data_dir/profiles/telegram-check/gateway_state.json" ]]

if rg -n 'gateway_state\.json|gateway_state.*running|gateway_state.*stopped' \
  "$repo_dir/scripts/create-profile.sh" "$repo_dir/scripts/migrate-host-hermes-data.sh"; then
  echo 'Profile setup or host migration still writes per-profile gateway state.' >&2
  exit 1
fi

echo 'Telegram gateway lifecycle checks passed.'

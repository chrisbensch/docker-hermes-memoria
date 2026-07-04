#!/usr/bin/env sh
set -eu

usage() {
  printf 'Usage: %s <profile-name> [hindsight-bank-id]\n' "$0" >&2
  printf 'Example: %s research hermes-research\n' "$0" >&2
  printf 'Default Hindsight bank ID: hermes-<profile-name>\n' >&2
}

if [ "${1:-}" = "" ]; then
  usage
  exit 2
fi

profile_name=$1
bank_id=${2:-hermes-$profile_name}

case "$profile_name" in
  *[!a-z0-9_-]*)
    printf 'Invalid profile name: %s\n' "$profile_name" >&2
    printf 'Use only lowercase letters, numbers, underscore, and hyphen.\n' >&2
    exit 2
    ;;
esac

case "$profile_name" in
  default|hermes|test|tmp|root|sudo)
    printf 'Invalid profile name: %s\n' "$profile_name" >&2
    printf 'This name is reserved by Hermes; choose a named profile such as research.\n' >&2
    exit 2
    ;;
esac

case "$bank_id" in
  *[!A-Za-z0-9_-]*)
    printf 'Invalid Hindsight bank ID: %s\n' "$bank_id" >&2
    printf 'Use only letters, numbers, underscore, and hyphen.\n' >&2
    exit 2
    ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stack_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
template_name=${HERMES_PROFILE_TEMPLATE:-rootful}
template_dir="$stack_dir/hermes-data/profile-templates/$template_name"
profile_dir="$stack_dir/hermes-data/profiles/$profile_name"
active_profile_file="$stack_dir/hermes-data/active_profile"
hindsight_mcp_base=${HERMES_HINDSIGHT_MCP_BASE:-http://127.0.0.1:8888/mcp}
headroom_mcp_description=${HERMES_HEADROOM_MCP_DESCRIPTION:-docker-backed stdio server using ghcr.io/chopratejas/headroom:latest}
activate_profile=${HERMES_PROFILE_ACTIVATE:-auto}

if [ ! -d "$template_dir" ]; then
  printf 'Missing template directory: %s\n' "$template_dir" >&2
  exit 1
fi

mkdir -p "$profile_dir"

render_template() {
  sed \
    -e "s/__PROFILE__/$profile_name/g" \
    -e "s/__BANK_ID__/$bank_id/g" \
    "$1" > "$2"
}

write_gateway_state() {
  state_file=$1
  gateway_state=$2
  desired_state=$3
  timestamp=$(date +%s 2>/dev/null || printf '0')
  printf '{"gateway_state":"%s","desired_state":"%s","timestamp":%s,"kind":"hermes-gateway"}\n' \
    "$gateway_state" "$desired_state" "$timestamp" > "$state_file"
}

activate_profile() {
  printf '%s\n' "$profile_name" > "$active_profile_file"
  write_gateway_state "$stack_dir/hermes-data/gateway_state.json" stopped stopped
  write_gateway_state "$profile_dir/gateway_state.json" running running
}

if [ -e "$profile_dir/config.yaml" ]; then
  printf 'Keeping existing %s\n' "$profile_dir/config.yaml"
else
  render_template "$template_dir/config.yaml" "$profile_dir/config.yaml"
  printf 'Created %s\n' "$profile_dir/config.yaml"
fi

if [ -e "$profile_dir/SOUL.md" ]; then
  printf 'Keeping existing %s\n' "$profile_dir/SOUL.md"
else
  render_template "$template_dir/SOUL.md" "$profile_dir/SOUL.md"
  printf 'Created %s\n' "$profile_dir/SOUL.md"
fi

if [ -e "$profile_dir/.env.example" ]; then
  printf 'Keeping existing %s\n' "$profile_dir/.env.example"
else
  render_template "$template_dir/.env.example" "$profile_dir/.env.example"
  printf 'Created %s\n' "$profile_dir/.env.example"
fi

if [ -e "$profile_dir/README.md" ]; then
  printf 'Keeping existing %s\n' "$profile_dir/README.md"
else
  render_template "$template_dir/README.md" "$profile_dir/README.md"
  printf 'Created %s\n' "$profile_dir/README.md"
fi

case "$activate_profile" in
  1|true|yes)
    activate_profile
    active_message="set to $profile_name"
    ;;
  0|false|no)
    active_message="unchanged"
    ;;
  auto)
    if [ -s "$active_profile_file" ]; then
      active_message="keeping $(sed -n '1p' "$active_profile_file")"
    else
      activate_profile
      active_message="set to $profile_name"
    fi
    ;;
  *)
    printf 'Invalid HERMES_PROFILE_ACTIVATE value: %s\n' "$activate_profile" >&2
    printf 'Use auto, 1, or 0.\n' >&2
    exit 2
    ;;
esac

printf '\nProfile: %s\n' "$profile_name"
printf 'Template: %s\n' "$template_name"
printf 'Active profile: %s\n' "$active_message"
printf 'Hindsight bank: %s\n' "$bank_id"
printf 'Hindsight MCP URL: %s/%s/\n' "$hindsight_mcp_base" "$bank_id"
printf 'Headroom MCP: %s\n' "$headroom_mcp_description"

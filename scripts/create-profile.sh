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
data_dir=${HERMES_DATA_DIR:-$stack_dir/appdata/hermes}
case "$data_dir" in
  /*) ;;
  *) data_dir="$stack_dir/$data_dir" ;;
esac
template_dir="$stack_dir/hermes-data/profile-templates/$template_name"
profile_dir="$data_dir/profiles/$profile_name"
active_profile_file="$data_dir/active_profile"
appdata_dir=${HERMES_APPDATA_DIR:-$stack_dir/appdata}
case "$appdata_dir" in
  /*) ;;
  *) appdata_dir="$stack_dir/$appdata_dir" ;;
esac
hindsight_mcp_base=${HERMES_HINDSIGHT_MCP_BASE:-http://127.0.0.1:8888/mcp}
headroom_mcp_description=${HERMES_HEADROOM_MCP_DESCRIPTION:-docker-backed stdio server using ghcr.io/chopratejas/headroom:0.27.0}
activate_profile=${HERMES_PROFILE_ACTIVATE:-auto}

if [ ! -d "$template_dir" ]; then
  printf 'Missing template directory: %s\n' "$template_dir" >&2
  exit 1
fi

render_template() {
  sed \
    -e "s/__PROFILE__/$profile_name/g" \
    -e "s/__BANK_ID__/$bank_id/g" \
    -e "s|__APPDATA_DIR__|$appdata_dir|g" \
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
  write_gateway_state "$data_dir/gateway_state.json" stopped stopped
  write_gateway_state "$profile_dir/gateway_state.json" running running
}

create_profile_in_container() {
  container=${HERMES_CONTAINER:-hermes-compose-mcp-hermes-1}
  container_data_dir=${HERMES_CONTAINER_DATA_DIR:-/opt/data}
  container_profile_dir="$container_data_dir/profiles/$profile_name"
  container_active_profile_file="$container_data_dir/active_profile"
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hermes-profile.XXXXXX")
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM

  if ! docker exec "$container" test -d "$container_data_dir" >/dev/null 2>&1; then
    printf 'Cannot write %s from the host, and Hermes container %s is unavailable.\n' "$data_dir" "$container" >&2
    printf 'Start the stack or set HERMES_CONTAINER to the running Hermes container name.\n' >&2
    exit 1
  fi

  docker exec "$container" sh -c '
    owner=$(stat -c "%u:%g" "$2" 2>/dev/null || printf "1000:1000")
    mkdir -p "$1"
    chown "$owner" "$1"
    chmod 775 "$1"
  ' sh "$container_profile_dir" "$container_data_dir/profiles"

  render_template "$template_dir/config.yaml" "$tmp_dir/config.yaml"
  render_template "$template_dir/SOUL.md" "$tmp_dir/SOUL.md"
  render_template "$template_dir/.env.example" "$tmp_dir/.env.example"
  render_template "$template_dir/README.md" "$tmp_dir/README.md"

  copy_if_missing() {
    src=$1
    dest=$2
    if docker exec "$container" test -e "$dest"; then
      printf 'Keeping existing %s\n' "$dest"
    else
      docker exec -i "$container" sh -c 'cat > "$1"' sh "$dest" < "$src"
      printf 'Created %s\n' "$dest"
    fi
    docker exec "$container" sh -c '
      owner=$(stat -c "%u:%g" "$2" 2>/dev/null || printf "1000:1000")
      chown "$owner" "$1"
      chmod 664 "$1"
    ' sh "$dest" "$container_data_dir/profiles"
  }

  copy_if_missing "$tmp_dir/config.yaml" "$container_profile_dir/config.yaml"
  copy_if_missing "$tmp_dir/SOUL.md" "$container_profile_dir/SOUL.md"
  copy_if_missing "$tmp_dir/.env.example" "$container_profile_dir/.env.example"
  copy_if_missing "$tmp_dir/README.md" "$container_profile_dir/README.md"

  activate_profile_in_container() {
    timestamp=$(date +%s 2>/dev/null || printf '0')
    docker exec "$container" sh -c '
      profile=$1
      active_file=$2
      base_state_file=$3
      profile_state_file=$4
      timestamp=$5
      printf "%s\n" "$profile" > "$active_file"
      printf "{\"gateway_state\":\"%s\",\"desired_state\":\"%s\",\"timestamp\":%s,\"kind\":\"hermes-gateway\"}\n" stopped stopped "$timestamp" > "$base_state_file"
      printf "{\"gateway_state\":\"%s\",\"desired_state\":\"%s\",\"timestamp\":%s,\"kind\":\"hermes-gateway\"}\n" running running "$timestamp" > "$profile_state_file"
    ' sh "$profile_name" "$container_active_profile_file" "$container_data_dir/gateway_state.json" "$container_profile_dir/gateway_state.json" "$timestamp"
  }

  case "$activate_profile" in
    1|true|yes)
      activate_profile_in_container
      active_message="set to $profile_name"
      ;;
    0|false|no)
      active_message="unchanged"
      ;;
    auto)
      active_name=$(docker exec "$container" sh -c 'test -s "$1" && sed -n "1p" "$1" || true' sh "$container_active_profile_file")
      if [ "$active_name" != "" ]; then
        active_message="keeping $active_name"
      else
        activate_profile_in_container
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
  exit 0
}

if ! mkdir -p "$profile_dir" 2>/dev/null; then
  create_profile_in_container
fi

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

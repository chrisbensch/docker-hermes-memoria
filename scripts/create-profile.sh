#!/usr/bin/env sh
set -eu

usage() {
  printf 'Usage: %s <profile-name> [hindsight-bank-id]\n' "$0" >&2
  printf 'Example: %s research hermes-research\n' "$0" >&2
  printf 'Default Hindsight bank ID: hermes-<profile-name>\n' >&2
  printf 'Set HERMES_CREATE_HINDSIGHT_BANK=0 to skip bank creation.\n' >&2
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
template_name=${HERMES_PROFILE_TEMPLATE:-rootless}
data_dir=${HERMES_DATA_DIR:-$stack_dir/appdata/hermes}
case "$data_dir" in
  /*) ;;
  *) data_dir="$stack_dir/$data_dir" ;;
esac
template_dir="$stack_dir/hermes-data/profile-templates/$template_name"
profile_override_dir="$stack_dir/hermes-data/profile-overrides/$profile_name"
profile_dir="$data_dir/profiles/$profile_name"
active_profile_file="$data_dir/active_profile"
appdata_dir=${HERMES_APPDATA_DIR:-$stack_dir/appdata}
case "$appdata_dir" in
  /*) ;;
  *) appdata_dir="$stack_dir/$appdata_dir" ;;
esac
obsidian_vault_dir=${HERMES_OBSIDIAN_VAULT_DIR:-$data_dir/obsidian-memory-vault}
case "$obsidian_vault_dir" in
  /*) ;;
  *) obsidian_vault_dir="$stack_dir/$obsidian_vault_dir" ;;
esac
container_obsidian_vault_dir=${HERMES_CONTAINER_OBSIDIAN_VAULT_DIR:-/opt/data/obsidian-memory-vault}
hindsight_mcp_base=${HERMES_HINDSIGHT_MCP_BASE:-http://hindsight-mcp:8888/mcp}
hindsight_api_base=${HERMES_HINDSIGHT_API_BASE:-http://127.0.0.1:8888}
init_hindsight_bank=${HERMES_CREATE_HINDSIGHT_BANK:-1}
require_hindsight_bank=${HERMES_REQUIRE_HINDSIGHT_BANK:-0}
headroom_mcp_description=${HERMES_HEADROOM_MCP_DESCRIPTION:-docker-backed stdio server joined to hermes-compose-mcp-rootless}
activate_profile=${HERMES_PROFILE_ACTIVATE:-auto}

if [ ! -d "$template_dir" ]; then
  printf 'Missing template directory: %s\n' "$template_dir" >&2
  exit 1
fi

soul_template="$template_dir/SOUL.md"
if [ -f "$profile_override_dir/SOUL.md" ]; then
  soul_template="$profile_override_dir/SOUL.md"
fi

render_template() {
  sed \
    -e "s/__PROFILE__/$profile_name/g" \
    -e "s/__BANK_ID__/$bank_id/g" \
    -e "s|__APPDATA_DIR__|$appdata_dir|g" \
    -e "s|__OBSIDIAN_VAULT_PATH__|$container_obsidian_vault_dir|g" \
    "$1" > "$2"
}

write_if_missing() {
  file=$1
  shift
  [ ! -e "$file" ] || return 0
  {
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } > "$file"
}

ensure_obsidian_vault() {
  vault_dir=$1
  profile=$2

  mkdir -p \
    "$vault_dir/Profiles/$profile" \
    "$vault_dir/Shared" \
    "$vault_dir/Templates"

  write_if_missing "$vault_dir/README.md" \
    '# Hermes Obsidian Memory Vault' \
    '' \
    'This vault is shared by Hermes profiles for durable, file-based knowledge.' \
    'Keep profile-specific notes under `Profiles/<profile>/` and shared stack notes under `Shared/`.'

  write_if_missing "$vault_dir/Profiles/$profile/Index.md" \
    '---' \
    "profile: $profile" \
    'kind: profile-index' \
    '---' \
    '' \
    "# $profile Profile Index" \
    '' \
    'Use this note as the entry point for durable profile knowledge, research logs, and links into domain notes.'

  write_if_missing "$vault_dir/Shared/Memory Architecture.md" \
    '# Memory Architecture' \
    '' \
    '- Hermes native memory stores compact profile-local facts.' \
    '- Hindsight stores deeper semantic memory in one bank per profile.' \
    '- This Obsidian vault stores durable notes, indexes, logs, and cross-profile knowledge.' \
    '- Headroom manages context compression and stats, not durable semantic memory.'

  write_if_missing "$vault_dir/Templates/Daily Review.md" \
    '---' \
    'kind: daily-review' \
    '---' \
    '' \
    '# Daily Review' \
    '' \
    '## Highlights' \
    '' \
    '## Follow-ups'
}

ensure_obsidian_vault_in_container() {
  container=$1
  profile=$2

  docker exec "$container" sh -c '
    set -eu
    vault=$1
    profile=$2
    mkdir -p "$vault/Profiles/$profile" "$vault/Shared" "$vault/Templates"
    write_if_missing() {
      file=$1
      shift
      [ ! -e "$file" ] || return 0
      for line in "$@"; do
        printf "%s\n" "$line"
      done > "$file"
    }
    write_if_missing "$vault/README.md" \
      "# Hermes Obsidian Memory Vault" \
      "" \
      "This vault is shared by Hermes profiles for durable, file-based knowledge." \
      "Keep profile-specific notes under \`Profiles/<profile>/\` and shared stack notes under \`Shared/\`."
    write_if_missing "$vault/Profiles/$profile/Index.md" \
      "---" \
      "profile: $profile" \
      "kind: profile-index" \
      "---" \
      "" \
      "# $profile Profile Index" \
      "" \
      "Use this note as the entry point for durable profile knowledge, research logs, and links into domain notes."
    write_if_missing "$vault/Shared/Memory Architecture.md" \
      "# Memory Architecture" \
      "" \
      "- Hermes native memory stores compact profile-local facts." \
      "- Hindsight stores deeper semantic memory in one bank per profile." \
      "- This Obsidian vault stores durable notes, indexes, logs, and cross-profile knowledge." \
      "- Headroom manages context compression and stats, not durable semantic memory."
    write_if_missing "$vault/Templates/Daily Review.md" \
      "---" \
      "kind: daily-review" \
      "---" \
      "" \
      "# Daily Review" \
      "" \
      "## Highlights" \
      "" \
      "## Follow-ups"
  ' sh "$container_obsidian_vault_dir" "$profile"
}

write_gateway_state() {
  state_file=$1
  gateway_state=$2
  desired_state=$3
  timestamp=$(date +%s 2>/dev/null || printf '0')
  printf '{"gateway_state":"%s","desired_state":"%s","timestamp":%s,"kind":"hermes-gateway"}\n' \
    "$gateway_state" "$desired_state" "$timestamp" > "$state_file"
}

init_hindsight_bank() {
  bank_url="$hindsight_api_base/v1/default/banks/$bank_id"
  if ! command -v curl >/dev/null 2>&1; then
    printf 'skipped; curl is not installed'
    return 0
  fi
  if curl -fsS -X PUT "$bank_url" -H "content-type: application/json" -d '{}' >/dev/null 2>&1; then
    printf 'ready'
    return 0
  fi
  if [ "$require_hindsight_bank" = 1 ] || [ "$require_hindsight_bank" = true ] || [ "$require_hindsight_bank" = yes ]; then
    printf 'Could not create Hindsight bank at %s\n' "$bank_url" >&2
    printf 'Start Hindsight or set HERMES_HINDSIGHT_API_BASE to the reachable API URL.\n' >&2
    exit 1
  fi
  printf 'skipped; Hindsight API unavailable at %s' "$hindsight_api_base"
}

print_summary() {
  if [ "$init_hindsight_bank" = 0 ] || [ "$init_hindsight_bank" = false ] || [ "$init_hindsight_bank" = no ]; then
    bank_message="skipped by HERMES_CREATE_HINDSIGHT_BANK=$init_hindsight_bank"
  else
    bank_message=$(init_hindsight_bank)
  fi

  printf '\nProfile: %s\n' "$profile_name"
  printf 'Template: %s\n' "$template_name"
  printf 'Active profile: %s\n' "$active_message"
  printf 'Hindsight bank: %s (%s)\n' "$bank_id" "$bank_message"
  printf 'Hindsight MCP URL: %s/%s/\n' "$hindsight_mcp_base" "$bank_id"
  printf 'Headroom MCP: %s\n' "$headroom_mcp_description"
  printf 'Obsidian profile index: %s/Profiles/%s/Index.md\n' "$obsidian_vault_dir" "$profile_name"
  if printf '%s' "$bank_message" | grep -q '^skipped;'; then
    printf 'Retry bank creation:\n'
    printf '  curl -fsS -X PUT "%s/v1/default/banks/%s" -H "content-type: application/json" -d '\''{}'\''\n' "$hindsight_api_base" "$bank_id"
  fi
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
  render_template "$soul_template" "$tmp_dir/SOUL.md"
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
  ensure_obsidian_vault_in_container "$container" "$profile_name"

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

  print_summary
  exit 0
}

if ! mkdir -p "$profile_dir" 2>/dev/null; then
  create_profile_in_container
fi

ensure_obsidian_vault "$obsidian_vault_dir" "$profile_name"

if [ -e "$profile_dir/config.yaml" ]; then
  printf 'Keeping existing %s\n' "$profile_dir/config.yaml"
else
  render_template "$template_dir/config.yaml" "$profile_dir/config.yaml"
  printf 'Created %s\n' "$profile_dir/config.yaml"
fi

if [ -e "$profile_dir/SOUL.md" ]; then
  printf 'Keeping existing %s\n' "$profile_dir/SOUL.md"
else
  render_template "$soul_template" "$profile_dir/SOUL.md"
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

print_summary

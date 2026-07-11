#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stack_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$stack_dir"

timestamp() {
  date +%Y%m%dT%H%M%S 2>/dev/null || date +%s
}

usage() {
  cat <<'EOF'
Usage: ./scripts/migrate-host-hermes-data.sh [options] [profile ...]

Copy durable data from a host-installed Hermes home into this rootless Compose
layout. When no profiles are listed, every directory under OLD_HERMES_HOME/profiles
is migrated.

Options:
  --dry-run       Print actions without changing files.
  -h, --help      Show this help.

Environment:
  OLD_HERMES_HOME       Source Hermes home. Default: $HOME/.hermes
  OLD_MEMORY_VAULT      Source Obsidian/Memory vault. Default: $HOME/Memory_Vault
  APPDATA_DIR           Compose appdata dir. Default: .env APPDATA_DIR or ./appdata
  HERMES_DATA_DIR       Destination Hermes data dir. Default: APPDATA_DIR/hermes
  MIGRATE_SECRETS       Copy env/auth/token/credential files. Default: 1
  MIGRATE_BULKY_DIRS    Copy workspace/sandboxes/skins directories. Default: 1
  MIGRATE_REWRITE_TEXT  Rewrite obvious host paths/URLs in copied cron/scripts/env files. Default: 1

The script keeps generated rootless config.yaml files live and stores old host
configs as config.host-migration.yaml for reference.
EOF
}

dry_run=0
profiles=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      profiles="${profiles}${profiles:+ }$1"
      ;;
  esac
  shift
done

get_env_value() {
  file=$1
  key=$2
  [ -f "$file" ] || return 1
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); found=1} END {if (!found) exit 1}' "$file" 2>/dev/null
}

env_default() {
  key=$1
  fallback=$2
  value=$(get_env_value "$stack_dir/.env" "$key" || true)
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

old_hermes_home=${OLD_HERMES_HOME:-$HOME/.hermes}
old_memory_vault=${OLD_MEMORY_VAULT:-$HOME/Memory_Vault}
appdata_dir=${APPDATA_DIR:-$(env_default APPDATA_DIR ./appdata)}
case "$appdata_dir" in
  /*) appdata_host_dir=$appdata_dir ;;
  *) appdata_host_dir="$stack_dir/$appdata_dir" ;;
esac
data_dir=${HERMES_DATA_DIR:-$appdata_host_dir/hermes}
case "$data_dir" in
  /*) ;;
  *) data_dir="$stack_dir/$data_dir" ;;
esac

migrate_secrets=${MIGRATE_SECRETS:-1}
migrate_bulky_dirs=${MIGRATE_BULKY_DIRS:-1}
rewrite_text=${MIGRATE_REWRITE_TEXT:-1}
backup_dir="$data_dir/migration-backups/$(timestamp)"
host_archive_dir="$data_dir/host-migration"
vault_dest="$data_dir/obsidian-memory-vault"
hermes_image=${HERMES_IMAGE:-$(env_default HERMES_IMAGE nousresearch/hermes-agent:latest)}
hermes_uid=${HERMES_UID:-$(env_default HERMES_UID 10000)}

run() {
  if [ "$dry_run" = 1 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

say() {
  printf '%s\n' "$*"
}

ensure_dir() {
  dir=$1
  run mkdir -p "$dir"
}

backup_existing() {
  path=$1
  [ -e "$path" ] || [ -L "$path" ] || return 0
  rel=${path#"$data_dir"/}
  if [ "$rel" = "$path" ]; then
    rel=$(basename "$path")
  fi
  ensure_dir "$backup_dir/$(dirname "$rel")"
  run mv "$path" "$backup_dir/$rel"
}

copy_path() {
  copy_src=$1
  copy_dest=$2
  [ -e "$copy_src" ] || [ -L "$copy_src" ] || return 0
  backup_existing "$copy_dest"
  ensure_dir "$(dirname "$copy_dest")"
  say "Copying $copy_src -> $copy_dest"
  run cp -a "$copy_src" "$copy_dest"
}

copy_dir_contents() {
  copy_dir_src=$1
  copy_dir_dest=$2
  [ -d "$copy_dir_src" ] || return 0
  ensure_dir "$copy_dir_dest"
  say "Merging $copy_dir_src/ -> $copy_dir_dest/"
  if command -v rsync >/dev/null 2>&1; then
    if [ "$dry_run" = 1 ]; then
      printf '[dry-run] rsync -a %s/ %s/\n' "$copy_dir_src" "$copy_dir_dest"
    else
      rsync -a "$copy_dir_src/" "$copy_dir_dest/"
    fi
  else
    if [ "$dry_run" = 1 ]; then
      printf '[dry-run] cp -a %s/. %s/\n' "$copy_dir_src" "$copy_dir_dest"
    else
      cp -a "$copy_dir_src/." "$copy_dir_dest/"
    fi
  fi
}

set_env_var() {
  file=$1
  key=$2
  value=$3
  tmp="$file.tmp.$$"
  [ -f "$file" ] || : > "$file"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      done = 1
      next
    }
    { print }
    END {
      if (!done) {
        print key "=" value
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

rewrite_file() {
  file=$1
  [ "$rewrite_text" = 1 ] || return 0
  [ -f "$file" ] || return 0
  tmp="$file.tmp.$$"
  sed \
    -e "s|$old_hermes_home|/opt/data|g" \
    -e "s|$old_memory_vault|/opt/data/obsidian-memory-vault|g" \
    -e 's|/home/hermes/.hermes|/opt/data|g' \
    -e 's|/home/hermes/Memory_Vault|/opt/data/obsidian-memory-vault|g' \
    -e 's|http://10.10.10.41:3002|http://firecrawl-api:3002|g' \
    -e 's|http://10.10.10.41:9377|http://camofox:9377|g' \
    -e 's|http://10.10.10.41:8321/search|http://searxng:80/search|g' \
    "$file" > "$tmp"
  mv "$tmp" "$file"
}

rewrite_tree_text_files() {
  dir=$1
  [ "$rewrite_text" = 1 ] || return 0
  [ -d "$dir" ] || return 0
  find "$dir" -type f \( \
    -name '*.sh' -o \
    -name '*.py' -o \
    -name '*.json' -o \
    -name '*.yaml' -o \
    -name '*.yml' -o \
    -name '*.md' -o \
    -name '.env' \
  \) -print 2>/dev/null | while IFS= read -r file; do
    rewrite_file "$file"
  done
}

profile_list() {
  if [ -n "$profiles" ]; then
    printf '%s\n' $profiles
    return 0
  fi
  if [ ! -d "$old_hermes_home/profiles" ]; then
    printf 'Missing source profiles directory: %s/profiles\n' "$old_hermes_home" >&2
    exit 1
  fi
  find "$old_hermes_home/profiles" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort
}

patch_env_for_rootless_stack() {
  file=$1
  [ -f "$file" ] || return 0
  if [ "$dry_run" = 1 ]; then
    printf '[dry-run] patch rootless env values in %s\n' "$file"
    return 0
  fi
  set_env_var "$file" OBSIDIAN_VAULT_PATH /opt/data/obsidian-memory-vault
  set_env_var "$file" FIRECRAWL_API_URL http://firecrawl-api:3002
  set_env_var "$file" CAMOFOX_URL http://camofox:9377
  set_env_var "$file" SEARXNG_URL http://searxng:80/search
  rewrite_file "$file"
}

prepare_base() {
  ensure_dir "$data_dir"
  ensure_dir "$host_archive_dir"
  ensure_dir "$vault_dest"

  if [ ! -f "$data_dir/config.yaml" ] && [ -f "$stack_dir/hermes-data/config.rootless.yaml" ]; then
    say "Seeding rootless base config at $data_dir/config.yaml"
    run cp "$stack_dir/hermes-data/config.rootless.yaml" "$data_dir/config.yaml"
  fi

  if [ -f "$old_hermes_home/config.yaml" ]; then
    copy_path "$old_hermes_home/config.yaml" "$host_archive_dir/config.host-migration.yaml"
  fi
  if [ -f "$old_hermes_home/SOUL.md" ]; then
    copy_path "$old_hermes_home/SOUL.md" "$host_archive_dir/SOUL.host-migration.md"
  fi
  if [ "$migrate_secrets" = 1 ] && [ -f "$old_hermes_home/.env" ]; then
    copy_path "$old_hermes_home/.env" "$data_dir/.env"
    patch_env_for_rootless_stack "$data_dir/.env"
  elif [ ! -f "$data_dir/.env" ] && [ -f "$stack_dir/hermes-data/.env.example" ]; then
    run cp "$stack_dir/hermes-data/.env.example" "$data_dir/.env"
    patch_env_for_rootless_stack "$data_dir/.env"
  fi

  if [ -d "$old_memory_vault" ]; then
    copy_dir_contents "$old_memory_vault" "$vault_dest"
  else
    say "WARNING: Memory vault not found at $old_memory_vault"
  fi
}

create_profile_shell() {
  profile=$1
  if [ -d "$data_dir/profiles/$profile" ]; then
    return 0
  fi
  say "Creating rootless profile shell: $profile"
  if [ "$dry_run" = 1 ]; then
    printf '[dry-run] HERMES_DATA_DIR=%s HERMES_APPDATA_DIR=%s HERMES_CREATE_HINDSIGHT_BANK=0 HERMES_PROFILE_ACTIVATE=0 ./scripts/create-profile.sh %s\n' "$data_dir" "$appdata_host_dir" "$profile"
  else
    HERMES_DATA_DIR="$data_dir" \
      HERMES_APPDATA_DIR="$appdata_host_dir" \
      HERMES_OBSIDIAN_VAULT_DIR="$vault_dest" \
      HERMES_CREATE_HINDSIGHT_BANK=0 \
      HERMES_PROFILE_ACTIVATE=0 \
      "$stack_dir/scripts/create-profile.sh" "$profile"
  fi
}

copy_profile() {
  profile=$1
  profile_src="$old_hermes_home/profiles/$profile"
  profile_dest="$data_dir/profiles/$profile"

  if [ ! -d "$profile_src" ]; then
    say "WARNING: missing source profile: $profile_src"
    return 0
  fi

  create_profile_shell "$profile"
  ensure_dir "$profile_dest/host-migration"

  say "Migrating profile: $profile"

  copy_path "$profile_src/config.yaml" "$profile_dest/host-migration/config.host-migration.yaml"
  copy_path "$profile_src/SOUL.md" "$profile_dest/SOUL.md"
  copy_path "$profile_src/profile.yaml" "$profile_dest/profile.yaml"
  copy_path "$profile_src/channel_directory.json" "$profile_dest/channel_directory.json"
  copy_path "$profile_src/discord_threads.json" "$profile_dest/discord_threads.json"
  copy_path "$profile_src/honcho.json" "$profile_dest/honcho.json"
  copy_path "$profile_src/provider_model_registry.md" "$profile_dest/provider_model_registry.md"
  copy_path "$profile_src/context_length_cache.yaml" "$profile_dest/context_length_cache.yaml"
  copy_path "$profile_src/processes.json" "$profile_dest/processes.json"

  for db in state.db state.db-shm state.db-wal kanban.db kanban.db-shm kanban.db-wal response_store.db response_store.db-shm response_store.db-wal; do
    copy_path "$profile_src/$db" "$profile_dest/$db"
  done

  for dir in memories sessions cron scripts hooks home plans platforms skills plugins credentials mcp-tokens; do
    copy_dir_contents "$profile_src/$dir" "$profile_dest/$dir"
  done

  if [ "$migrate_bulky_dirs" = 1 ]; then
    for dir in workspace sandboxes skins; do
      copy_dir_contents "$profile_src/$dir" "$profile_dest/$dir"
    done
  fi

  if [ "$migrate_secrets" = 1 ]; then
    for file in .env auth.json google_client_secret.json google_token.json google_oauth_last_url.txt; do
      copy_path "$profile_src/$file" "$profile_dest/$file"
    done
    patch_env_for_rootless_stack "$profile_dest/.env"
  fi

  rewrite_tree_text_files "$profile_dest/cron"
  rewrite_tree_text_files "$profile_dest/scripts"
  rewrite_tree_text_files "$profile_dest/hooks"
  rewrite_tree_text_files "$profile_dest/memories"
  rewrite_file "$profile_dest/SOUL.md"
}

activate_profile() {
  active_file="$old_hermes_home/active_profile"
  [ -f "$active_file" ] || return 0
  active_profile=$(sed -n '1p' "$active_file")
  [ -n "$active_profile" ] || return 0
  say "Setting active profile: $active_profile"
  if [ "$dry_run" = 1 ]; then
    printf '[dry-run] write %s to %s/active_profile\n' "$active_profile" "$data_dir"
    return 0
  fi
  printf '%s\n' "$active_profile" > "$data_dir/active_profile"
  timestamp_value=$(date +%s 2>/dev/null || printf '0')
  printf '{"gateway_state":"stopped","desired_state":"stopped","timestamp":%s,"kind":"hermes-gateway"}\n' "$timestamp_value" > "$data_dir/gateway_state.json"
  if [ -d "$data_dir/profiles/$active_profile" ]; then
    printf '{"gateway_state":"running","desired_state":"running","timestamp":%s,"kind":"hermes-gateway"}\n' "$timestamp_value" > "$data_dir/profiles/$active_profile/gateway_state.json"
  fi
}

normalize_vault_permissions() {
  if [ "$dry_run" = 1 ]; then
    printf '[dry-run] fix Obsidian vault permissions at %s with %s\n' "$vault_dest" "$stack_dir/scripts/fix-obsidian-vault-permissions.sh"
    return 0
  fi

  HERMES_ENV_FILE="$stack_dir/.env" \
  HERMES_DATA_DIR="$data_dir" \
  HERMES_OBSIDIAN_VAULT_DIR="$vault_dest" \
  HERMES_IMAGE="$hermes_image" \
  HERMES_UID="$hermes_uid" \
    "$stack_dir/scripts/fix-obsidian-vault-permissions.sh"
}

cat <<EOF
Hermes host data migration

Source Hermes home: $old_hermes_home
Source Memory Vault: $old_memory_vault
Destination Hermes data: $data_dir
Destination vault: $vault_dest
Dry run: $dry_run
Copy secrets/tokens: $migrate_secrets
Copy bulky dirs: $migrate_bulky_dirs
Rewrite text paths/URLs: $rewrite_text

EOF

prepare_base

profile_list | while IFS= read -r profile; do
  [ -n "$profile" ] || continue
  copy_profile "$profile"
done

activate_profile
normalize_vault_permissions

cat <<EOF

Migration copy complete.

Backups of overwritten destination files, if any:
  $backup_dir

Old host configs were preserved under:
  $host_archive_dir
  $data_dir/profiles/<profile>/host-migration/

Next steps:
  1. Review copied cron jobs under $data_dir/profiles/*/cron.
  2. Review copied profile env/auth/token files before starting the stack.
  3. Run: docker compose --env-file .env config
  4. Run: docker compose --env-file .env up -d
  5. Run: ./scripts/normalize-appdata-permissions.sh
EOF

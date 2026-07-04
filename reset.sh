#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"

usage() {
  cat <<'EOF'
Usage: ./reset.sh [options]

Reset generated Hermes Compose state so ./setup.sh can run from a clean slate.

Options:
  --hard       Delete generated files instead of archiving them.
  --yes        Do not prompt for confirmation.
  --keep-env   Keep .env and hermes-data/.env.
  --no-down    Do not run docker compose down.
  --volumes    Remove Compose-managed Docker volumes too.
  -h, --help   Show this help.

By default, generated files are moved into reset-backups/<timestamp>/.
Tracked templates, seed configs, scripts, and docs are preserved.
EOF
}

timestamp() {
  date +%Y%m%dT%H%M%S 2>/dev/null || date +%s
}

prompt_yes_no() {
  label=$1
  default=$2
  case "$default" in
    y|Y|yes|YES) suffix='Y/n' ;;
    *) suffix='y/N' ;;
  esac
  while :; do
    printf '%s [%s]: ' "$label" "$suffix" >&2
    IFS= read -r value || value=
    [ -n "$value" ] || value=$default
    case "$value" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf 'Please answer yes or no.\n' >&2 ;;
    esac
  done
}

hard=no
assume_yes=no
keep_env=no
run_down=yes
remove_volumes=no

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hard) hard=yes ;;
    --yes) assume_yes=yes ;;
    --keep-env) keep_env=yes ;;
    --no-down) run_down=no ;;
    --volumes) remove_volumes=yes ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

backup_root="$script_dir/reset-backups"
backup_dir="$backup_root/$(timestamp)-$$"

compose_base='docker compose --env-file .env --profile dashboard'
compose_rootful="$compose_base"
compose_rootless="$compose_base -f docker-compose.yml -f docker-compose.rootless.yml"

paths_to_reset='
	hermes-data/.clean_shutdown
	.firecrawl-src
	hermes-data/.cua-driver
hermes-data/.hermes_history
hermes-data/.local
hermes-data/.skills_prompt_snapshot.json
hermes-data/SOUL.md
hermes-data/active_profile
hermes-data/auth.lock
hermes-data/audio_cache
hermes-data/backups
hermes-data/bin
hermes-data/cache
hermes-data/channel_directory.json
hermes-data/config.yaml
hermes-data/config.yaml.bak-*
hermes-data/config.yaml.bak.*
hermes-data/cron
hermes-data/gateway_state.json
hermes-data/home
hermes-data/hooks
hermes-data/image_cache
hermes-data/kanban
hermes-data/kanban.db
hermes-data/kanban.db-shm
hermes-data/kanban.db-wal
hermes-data/kanban.db.dispatch.lock
hermes-data/kanban.db.init.lock
hermes-data/lazy-packages
hermes-data/logs
hermes-data/memories
hermes-data/models_dev_cache.json
hermes-data/ollama_cloud_models_cache.json
hermes-data/pairing
hermes-data/plans
hermes-data/platforms
hermes-data/plugins
hermes-data/profiles
hermes-data/sandboxes
hermes-data/sessions
hermes-data/skills
hermes-data/skins
hermes-data/state.db
hermes-data/state.db-shm
hermes-data/state.db-wal
	hermes-data/workspace
	web-search/searxng-settings.yml
	'

env_paths='
.env
.env.bak-*
hermes-data/.env
hermes-data/.env.bak-*
'

printf '\nHermes Compose reset\n'
printf 'This removes generated runtime state and prepares the repo for ./setup.sh.\n\n'

if [ "$hard" = yes ]; then
  printf 'Mode: delete generated state permanently.\n'
else
  printf 'Mode: archive generated state under %s.\n' "$backup_dir"
fi

if [ "$keep_env" = yes ]; then
  printf 'Environment files: keep .env and hermes-data/.env.\n'
else
  printf 'Environment files: reset .env and hermes-data/.env.\n'
fi

if [ "$run_down" = yes ]; then
  printf 'Compose: stop rootful and rootless project variants before file reset.\n'
else
  printf 'Compose: skip docker compose down.\n'
fi

if [ "$remove_volumes" = yes ]; then
  printf 'Docker volumes: remove Compose-managed Hindsight and Headroom volumes.\n'
else
  printf 'Docker volumes: keep named Docker volumes.\n'
fi

if [ "$assume_yes" != yes ]; then
  printf '\n'
  prompt_yes_no 'Continue with reset' n || {
    printf 'Reset cancelled.\n'
    exit 0
  }
fi

run_compose_down() {
  cmd=$1
  if [ -f .env ]; then
    printf 'Stopping services: %s down --remove-orphans\n' "$cmd"
    sh -c "$cmd down --remove-orphans" || true
  else
    printf 'Skipping compose down because .env does not exist yet.\n'
  fi
}

if [ "$run_down" = yes ]; then
  run_compose_down "$compose_rootless"
  run_compose_down "$compose_rootful"
fi

if [ "$remove_volumes" = yes ]; then
  printf 'Removing Docker volumes: hermes-hindsight-data hermes-headroom-workspace hermes-firecrawl-redis hermes-firecrawl-rabbitmq hermes-firecrawl-postgres\n'
  docker volume rm \
    hermes-hindsight-data \
    hermes-headroom-workspace \
    hermes-firecrawl-redis \
    hermes-firecrawl-rabbitmq \
    hermes-firecrawl-postgres >/dev/null 2>&1 || true
fi

move_or_delete() {
  path=$1
  [ -e "$path" ] || [ -L "$path" ] || return 0

  if [ "$hard" = yes ]; then
    rm -rf -- "$path"
    printf 'Deleted %s\n' "$path"
    return 0
  fi

  dest="$backup_dir/$path"
  mkdir -p "$(dirname "$dest")"
  mv -- "$path" "$dest"
  printf 'Archived %s\n' "$path"
}

if [ "$hard" != yes ]; then
  mkdir -p "$backup_dir"
fi

for path in $paths_to_reset; do
  move_or_delete "$path"
done

if [ "$keep_env" != yes ]; then
  for path in $env_paths; do
    move_or_delete "$path"
  done
fi

mkdir -p hermes-data/profiles

printf '\nReset complete.\n'
if [ "$hard" != yes ]; then
  printf 'Archived state: %s\n' "$backup_dir"
fi
printf 'Next step:\n'
printf '  ./setup.sh\n'

#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"

env_file="$script_dir/.env"
env_example="$script_dir/.env.example"
seed_dir="$script_dir/hermes-data"
hermes_env_example="$seed_dir/.env.example"
data_dir="$script_dir/appdata/hermes"
hermes_env_file="$data_dir/.env"
base_config="$data_dir/config.yaml"

timestamp() {
  date +%Y%m%dT%H%M%S 2>/dev/null || date +%s
}

backup_file() {
  file=$1
  if [ -f "$file" ] && [ ! -f "$file.bak-$(timestamp)" ]; then
    cp "$file" "$file.bak-$(timestamp)"
  fi
}

prompt_default() {
  label=$1
  default=$2
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$label" "$default" >&2
  else
    printf '%s: ' "$label" >&2
  fi
  IFS= read -r value || value=
  if [ -z "$value" ]; then
    printf '%s\n' "$default"
  else
    printf '%s\n' "$value"
  fi
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
    if [ -z "$value" ]; then
      value=$default
    fi
    case "$value" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf 'Please answer yes or no.\n' >&2 ;;
    esac
  done
}

prompt_secret() {
  label=$1
  printf '%s: ' "$label" >&2
  if [ -t 0 ]; then
    stty -echo
    IFS= read -r value || value=
    stty echo
    printf '\n' >&2
  else
    IFS= read -r value || value=
  fi
  printf '%s\n' "$value"
}

get_env_value() {
  file=$1
  key=$2
  [ -f "$file" ] || return 1
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); found=1} END {if (!found) exit 1}' "$file" 2>/dev/null
}

env_default() {
  file=$1
  key=$2
  fallback=$3
  value=$(get_env_value "$file" "$key" || true)
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

env_missing_or_placeholder() {
  file=$1
  key=$2
  value=$(get_env_value "$file" "$key" || true)
  case "$value" in
    ''|CHANGEME|change-me|postgres|sk-your-*|paste-*) return 0 ;;
    *) return 1 ;;
  esac
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

remove_yaml_block() {
  file=$1
  block=$2
  tmp="$file.tmp.$$"
  awk -v block="$block" '
    $0 ~ "^" block ":" {
      skip = 1
      next
    }
    skip && $0 ~ "^[^[:space:]#][^:]*:" {
      skip = 0
    }
    !skip {
      print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

append_model_config() {
  file=$1
  provider=$2
  model=$3
  base_url=$4
  remove_yaml_block "$file" model
  remove_yaml_block "$file" auxiliary
  {
    printf '\nmodel:\n'
    printf '  provider: %s\n' "$provider"
    printf '  default: %s\n' "$model"
    if [ -n "$base_url" ]; then
      printf '  base_url: %s\n' "$base_url"
    fi
    printf '\nauxiliary:\n'
    for slot in \
      vision \
      web_extract \
      compression \
      skills_hub \
      approval \
      mcp \
      title_generation \
      triage_specifier \
      kanban_decomposer \
      profile_describer \
      curator; do
      printf '  %s:\n' "$slot"
      printf '    provider: %s\n' "$provider"
      printf '    model: %s\n' "$model"
    done
  } >> "$file"
}

append_web_config() {
  file=$1
  remove_yaml_block "$file" web
  remove_yaml_block "$file" browser
  {
    printf '\nweb:\n'
    printf '  extract_backend: firecrawl\n'
    printf '  search_backend: firecrawl\n'
    printf '\n'
    printf 'browser:\n'
    printf '  backend: camofox\n'
  } >> "$file"
}

append_dashboard_auth() {
  file=$1
  username=$2
  password_hash=$3
  remove_yaml_block "$file" dashboard
  {
    printf '\ndashboard:\n'
    printf '  basic_auth:\n'
    printf '    username: %s\n' "$username"
    printf '    password_hash: "%s"\n' "$password_hash"
  } >> "$file"
}

validate_profile_name() {
  name=$1
  case "$name" in
    ''|default|hermes|test|tmp|root|sudo|*[!a-z0-9_-]*)
      printf 'Invalid profile name: %s\n' "$name" >&2
      printf 'Use lowercase letters, numbers, underscores, or hyphens; do not use default.\n' >&2
      return 1
      ;;
  esac
}

generate_dashboard_hash() {
  image=$1
  password=$2
  hash=$(docker run --rm --entrypoint python "$image" -c 'import sys; from plugins.dashboard_auth.basic import hash_password; print(hash_password(sys.argv[1]))' "$password")
  case "$hash" in
    scrypt\$*) printf '%s\n' "$hash" ;;
    *)
      printf 'Unexpected dashboard hash output: %s\n' "$hash" >&2
      return 1
      ;;
  esac
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
    printf '\n'
  fi
}

write_searxng_settings() {
  settings_file=$1
  template_file="$script_dir/web-search/searxng-settings.template.yml"

  if [ ! -f "$template_file" ]; then
    printf 'Missing SearXNG settings template: %s\n' "$template_file" >&2
    exit 1
  fi

  if [ ! -f "$settings_file" ] || grep -q 'CHANGE-ME-TO-A-RANDOM-SECRET' "$settings_file"; then
    mkdir -p "$(dirname "$settings_file")"
    secret=$(generate_secret)
    sed "s/CHANGE-ME-TO-A-RANDOM-SECRET/$secret/" "$template_file" > "$settings_file"
    chmod 644 "$settings_file"
    printf 'Generated %s with a fresh SearXNG secret.\n' "$settings_file" >&2
  fi
}

ensure_firecrawl_source() {
  source_dir=$1
  if [ -f "$source_dir/apps/nuq-postgres/Dockerfile" ]; then
    printf 'Using existing Firecrawl source at %s.\n' "$source_dir" >&2
  else
    if ! command -v git >/dev/null 2>&1; then
      printf 'git is required to clone Firecrawl source for nuq-postgres.\n' >&2
      exit 1
    fi
    mkdir -p "$(dirname "$source_dir")"
    printf 'Cloning Firecrawl source into %s for nuq-postgres build...\n' "$source_dir" >&2
    git clone --depth 1 https://github.com/firecrawl/firecrawl.git "$source_dir"
  fi

  chmod a+r "$source_dir/apps/nuq-postgres/Dockerfile" "$source_dir/apps/nuq-postgres/nuq.sql" 2>/dev/null || true
}

prepare_rootless_hindsight_dir() {
  image=$1
  dir=$2

  printf 'Preparing rootless Hindsight data ownership at %s...\n' "$dir" >&2
  docker run --rm \
    --user 0:0 \
    -v "$dir:/mnt" \
    --entrypoint sh \
    "$image" \
    -c 'chown 1000:1000 /mnt && rm -f /mnt/.chown-test' >/dev/null
}

default_lm_base_url() {
  mode=$1
  case "$mode" in
    rootful) printf 'http://127.0.0.1:1234/v1\n' ;;
    *) printf 'http://host.docker.internal:1234/v1\n' ;;
  esac
}

printf '\nHermes Compose setup\n'
printf 'This writes .env files, creates a named profile, and prints the Compose command.\n\n'

default_mode=rootless
if [ ! -S "/run/user/$(id -u)/docker.sock" ] && [ -S /var/run/docker.sock ]; then
  default_mode=rootful
fi

while :; do
  mode=$(prompt_default 'Deployment mode (rootless/rootful)' "$default_mode")
  case "$mode" in
    rootless|rootful) break ;;
    *) printf 'Use rootless or rootful.\n' >&2 ;;
  esac
done

default_appdata_dir=$(env_default "$env_file" APPDATA_DIR ./appdata)
case "$default_appdata_dir" in
  /*) default_appdata_host_dir=$default_appdata_dir ;;
  *) default_appdata_host_dir="$script_dir/$default_appdata_dir" ;;
esac
data_dir="$default_appdata_host_dir/hermes"
default_profile=$(cat "$data_dir/active_profile" 2>/dev/null || printf 'research')
while :; do
  profile_name=$(prompt_default 'Hermes profile name' "$default_profile")
  if validate_profile_name "$profile_name"; then
    break
  fi
done

bank_id=$(prompt_default 'Hindsight bank ID' "hermes-$profile_name")

uid_value=$(prompt_default 'Host UID for appdata ownership' "$(id -u)")
gid_value=$(prompt_default 'Host GID for appdata ownership' "$(id -g)")

case "$mode" in
  rootless)
    socket_default="/run/user/$(id -u)/docker.sock"
    seed_config="$seed_dir/config.rootless.yaml"
    profile_script="$script_dir/scripts/create-profile-rootless.sh"
    ;;
  rootful)
    socket_default=/var/run/docker.sock
    seed_config="$seed_dir/config.rootful.yaml"
    profile_script="$script_dir/scripts/create-profile.sh"
    ;;
esac

docker_socket=$(prompt_default 'Docker socket to mount for Headroom MCP' "$socket_default")
if [ ! -S "$docker_socket" ]; then
  printf 'WARNING: %s is not a socket. Headroom stdio MCP will not work until this points to a real Docker socket.\n' "$docker_socket" >&2
fi

if [ ! -f "$env_file" ]; then
  cp "$env_example" "$env_file"
else
  backup_file "$env_file"
fi

set_env_var "$env_file" HERMES_UID "$uid_value"
set_env_var "$env_file" HERMES_GID "$gid_value"
set_env_var "$env_file" HERMES_HOME_MODE "$(env_default "$env_file" HERMES_HOME_MODE 0755)"
set_env_var "$env_file" DOCKER_SOCK "$docker_socket"
appdata_dir=$(env_default "$env_file" APPDATA_DIR ./appdata)
set_env_var "$env_file" APPDATA_DIR "$appdata_dir"
case "$appdata_dir" in
  /*) appdata_host_dir=$appdata_dir ;;
  *) appdata_host_dir="$script_dir/$appdata_dir" ;;
esac
data_dir="$appdata_host_dir/hermes"
hermes_env_file="$data_dir/.env"
base_config="$data_dir/config.yaml"
mkdir -p \
  "$data_dir" \
  "$appdata_host_dir/hindsight" \
  "$appdata_host_dir/headroom" \
  "$appdata_host_dir/firecrawl-redis" \
  "$appdata_host_dir/firecrawl-rabbitmq" \
  "$appdata_host_dir/firecrawl-postgres"

hindsight_image=$(env_default "$env_file" HINDSIGHT_IMAGE ghcr.io/vectorize-io/hindsight:latest)
set_env_var "$env_file" HINDSIGHT_IMAGE "$hindsight_image"
if [ "$mode" = rootless ]; then
  prepare_rootless_hindsight_dir "$hindsight_image" "$appdata_host_dir/hindsight"
fi

if [ ! -f "$hermes_env_file" ]; then
  cp "$hermes_env_example" "$hermes_env_file"
else
  backup_file "$hermes_env_file"
fi
if [ ! -f "$base_config" ]; then
  cp "$seed_config" "$base_config"
else
  backup_file "$base_config"
fi

firecrawl_source_dir=$(env_default "$env_file" FIRECRAWL_SOURCE_DIR ./.firecrawl-src)
set_env_var "$env_file" FIRECRAWL_IMAGE "$(env_default "$env_file" FIRECRAWL_IMAGE ghcr.io/firecrawl/firecrawl:latest)"
set_env_var "$env_file" FIRECRAWL_PLAYWRIGHT_IMAGE "$(env_default "$env_file" FIRECRAWL_PLAYWRIGHT_IMAGE ghcr.io/firecrawl/playwright-service:latest)"
set_env_var "$env_file" FIRECRAWL_SOURCE_DIR "$firecrawl_source_dir"
set_env_var "$env_file" FIRECRAWL_BIND_HOST "$(env_default "$env_file" FIRECRAWL_BIND_HOST 127.0.0.1)"
set_env_var "$env_file" FIRECRAWL_HOST_PORT "$(env_default "$env_file" FIRECRAWL_HOST_PORT 3002)"
set_env_var "$env_file" FIRECRAWL_USE_DB_AUTHENTICATION "$(env_default "$env_file" FIRECRAWL_USE_DB_AUTHENTICATION false)"
set_env_var "$env_file" FIRECRAWL_POSTGRES_USER "$(env_default "$env_file" FIRECRAWL_POSTGRES_USER postgres)"
set_env_var "$env_file" FIRECRAWL_POSTGRES_DB "$(env_default "$env_file" FIRECRAWL_POSTGRES_DB postgres)"
if env_missing_or_placeholder "$env_file" FIRECRAWL_POSTGRES_PASSWORD; then
  set_env_var "$env_file" FIRECRAWL_POSTGRES_PASSWORD "$(generate_secret)"
fi
if env_missing_or_placeholder "$env_file" FIRECRAWL_BULL_AUTH_KEY; then
  set_env_var "$env_file" FIRECRAWL_BULL_AUTH_KEY "$(generate_secret)"
fi

set_env_var "$env_file" SEARXNG_IMAGE "$(env_default "$env_file" SEARXNG_IMAGE searxng/searxng:latest)"
set_env_var "$env_file" SEARXNG_NGINX_IMAGE "$(env_default "$env_file" SEARXNG_NGINX_IMAGE nginx:alpine)"
set_env_var "$env_file" SEARXNG_SETTINGS_FILE "$(env_default "$env_file" SEARXNG_SETTINGS_FILE ./web-search/searxng-settings.yml)"
set_env_var "$env_file" SEARXNG_BIND_HOST "$(env_default "$env_file" SEARXNG_BIND_HOST 127.0.0.1)"
set_env_var "$env_file" SEARXNG_HOST_PORT "$(env_default "$env_file" SEARXNG_HOST_PORT 8889)"
set_env_var "$env_file" CAMOFOX_IMAGE "$(env_default "$env_file" CAMOFOX_IMAGE ghcr.io/jo-inc/camofox-browser:latest)"
set_env_var "$env_file" CAMOFOX_BIND_HOST "$(env_default "$env_file" CAMOFOX_BIND_HOST 127.0.0.1)"
set_env_var "$env_file" CAMOFOX_HOST_PORT "$(env_default "$env_file" CAMOFOX_HOST_PORT 9377)"

write_searxng_settings "$(env_default "$env_file" SEARXNG_SETTINGS_FILE ./web-search/searxng-settings.yml)"
ensure_firecrawl_source "$firecrawl_source_dir"

hindsight_provider=$(prompt_default 'Hindsight LLM provider (lmstudio/deepseek/openai)' "$(env_default "$env_file" HINDSIGHT_API_LLM_PROVIDER lmstudio)")
case "$hindsight_provider" in
  lmstudio)
    hindsight_model=$(prompt_default 'Hindsight LM Studio model' "$(env_default "$env_file" HINDSIGHT_API_LLM_MODEL your-local-model)")
    hindsight_base=$(prompt_default 'Hindsight LM Studio base URL' "$(env_default "$env_file" HINDSIGHT_API_LLM_BASE_URL "$(default_lm_base_url "$mode")")")
    hindsight_key=$(prompt_default 'Hindsight LM Studio API key (blank is ok)' "$(get_env_value "$env_file" HINDSIGHT_API_LLM_API_KEY || true)")
    ;;
  deepseek)
    hindsight_model=$(prompt_default 'Hindsight DeepSeek model' "$(env_default "$env_file" HINDSIGHT_API_LLM_MODEL deepseek-chat)")
    hindsight_base=$(prompt_default 'Hindsight DeepSeek base URL (blank for provider default)' "$(get_env_value "$env_file" HINDSIGHT_API_LLM_BASE_URL || true)")
    hindsight_key=$(prompt_secret 'Hindsight DeepSeek API key (blank to leave empty)')
    ;;
  openai)
    hindsight_model=$(prompt_default 'Hindsight OpenAI model' "$(env_default "$env_file" HINDSIGHT_API_LLM_MODEL gpt-4o-mini)")
    hindsight_base=$(prompt_default 'Hindsight OpenAI base URL (blank for OpenAI)' "$(get_env_value "$env_file" HINDSIGHT_API_LLM_BASE_URL || true)")
    hindsight_key=$(prompt_secret 'Hindsight OpenAI API key (blank to leave empty)')
    ;;
  *)
    printf 'Unknown Hindsight provider: %s\n' "$hindsight_provider" >&2
    exit 2
    ;;
esac

set_env_var "$env_file" HINDSIGHT_API_LLM_PROVIDER "$hindsight_provider"
set_env_var "$env_file" HINDSIGHT_API_LLM_MODEL "$hindsight_model"
set_env_var "$env_file" HINDSIGHT_API_LLM_BASE_URL "$hindsight_base"
set_env_var "$env_file" HINDSIGHT_API_LLM_API_KEY "$hindsight_key"

if [ "$hindsight_provider" = lmstudio ] && prompt_yes_no 'Point Headroom proxy at the same LM Studio URL' y; then
  set_env_var "$env_file" OPENAI_TARGET_API_URL "$hindsight_base"
fi

dashboard_public=no

if prompt_yes_no 'Expose browser UIs on the LAN' n; then
  dashboard_public=yes
  set_env_var "$env_file" HERMES_DASHBOARD_BIND_HOST 0.0.0.0
  set_env_var "$env_file" HINDSIGHT_UI_BIND_HOST 0.0.0.0
  if prompt_yes_no 'Expose Headroom proxy/stats on the LAN too' n; then
    set_env_var "$env_file" HEADROOM_PROXY_BIND_HOST 0.0.0.0
  else
    set_env_var "$env_file" HEADROOM_PROXY_BIND_HOST 127.0.0.1
  fi
else
  set_env_var "$env_file" HERMES_DASHBOARD_BIND_HOST 127.0.0.1
  set_env_var "$env_file" HINDSIGHT_UI_BIND_HOST 127.0.0.1
  set_env_var "$env_file" HEADROOM_PROXY_BIND_HOST 127.0.0.1
fi

if [ "$dashboard_public" = yes ]; then
  dash_user=$(prompt_default 'Dashboard username' admin)
  while :; do
    dash_password=$(prompt_secret 'Dashboard password')
    [ -n "$dash_password" ] && break
    printf 'Dashboard password cannot be blank for LAN exposure.\n' >&2
  done
  image_name=$(get_env_value "$env_file" HERMES_IMAGE || printf 'nousresearch/hermes-agent:latest')
  printf 'Generating dashboard password hash with %s...\n' "$image_name" >&2
  if dash_hash=$(generate_dashboard_hash "$image_name" "$dash_password" 2>/tmp/hermes-dashboard-hash.err); then
    append_dashboard_auth "$base_config" "$dash_user" "$dash_hash"
  else
    printf 'Could not generate dashboard password hash automatically.\n' >&2
    sed -n '1,80p' /tmp/hermes-dashboard-hash.err >&2 || true
    printf 'Dashboard bind has been reset to 127.0.0.1; run the hash command from QUICKSTART.md before exposing it.\n' >&2
    set_env_var "$env_file" HERMES_DASHBOARD_BIND_HOST 127.0.0.1
    dashboard_public=no
  fi
fi

chmod +x \
  "$script_dir/scripts/create-profile.sh" \
  "$script_dir/scripts/create-profile-rootless.sh" \
  "$script_dir/scripts/normalize-appdata-permissions.sh"
HERMES_DATA_DIR="$data_dir" HERMES_APPDATA_DIR="$appdata_host_dir" HERMES_PROFILE_ACTIVATE=1 "$profile_script" "$profile_name" "$bank_id"

profile_config="$data_dir/profiles/$profile_name/config.yaml"
backup_file "$profile_config"

case "$mode" in
  rootless)
    firecrawl_api_url=http://firecrawl-api:3002
    camofox_url=http://camofox:9377
    ;;
  rootful)
    firecrawl_api_url="http://127.0.0.1:$(env_default "$env_file" FIRECRAWL_HOST_PORT 3002)"
    camofox_url="http://127.0.0.1:$(env_default "$env_file" CAMOFOX_HOST_PORT 9377)"
    ;;
esac

set_env_var "$hermes_env_file" FIRECRAWL_API_URL "$firecrawl_api_url"
set_env_var "$hermes_env_file" CAMOFOX_URL "$camofox_url"

profile_env_file="$data_dir/profiles/$profile_name/.env"
backup_file "$profile_env_file"
set_env_var "$profile_env_file" HINDSIGHT_BANK_ID "$bank_id"
set_env_var "$profile_env_file" FIRECRAWL_API_URL "$firecrawl_api_url"
set_env_var "$profile_env_file" CAMOFOX_URL "$camofox_url"

append_web_config "$profile_config"

if prompt_yes_no 'Configure Hermes Agent runtime model now' y; then
  runtime_provider=$(prompt_default 'Hermes runtime provider (lmstudio/deepseek/openai)' "$hindsight_provider")
  case "$runtime_provider" in
    lmstudio)
      runtime_model=$(prompt_default 'Hermes LM Studio model' "$hindsight_model")
      runtime_base=$(prompt_default 'Hermes LM Studio base URL' "$(default_lm_base_url "$mode")")
      runtime_key=$(prompt_default 'Hermes LM Studio API key (blank is ok)' "$(get_env_value "$hermes_env_file" LM_API_KEY || true)")
      set_env_var "$hermes_env_file" LM_BASE_URL "$runtime_base"
      set_env_var "$hermes_env_file" LM_API_KEY "$runtime_key"
      append_model_config "$profile_config" lmstudio "$runtime_model" "$runtime_base"
      ;;
    deepseek)
      runtime_model=$(prompt_default 'Hermes DeepSeek model' deepseek-chat)
      runtime_base=$(prompt_default 'Hermes DeepSeek base URL' "$(get_env_value "$hermes_env_file" DEEPSEEK_BASE_URL || printf 'https://api.deepseek.com/v1')")
      runtime_key=$(prompt_secret 'Hermes DeepSeek API key (blank to leave empty)')
      set_env_var "$hermes_env_file" DEEPSEEK_BASE_URL "$runtime_base"
      set_env_var "$hermes_env_file" DEEPSEEK_API_KEY "$runtime_key"
      append_model_config "$profile_config" deepseek "$runtime_model" ""
      ;;
    openai)
      runtime_model=$(prompt_default 'Hermes OpenAI model' gpt-4o-mini)
      runtime_key=$(prompt_secret 'Hermes OpenAI API key (blank to leave empty)')
      set_env_var "$hermes_env_file" OPENAI_API_KEY "$runtime_key"
      append_model_config "$profile_config" openai "$runtime_model" ""
      ;;
    *)
      printf 'Unknown Hermes runtime provider: %s\n' "$runtime_provider" >&2
      exit 2
      ;;
  esac
fi

if [ "$mode" = rootless ]; then
  compose_cmd='docker compose --env-file .env'
else
  compose_cmd='docker compose --env-file .env -f docker-compose.yml -f docker-compose.rootful.yml'
fi

server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)
[ -n "$server_ip" ] || server_ip='<server-ip>'
dashboard_bind=$(env_default "$env_file" HERMES_DASHBOARD_BIND_HOST 127.0.0.1)
hindsight_bind=$(env_default "$env_file" HINDSIGHT_UI_BIND_HOST 127.0.0.1)
headroom_bind=$(env_default "$env_file" HEADROOM_PROXY_BIND_HOST 127.0.0.1)
dashboard_host=127.0.0.1
hindsight_host=127.0.0.1
headroom_host=127.0.0.1
[ "$dashboard_bind" = 0.0.0.0 ] && dashboard_host=$server_ip
[ "$hindsight_bind" = 0.0.0.0 ] && hindsight_host=$server_ip
[ "$headroom_bind" = 0.0.0.0 ] && headroom_host=$server_ip

printf '\nSetup files updated.\n\n'
printf 'Validate the Compose file:\n'
printf '  %s config\n\n' "$compose_cmd"
printf 'Bring the stack up:\n'
printf '  %s up -d\n\n' "$compose_cmd"
if [ "$mode" = rootless ]; then
  printf 'Normalize rootless appdata permissions after the containers create their state:\n'
  printf '  ./scripts/normalize-appdata-permissions.sh\n\n'
fi
printf 'Initialize the Hindsight bank after the stack is healthy:\n'
printf '  curl -fsS -X PUT "http://127.0.0.1:8888/v1/default/banks/%s" -H "content-type: application/json" -d '\''{}'\''\n\n' "$bank_id"
printf 'Check the integrated web stack after startup:\n'
printf '  curl -fsS http://127.0.0.1:%s/readyz\n' "$(env_default "$env_file" HEADROOM_PROXY_HOST_PORT 8787)"
printf '  curl -fsS http://127.0.0.1:%s/stats\n' "$(env_default "$env_file" HEADROOM_PROXY_HOST_PORT 8787)"
printf '  curl -fsS http://127.0.0.1:%s/v0/health/liveness\n' "$(env_default "$env_file" FIRECRAWL_HOST_PORT 3002)"
printf '  curl -fsS "http://127.0.0.1:%s/search?q=test&format=json"\n' "$(env_default "$env_file" SEARXNG_HOST_PORT 8889)"
printf '  curl -fsS http://127.0.0.1:%s/health\n\n' "$(env_default "$env_file" CAMOFOX_HOST_PORT 9377)"
printf 'Useful URLs:\n'
printf '  Hermes Dashboard:        http://%s:%s/login?next=%%2F\n' "$dashboard_host" "$(env_default "$env_file" HERMES_DASHBOARD_HOST_PORT 9119)"
printf '  Hindsight Control Plane: http://%s:%s\n' "$hindsight_host" "$(env_default "$env_file" HINDSIGHT_UI_HOST_PORT 9999)"
printf '  Headroom stats:          http://%s:%s/stats\n' "$headroom_host" "$(env_default "$env_file" HEADROOM_PROXY_HOST_PORT 8787)"

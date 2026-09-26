#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$script_dir"

env_file="$script_dir/.env"
mode=self-hosted

usage() {
  cat <<'EOF'
Usage: ./setup.sh --gbrain [--no-embedding]

Initialize the optional shared GBrain Postgres service. The default flow uses
a self-hosted OpenAI-compatible embedding endpoint and verifies a real vector,
including its declared dimension, before database initialization.

Options:
  --no-embedding  Initialize keyless keyword-only retrieval instead.
EOF
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
  printf '%s\n' "${value:-$default}"
}

get_env_value() {
  file=$1
  key=$2
  [ -f "$file" ] || return 1
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); found=1} END {if (!found) exit 1}' "$file"
}

env_default() {
  value=$(get_env_value "$1" "$2" 2>/dev/null || true)
  printf '%s\n' "${value:-$3}"
}

set_env_var() {
  file=$1
  key=$2
  value=$3
  tmp="$file.tmp.$$"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ "^" key "=" { print key "=" value; done = 1; next }
    { print }
    END { if (!done) print key "=" value }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    ./*) printf '%s/%s\n' "$script_dir" "${1#./}" ;;
    *) printf '%s/%s\n' "$script_dir" "$1" ;;
  esac
}

generate_secret_file() {
  destination=$1
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32 > "$destination"
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$destination"
    printf '\n' >> "$destination"
  fi
  chmod 0600 "$destination"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-embedding) mode=none ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown GBrain setup option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for command_name in docker python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Required command is unavailable: %s\n' "$command_name" >&2
    exit 1
  }
done
docker compose version >/dev/null 2>&1 || {
  printf 'The Docker Compose plugin is unavailable.\n' >&2
  exit 1
}

if [ ! -f "$env_file" ]; then
  cp "$script_dir/.env.example" "$env_file"
  chmod 0600 "$env_file"
fi

appdata_setting=$(env_default "$env_file" APPDATA_DIR ./appdata)
appdata_dir=$(resolve_path "$appdata_setting")
gbrain_home="$appdata_dir/gbrain/shared"
if [ -f "$gbrain_home/.gbrain/config.json" ]; then
  printf 'GBrain is already initialized at %s.\n' "$gbrain_home" >&2
  printf 'Refusing to reinitialize it; use the documented embedding migration workflow instead.\n' >&2
  exit 1
fi

postgres_password_setting=$(env_default "$env_file" GBRAIN_POSTGRES_PASSWORD_FILE ./appdata/gbrain/secrets/postgres-password.txt)
admin_token_setting=$(env_default "$env_file" GBRAIN_ADMIN_TOKEN_FILE ./appdata/gbrain/secrets/admin-token.txt)
profile_credentials_setting=$(env_default "$env_file" GBRAIN_PROFILE_CREDENTIALS_DIR ./appdata/gbrain/secrets/profiles)
embedding_key_setting=$(env_default "$env_file" GBRAIN_EMBEDDING_API_KEY_FILE ./appdata/gbrain/secrets/embedding-api-key.txt)

if [ "$mode" = self-hosted ]; then
  printf '\nSelf-hosted GBrain embeddings\n'
  printf 'The endpoint must expose the OpenAI-compatible /v1/embeddings API and be reachable from this host.\n\n'
  embedding_base_url=$(prompt_default 'Embedding base URL (include /v1)' "$(get_env_value "$env_file" GBRAIN_EMBEDDING_BASE_URL 2>/dev/null || true)")
  embedding_model=$(prompt_default 'Embedding model ID' "$(get_env_value "$env_file" GBRAIN_EMBEDDING_MODEL 2>/dev/null || true)")
  embedding_dimensions=$(prompt_default 'Embedding dimensions' "$(env_default "$env_file" GBRAIN_EMBEDDING_DIMENSIONS 1024)")

  [ -n "$embedding_base_url" ] || { printf 'Embedding base URL cannot be blank.\n' >&2; exit 2; }
  [ -n "$embedding_model" ] || { printf 'Embedding model ID cannot be blank.\n' >&2; exit 2; }
  case "$embedding_dimensions" in
    ''|*[!0-9]*|0) printf 'Embedding dimensions must be a positive integer.\n' >&2; exit 2 ;;
  esac

  embedding_key_path=$(resolve_path "$embedding_key_setting")
  if [ ! -e "$embedding_key_path" ]; then
    mkdir -p "$(dirname "$embedding_key_path")"
    umask 077
    : > "$embedding_key_path"
  fi
  [ -f "$embedding_key_path" ] && [ ! -L "$embedding_key_path" ] || {
    printf 'Embedding API key path must be a regular, non-symlink file: %s\n' "$embedding_key_path" >&2
    exit 1
  }
  # Keep the convenient user-facing value in the ignored .env, but continue
  # mounting a dedicated 0600 file so the secret is not passed as a Compose
  # environment value or command-line argument. An explicitly blank value
  # clears the generated file for a keyless endpoint.
  if grep -q '^GBRAIN_EMBEDDING_API_KEY=' "$env_file"; then
    embedding_key_value=$(get_env_value "$env_file" GBRAIN_EMBEDDING_API_KEY)
    umask 077
    printf '%s\n' "$embedding_key_value" > "$embedding_key_path"
    unset embedding_key_value
  fi
  chmod 0600 "$embedding_key_path"

  printf '\nValidating the embedding endpoint before database initialization...\n'
  python3 "$script_dir/scripts/validate-gbrain-embedding-provider.py" \
    --base-url "$embedding_base_url" \
    --model "$embedding_model" \
    --dimensions "$embedding_dimensions" \
    --api-key-file "$embedding_key_path"
else
  embedding_base_url=
  embedding_model=
  embedding_dimensions=
  embedding_key_path=$(resolve_path "$embedding_key_setting")
fi

# No database is touched until the provider validation above has passed.
postgres_password_path=$(resolve_path "$postgres_password_setting")
admin_token_path=$(resolve_path "$admin_token_setting")
profile_credentials_path=$(resolve_path "$profile_credentials_setting")
mkdir -p "$gbrain_home" "$(dirname "$postgres_password_path")" "$profile_credentials_path"
chmod 0700 "$(dirname "$postgres_password_path")" "$profile_credentials_path"
umask 077
[ -f "$postgres_password_path" ] || generate_secret_file "$postgres_password_path"
[ -f "$admin_token_path" ] || generate_secret_file "$admin_token_path"
if [ ! -e "$embedding_key_path" ]; then
  : > "$embedding_key_path"
fi
chmod 0600 "$postgres_password_path" "$admin_token_path" "$embedding_key_path"

set_env_var "$env_file" GBRAIN_POSTGRES_PASSWORD_FILE "$postgres_password_setting"
set_env_var "$env_file" GBRAIN_ADMIN_TOKEN_FILE "$admin_token_setting"
set_env_var "$env_file" GBRAIN_PROFILE_CREDENTIALS_DIR "$profile_credentials_setting"
set_env_var "$env_file" GBRAIN_EMBEDDING_API_KEY_FILE "$embedding_key_setting"
set_env_var "$env_file" GBRAIN_EMBEDDING_BASE_URL "$embedding_base_url"
set_env_var "$env_file" GBRAIN_EMBEDDING_MODEL "$embedding_model"
set_env_var "$env_file" GBRAIN_EMBEDDING_DIMENSIONS "$embedding_dimensions"

docker compose --env-file "$env_file" --profile gbrain config --quiet
docker compose --env-file "$env_file" --profile gbrain up -d gbrain-postgres

if [ "$mode" = self-hosted ]; then
  docker compose --env-file "$env_file" --profile gbrain run --rm gbrain \
    init --non-interactive \
    --embedding-model "openai:$embedding_model" \
    --embedding-dimensions "$embedding_dimensions"
else
  docker compose --env-file "$env_file" --profile gbrain run --rm gbrain \
    init --non-interactive --no-embedding
fi

docker compose --env-file "$env_file" --profile gbrain run --rm gbrain doctor --json
printf '\nGBrain initialized. Start it with:\n'
printf '  docker compose --env-file .env --profile gbrain up -d --build gbrain-postgres gbrain\n'

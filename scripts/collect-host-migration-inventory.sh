#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stack_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

timestamp() {
  date +%Y%m%dT%H%M%S 2>/dev/null || date +%s
}

output_file=${1:-${MIGRATION_INVENTORY_OUTPUT:-/tmp/host-migration-$(timestamp).md}}
hermes_home=${HERMES_HOST_HOME:-$HOME/.hermes}
memory_vault=${HERMES_MEMORY_VAULT:-$HOME/hermes/Memory_Vault}
compose_search_roots=${COMPOSE_SEARCH_ROOTS:-"$HOME/hermes $HOME/.hermes $PWD"}

mkdir -p "$(dirname "$output_file")"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

section() {
  printf '\n## %s\n\n' "$1" >> "$output_file"
}

run_block() {
  title=$1
  shift
  printf '### %s\n\n' "$title" >> "$output_file"
  printf '```text\n' >> "$output_file"
  "$@" >> "$output_file" 2>&1 || printf '[command failed: %s]\n' "$*" >> "$output_file"
  printf '```\n\n' >> "$output_file"
}

redact_stream() {
  sed -E '
    s/([A-Za-z0-9_]*(API_KEY|TOKEN|SECRET|PASSWORD|PASS|AUTH|CREDENTIAL|COOKIE|SESSION|PRIVATE_KEY)[A-Za-z0-9_]*[[:space:]]*[:=][[:space:]]*).*/\1REDACTED/I
    s#(Bearer )[A-Za-z0-9._~+/=-]+#\1REDACTED#g
    s#(sk-[A-Za-z0-9_-]{8})[A-Za-z0-9_-]+#\1...REDACTED#g
  '
}

print_sanitized_file() {
  file=$1
  label=$2
  printf '### %s\n\n' "$label" >> "$output_file"
  if [ -f "$file" ]; then
    printf 'Path: `%s`\n\n' "$file" >> "$output_file"
    printf '```text\n' >> "$output_file"
    redact_stream < "$file" >> "$output_file"
    printf '```\n\n' >> "$output_file"
  else
    printf 'Not found: `%s`\n\n' "$file" >> "$output_file"
  fi
}

find_dirs() {
  dir=$1
  depth=$2
  if [ -d "$dir" ]; then
    find "$dir" -maxdepth "$depth" -type d -print 2>/dev/null | sort
  else
    printf 'Not found: %s\n' "$dir"
  fi
}

find_files() {
  dir=$1
  depth=$2
  limit=$3
  if [ -d "$dir" ]; then
    find "$dir" -maxdepth "$depth" -type f -print 2>/dev/null | sort | sed -n "1,${limit}p"
  else
    printf 'Not found: %s\n' "$dir"
  fi
}

find_compose_files() {
  for root in $compose_search_roots; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 4 -type f \( \
      -name 'compose.yml' -o \
      -name 'compose.yaml' -o \
      -name 'docker-compose.yml' -o \
      -name 'docker-compose.yaml' \
    \) -print 2>/dev/null
  done | sort -u
}

copy_compose_files() {
  files=$(find_compose_files || true)
  if [ -z "$files" ]; then
    printf 'No compose files found under: %s\n' "$compose_search_roots"
    return 0
  fi

  printf '%s\n' "$files" | while IFS= read -r file; do
    printf '\n--- %s ---\n' "$file"
    redact_stream < "$file"
  done
}

: > "$output_file"

cat >> "$output_file" <<EOF
# Hermes Host Migration Inventory

Generated: $(date -Is 2>/dev/null || date)
Host: $(hostname 2>/dev/null || printf unknown)
User: $(id -un 2>/dev/null || printf unknown)

This report is meant for planning a migration from a host-installed Hermes Agent
to the rootless Compose stack. Sensitive-looking values are redacted by pattern,
but you should still review the file before sharing it.

Configured paths:

- Hermes host home: \`$hermes_home\`
- Memory Vault: \`$memory_vault\`
- Compose search roots: \`$compose_search_roots\`

EOF

section "Host"
run_block "OS Release" sh -c 'cat /etc/os-release 2>/dev/null || uname -a'
run_block "Kernel And User" sh -c 'uname -a; id; printf "HOME=%s\nPWD=%s\n" "$HOME" "$PWD"'
run_block "Disk Usage Summary" sh -c 'df -h "$HOME" . 2>/dev/null || df -h'

section "Docker"
if command_exists docker; then
  run_block "Docker Contexts" docker context ls
  run_block "Docker Info First 120 Lines" sh -c 'docker info 2>&1 | sed -n "1,120p"'
  run_block "Running Containers" docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  run_block "Docker Compose Version" docker compose version
else
  printf 'Docker command not found.\n\n' >> "$output_file"
fi

section "Hermes Host Install"
run_block "Hermes Executables" sh -c 'command -v hermes || true; command -v hermes-agent || true; command -v agent || true'
run_block "Hermes Home Directories" find_dirs "$hermes_home" 3
run_block "Hermes Home Files" find_files "$hermes_home" 2 300
run_block "Hermes Profile Files" sh -c 'if [ -d "$1/profiles" ]; then find "$1/profiles" -maxdepth 3 -type f -print 2>/dev/null | sort | sed -n "1,400p"; else printf "Not found: %s/profiles\n" "$1"; fi' sh "$hermes_home"
print_sanitized_file "$hermes_home/config.yaml" "Sanitized Hermes Config"
print_sanitized_file "$hermes_home/.env" "Sanitized Hermes Runtime Env"
print_sanitized_file "$hermes_home/active_profile" "Active Profile"

section "Obsidian And Memory Vault"
run_block "Likely Obsidian Vault Directories Under Hermes Home" sh -c 'if [ -d "$1" ]; then find "$1" -maxdepth 4 -type d \( -iname "*obsidian*" -o -iname "*vault*" \) -print 2>/dev/null | sort; else printf "Not found: %s\n" "$1"; fi' sh "$hermes_home"
run_block "Memory Vault Directories" find_dirs "$memory_vault" 3
run_block "Memory Vault Files First 300" find_files "$memory_vault" 3 300
run_block "Memory Vault Size" sh -c 'du -sh "$1" 2>/dev/null || printf "Not found: %s\n" "$1"' sh "$memory_vault"

section "Existing Compose Sidecars"
run_block "Discovered Compose Files Sanitized" copy_compose_files
if command_exists docker; then
  run_block "Likely Hindsight Containers" sh -c 'docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | awk "NR==1 || /hindsight|headroom|searx|firecrawl|camofox/i"'
  run_block "Likely Hindsight Volumes" sh -c 'docker volume ls --format "{{.Name}}" | awk "/hindsight|headroom|hermes|memory/i"'
  run_block "Likely Sidecar Networks" sh -c 'docker network ls --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}" | awk "NR==1 || /hindsight|headroom|hermes|memory/i"'
fi

section "New Rootless Stack Context"
run_block "Current Repo Status" sh -c 'cd "$1" && git status --short 2>/dev/null || true' sh "$stack_dir"
run_block "Current Rootless Compose Config Check" sh -c 'cd "$1" && if [ -f .env ]; then docker compose --env-file .env config >/dev/null && printf "compose config: ok\n"; else printf ".env not present; skipped compose config\n"; fi' sh "$stack_dir"

cat >> "$output_file" <<EOF
## Notes For Review

- Review this file for secrets before sharing.
- If compose files were missed, rerun with:

\`\`\`bash
COMPOSE_SEARCH_ROOTS="/path/one /path/two" ./scripts/collect-host-migration-inventory.sh
\`\`\`

- If Hermes or the Memory Vault live elsewhere, rerun with:

\`\`\`bash
HERMES_HOST_HOME=/path/to/.hermes \\
HERMES_MEMORY_VAULT=/path/to/Memory_Vault \\
./scripts/collect-host-migration-inventory.sh
\`\`\`
EOF

printf 'Wrote migration inventory: %s\n' "$output_file"

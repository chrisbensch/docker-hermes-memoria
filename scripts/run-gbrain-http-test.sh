#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
env_file=${GBRAIN_HTTP_TEST_ENV_FILE:-"$repo_root/.env"}
test_profile=http-test

usage() {
  cat <<'EOF'
Usage: scripts/run-gbrain-http-test.sh <init|start|verify|stop>

Run Phase 1's disposable GBrain HTTP/OAuth surface test. It uses only the
tracked synthetic corpus and appdata/gbrain/home/http-test. It does not mount
the live vault, configure Hermes, create an OAuth client, or contact a model
provider.

  init    Create an isolated PGLite brain, force conservative mode, and import
          the synthetic corpus with --no-embed.
  start   Start the HTTP test service on host loopback only.
  verify  Check OAuth discovery, unauthenticated MCP rejection, and port scope.
  stop    Stop only the HTTP test service; keep its disposable state for review.
EOF
}

action=${1:-}
[[ $# == 1 ]] || { usage >&2; exit 2; }
case "$action" in
  init|start|verify|stop) ;;
  -h|--help) usage; exit 0 ;;
  *) printf 'Unsupported Phase 1 action: %s\n' "$action" >&2; usage >&2; exit 2 ;;
esac
[[ -f $env_file ]] || { printf 'Missing %s; create it from .env.example first.\n' "$env_file" >&2; exit 1; }

appdata_value=$(awk -F= '$1 == "APPDATA_DIR" {value = substr($0, length($1) + 2)} END {print value}' "$env_file")
appdata_value=${appdata_value:-./appdata}
if [[ $appdata_value == /* ]]; then
  appdata_dir=$appdata_value
else
  appdata_dir="$repo_root/$appdata_value"
fi
pilot_dir="$appdata_dir/gbrain"
home_dir="$pilot_dir/home/$test_profile"
port=$(awk -F= '$1 == "GBRAIN_HTTP_TEST_HOST_PORT" {value = substr($0, length($1) + 2)} END {print value}' "$env_file")
port=${port:-3131}
[[ $port =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) || {
  printf 'GBRAIN_HTTP_TEST_HOST_PORT must be an unprivileged TCP port.\n' >&2
  exit 2
}

compose=(docker compose --env-file "$env_file" --profile gbrain-pilot --profile gbrain-http-test)
run_gbrain() {
  "${compose[@]}" run --rm -e "GBRAIN_HOME=/var/lib/gbrain/home/$test_profile" gbrain-pilot "$@"
}

recover_stale_serve_lock() {
  local lock_dir backup_dir stale_dir timestamp running_id
  lock_dir="$home_dir/.gbrain/brain.pglite/.gbrain-lock"
  [[ -d $lock_dir ]] || return 0
  running_id=$("${compose[@]}" ps --status running -q gbrain-http-test)
  if [[ -n $running_id ]]; then
    printf 'Refusing to recover a PGLite lock while gbrain-http-test is running.\n' >&2
    exit 1
  fi
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup_dir="${lock_dir}.before-recovery-$timestamp"
  stale_dir="${lock_dir}.stale-$timestamp"
  cp -a "$lock_dir" "$backup_dir"
  cmp "$lock_dir/lock" "$backup_dir/lock"
  mv "$lock_dir" "$stale_dir"
  printf 'Archived verified stale PGLite lock: %s\n' "$stale_dir"
}

case "$action" in
  init)
    [[ ! -e $home_dir ]] || {
      printf 'Refusing to reuse existing Phase 1 state: %s\n' "$home_dir" >&2
      printf 'Review it first; choose a fresh appdata directory for another run.\n' >&2
      exit 1
    }
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    corpus_dir="$pilot_dir/staging/$test_profile/synthetic-$timestamp"
    mkdir -p "$home_dir" "$corpus_dir"
    cp -R "$repo_root/gbrain/http-test-corpus/." "$corpus_dir/"
    run_gbrain init --pglite --no-embedding
    run_gbrain config set search.mode conservative
    run_gbrain import "/staging/$test_profile/synthetic-$timestamp" --no-embed
    run_gbrain doctor --json
    printf 'Phase 1 synthetic brain initialized: %s\n' "$home_dir"
    ;;
  start)
    [[ -d $home_dir ]] || {
      printf 'Missing Phase 1 state: run %s init first.\n' "$0" >&2
      exit 1
    }
    recover_stale_serve_lock
    "${compose[@]}" up -d --build gbrain-http-test
    "${compose[@]}" ps gbrain-http-test
    ;;
  verify)
    response_file=$(mktemp)
    trap 'rm -f "$response_file"' EXIT
    discovery="http://127.0.0.1:$port/.well-known/oauth-authorization-server"
    mcp_endpoint="http://127.0.0.1:$port/mcp"
    ready=false
    for _attempt in {1..20}; do
      if curl --fail --silent --max-time 2 "$discovery" > "$response_file"; then
        ready=true
        break
      fi
      sleep 1
    done
    if ! $ready; then
      printf 'OAuth discovery did not become ready within 20 seconds.\n' >&2
      "${compose[@]}" logs --tail=100 gbrain-http-test >&2 || true
      exit 1
    fi
    grep -Fq 'authorization_endpoint' "$response_file" || {
      printf 'OAuth discovery response lacks authorization_endpoint.\n' >&2
      exit 1
    }
    status=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
      --max-time 10 --request POST "$mcp_endpoint" \
      --header 'Content-Type: application/json' \
      --header 'Accept: application/json, text/event-stream' \
      --data '{"jsonrpc":"2.0","id":"phase1","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"phase1-verifier","version":"1"}}}')
    case "$status" in
      401|403) ;;
      *)
        printf 'Unauthenticated MCP initialize was not rejected (HTTP %s).\n' "$status" >&2
        exit 1
        ;;
    esac
    container_id=$("${compose[@]}" ps -q gbrain-http-test)
    [[ -n $container_id ]] || { printf 'HTTP test service is not running.\n' >&2; exit 1; }
    published=$(docker port "$container_id" 3131)
    [[ $published == 127.0.0.1:* ]] || {
      printf 'HTTP test port is not loopback-only: %s\n' "$published" >&2
      exit 1
    }
    printf 'Phase 1 verification passed: discovery works, unauthenticated MCP is denied, port=%s\n' "$published"
    ;;
  stop)
    "${compose[@]}" stop gbrain-http-test
    [[ ! -e $home_dir/.gbrain/brain.pglite/.gbrain-lock ]] || {
      printf 'PGLite serve lock remains after a graceful HTTP stop: %s\n' "$home_dir/.gbrain/brain.pglite/.gbrain-lock" >&2
      printf 'The lock was retained for diagnosis; do not restart until it is reviewed.\n' >&2
      exit 1
    }
    printf 'Phase 1 HTTP stop passed: PGLite serve lock released.\n'
    ;;
esac

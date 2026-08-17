#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
env_file=${GBRAIN_HTTP_TEST_ENV_FILE:-"$repo_root/.env"}

usage() {
  cat <<'EOF'
Usage: scripts/run-gbrain-allowlist-test.sh <start|verify|stop>

Exercise Phase 3's synthetic MCP allowlist proxy. It exposes only `search` to
an unauthenticated local caller; it holds the upstream OAuth read credentials
itself. It does not mount the live vault or alter Hermes configuration.

  start   Start the synthetic GBrain HTTP test, then the loopback-only proxy.
  verify  Assert discovery filtering, allowed search, and local write denial.
  stop    Stop the proxy and synthetic GBrain HTTP test.
EOF
}

action=${1:-}
[[ $# == 1 ]] || { usage >&2; exit 2; }
case "$action" in
  start|verify|stop) ;;
  -h|--help) usage; exit 0 ;;
  *) printf 'Unsupported Phase 3 action: %s\n' "$action" >&2; usage >&2; exit 2 ;;
esac
[[ -f $env_file ]] || { printf 'Missing %s; create it from .env.example first.\n' "$env_file" >&2; exit 1; }

appdata_value=$(awk -F= '$1 == "APPDATA_DIR" {value = substr($0, length($1) + 2)} END {print value}' "$env_file")
appdata_value=${appdata_value:-./appdata}
if [[ $appdata_value == /* ]]; then
  appdata_dir=$appdata_value
else
  appdata_dir="$repo_root/$appdata_value"
fi
credentials_file="$appdata_dir/gbrain/secrets/http-test-read-verifier-phase2.env"
port=$(awk -F= '$1 == "GBRAIN_ALLOWLIST_TEST_HOST_PORT" {value = substr($0, length($1) + 2)} END {print value}' "$env_file")
port=${port:-3132}
[[ $port =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) || {
  printf 'GBRAIN_ALLOWLIST_TEST_HOST_PORT must be an unprivileged TCP port.\n' >&2
  exit 2
}

compose=(docker compose --env-file "$env_file" --profile gbrain-pilot --profile gbrain-http-test --profile gbrain-proxy-test)

ensure_http_test_ready() {
  local running_id
  running_id=$("${compose[@]}" ps --status running -q gbrain-http-test)
  if [[ -n $running_id ]]; then
    printf 'Reusing running gbrain-http-test after Phase 1 verification.\n'
  else
    GBRAIN_HTTP_TEST_ENV_FILE=$env_file "$script_dir/run-gbrain-http-test.sh" start
  fi
  GBRAIN_HTTP_TEST_ENV_FILE=$env_file "$script_dir/run-gbrain-http-test.sh" verify
}

case "$action" in
  start)
    [[ -f $credentials_file ]] || {
      printf 'Phase 3 requires the confidential Phase 2 client file: %s\n' "$credentials_file" >&2
      exit 1
    }
    [[ $(stat -c '%U:%a' "$credentials_file") == "$(id -un):600" ]] || {
      printf 'Phase 2 credentials must be owned by %s and mode 0600.\n' "$(id -un)" >&2
      exit 1
    }
    ensure_http_test_ready
    # The HTTP service is already running above. Do not let this proxy build
    # recreate it: PGLite permits only one process to own its serve lock.
    "${compose[@]}" up -d --no-deps --build gbrain-mcp-allowlist-test
    "${compose[@]}" ps gbrain-http-test gbrain-mcp-allowlist-test
    ;;
  verify)
    response_file=$(mktemp)
    trap 'rm -f "$response_file"' EXIT
    endpoint="http://127.0.0.1:$port/mcp"
    ready=false
    for _attempt in {1..20}; do
      status=$(curl --silent --output "$response_file" --write-out '%{http_code}' --max-time 2 \
        --request POST "$endpoint" --header 'Content-Type: application/json' \
        --header 'Accept: application/json, text/event-stream' \
        --data '{"jsonrpc":"2.0","id":"phase3-init","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"phase3-proxy-verifier","version":"1"}}}' || true)
      if [[ $status == 200 ]] && grep -Fq '"serverInfo"' "$response_file"; then
        ready=true
        break
      fi
      sleep 1
    done
    $ready || { printf 'Phase 3 proxy did not become ready within 20 seconds.\n' >&2; exit 1; }
    proxy_id=$("${compose[@]}" ps -q gbrain-mcp-allowlist-test)
    [[ -n $proxy_id ]] || { printf 'Phase 3 proxy is not running.\n' >&2; exit 1; }
    published=$(docker port "$proxy_id" 3132)
    [[ $published == 127.0.0.1:* ]] || { printf 'Proxy port is not loopback-only: %s\n' "$published" >&2; exit 1; }
    curl --fail --silent --show-error --max-time 10 --request POST "$endpoint" \
      --header 'Content-Type: application/json' --header 'Accept: application/json, text/event-stream' \
      --data '{"jsonrpc":"2.0","id":"phase3-tools","method":"tools/list","params":{}}' > "$response_file"
    grep -Fq '"name":"search"' "$response_file" || { printf 'Proxy did not advertise search.\n' >&2; exit 1; }
    ! grep -Fq '"name":"put_page"' "$response_file" || { printf 'Proxy advertised blocked put_page.\n' >&2; exit 1; }
    curl --fail --silent --show-error --max-time 10 --request POST "$endpoint" \
      --header 'Content-Type: application/json' --header 'Accept: application/json, text/event-stream' \
      --data '{"jsonrpc":"2.0","id":"phase3-search","method":"tools/call","params":{"name":"search","arguments":{"query":"read-only MCP decision"}}}' > "$response_file"
    grep -Fq 'Synthetic Read-Only MCP Decision' "$response_file" || { printf 'Proxy search did not return synthetic content.\n' >&2; exit 1; }
    curl --fail --silent --show-error --max-time 10 --request POST "$endpoint" \
      --header 'Content-Type: application/json' --header 'Accept: application/json, text/event-stream' \
      --data '{"jsonrpc":"2.0","id":"phase3-write","method":"tools/call","params":{"name":"put_page","arguments":{"title":"Denied proxy write","body":"This must not be stored."}}}' > "$response_file"
    grep -Fq 'not permitted by the retrieval proxy' "$response_file" || { printf 'Proxy did not locally deny put_page.\n' >&2; exit 1; }
    printf 'Phase 3 verification passed: loopback proxy advertises only search and locally denies put_page.\n'
    ;;
  stop)
    "${compose[@]}" stop gbrain-mcp-allowlist-test
    GBRAIN_HTTP_TEST_ENV_FILE=$env_file "$script_dir/run-gbrain-http-test.sh" stop
    ;;
esac

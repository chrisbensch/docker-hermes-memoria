#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
env_file=${GBRAIN_HTTP_TEST_ENV_FILE:-"$repo_root/.env"}

usage() {
  cat <<'EOF'
Usage: scripts/verify-gbrain-http-read-client.sh [--credentials FILE]

Verify Phase 2's server-side OAuth read scope against the running synthetic
GBrain HTTP test. The credentials file must contain GBRAIN_OAUTH_CLIENT_ID and
GBRAIN_OAUTH_CLIENT_SECRET, be owned by the current user, and have mode 0600.

This writes only synthetic request/response evidence below appdata/gbrain/
reports/http-test/. It never prints or saves the access token or client secret.
Start the test service first with scripts/run-gbrain-http-test.sh start, and
stop it afterward with scripts/run-gbrain-http-test.sh stop.
EOF
}

credentials_file=
while (($#)); do
  case "$1" in
    --credentials)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      credentials_file=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unsupported argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -f $env_file ]] || { printf 'Missing %s; create it from .env.example first.\n' "$env_file" >&2; exit 1; }
appdata_value=$(awk -F= '$1 == "APPDATA_DIR" {value = substr($0, length($1) + 2)} END {print value}' "$env_file")
appdata_value=${appdata_value:-./appdata}
if [[ $appdata_value == /* ]]; then
  appdata_dir=$appdata_value
else
  appdata_dir="$repo_root/$appdata_value"
fi
credentials_file=${credentials_file:-"$appdata_dir/gbrain/secrets/http-test-read-verifier-phase2.env"}
[[ -f $credentials_file ]] || { printf 'Missing read-client credentials: %s\n' "$credentials_file" >&2; exit 1; }
[[ $(stat -c '%U:%a' "$credentials_file") == "$(id -un):600" ]] || {
  printf 'Read-client credentials must be owned by %s and mode 0600: %s\n' "$(id -un)" "$credentials_file" >&2
  exit 1
}

client_id=$(awk -F= '$1 == "GBRAIN_OAUTH_CLIENT_ID" {print substr($0, length($1) + 2); exit}' "$credentials_file")
client_secret=$(awk -F= '$1 == "GBRAIN_OAUTH_CLIENT_SECRET" {print substr($0, length($1) + 2); exit}' "$credentials_file")
[[ -n $client_id && -n $client_secret ]] || { printf 'Credentials file lacks required client values.\n' >&2; exit 1; }

GBRAIN_HTTP_TEST_ENV_FILE=$env_file "$script_dir/run-gbrain-http-test.sh" verify

port=$(awk -F= '$1 == "GBRAIN_HTTP_TEST_HOST_PORT" {value = substr($0, length($1) + 2)} END {print value}' "$env_file")
port=${port:-3131}
base_url="http://127.0.0.1:$port"
discovery_file=$(mktemp)
token_file=$(mktemp)
trap 'rm -f "$discovery_file" "$token_file"' EXIT
curl --fail --silent --show-error --max-time 10 "$base_url/.well-known/oauth-authorization-server" > "$discovery_file"
token_endpoint=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["token_endpoint"])' "$discovery_file")
curl --fail --silent --show-error --max-time 10 --request POST "$token_endpoint" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode "client_id=$client_id" \
  --data-urlencode "client_secret=$client_secret" > "$token_file"
access_token=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["access_token"])' "$token_file")
[[ -n $access_token ]] || { printf 'OAuth token response did not contain an access token.\n' >&2; exit 1; }

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
report_dir="$appdata_dir/gbrain/reports/http-test/phase2-scope-$timestamp"
mkdir -p "$report_dir"
printf '%s\n' 'Synthetic Phase 2 evidence; no credentials or access tokens are recorded.' > "$report_dir/README.txt"

mcp_post() {
  local name=$1 payload=$2 status
  status=$(curl --silent --show-error --output "$report_dir/$name.sse" \
    --write-out '%{http_code}' --max-time 10 --request POST "$base_url/mcp" \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json, text/event-stream' \
    --header "Authorization: Bearer $access_token" \
    --data "$payload")
  printf '%s\n' "$status" > "$report_dir/$name.status"
  [[ $status == 200 ]] || { printf '%s returned HTTP %s.\n' "$name" "$status" >&2; exit 1; }
}

mcp_post initialize '{"jsonrpc":"2.0","id":"phase2-init","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"phase2-read-scope-verifier","version":"1"}}}'
mcp_post search '{"jsonrpc":"2.0","id":"phase2-search","method":"tools/call","params":{"name":"search","arguments":{"query":"read-only MCP decision"}}}'
mcp_post write '{"jsonrpc":"2.0","id":"phase2-write","method":"tools/call","params":{"name":"put_page","arguments":{"title":"Denied write proof","body":"This must not be stored.","slug":"denied-write-proof"}}}'
mcp_post tools '{"jsonrpc":"2.0","id":"phase2-tools","method":"tools/list","params":{}}'

grep -Fq 'Synthetic Read-Only MCP Decision' "$report_dir/search.sse" || {
  printf 'Read-scope search did not return the synthetic corpus result.\n' >&2
  exit 1
}
grep -Fq '"isError":true' "$report_dir/write.sse" && \
  grep -Fq "requires 'write' scope" "$report_dir/write.sse" || {
  printf 'Read-scope token was not denied the put_page write operation.\n' >&2
  exit 1
}

if grep -Fq '"name":"put_page"' "$report_dir/tools.sse"; then
  printf '%s\n' 'Phase 2 scope verification passed: search works and put_page requires write scope.'
  printf '%s\n' 'Limitation recorded: tools/list still advertises put_page; use an MCP allowlist proxy before Hermes integration.'
else
  printf '%s\n' 'Phase 2 scope verification passed: search works and put_page requires write scope.'
  printf '%s\n' 'tools/list did not advertise put_page; review the evidence before changing the promotion gates.'
fi
printf 'Evidence: %s\n' "$report_dir"

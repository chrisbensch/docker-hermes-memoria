#!/usr/bin/env bash
set -euo pipefail

for script in \
  scripts/prepare-gbrain-pilot-corpus.sh \
  scripts/run-gbrain-pilot.sh \
  scripts/run-gbrain-http-test.sh \
  scripts/verify-gbrain-http-read-client.sh \
  scripts/run-gbrain-allowlist-test.sh; do
  bash -n "$script"
done

grep -Fq 'profiles: ["gbrain-pilot"]' docker-compose.yml
grep -Fq 'GBRAIN_REF: ${GBRAIN_REF:-c6dc0adf26a2d20df1147d2ec87c8922ca86d410}' docker-compose.yml
grep -Fq '/staging:ro' docker-compose.yml
grep -Fq 'user: "0:0"' docker-compose.yml
grep -Fq 'GBRAIN_SKIP_STARTUP_HOOKS: "1"' docker-compose.yml
grep -Fq 'stop_grace_period: 30s' docker-compose.yml
gbrain_block=$(sed -n '/^  gbrain-pilot:/,/^  firecrawl-api:/p' docker-compose.yml)
! grep -Fqi 'obsidian' <<< "$gbrain_block"
! grep -Fq 'ports:' <<< "$gbrain_block"
! grep -Eq '(API_KEY|TOKEN|PASSWORD|SECRET)' <<< "$gbrain_block"
grep -Fq 'GBRAIN_REF=c6dc0adf26a2d20df1147d2ec87c8922ca86d410' .env.example
grep -Fq 'git checkout --detach "$GBRAIN_REF"' gbrain/Dockerfile
grep -Fq 'git apply --check /tmp/0001-close-pglite-after-http-shutdown.patch' gbrain/Dockerfile
grep -Fq 'bun install --frozen-lockfile --production' gbrain/Dockerfile
grep -Fq 'Shared/*' scripts/prepare-gbrain-pilot-corpus.sh
grep -Fq 'Profiles/$profile/' scripts/prepare-gbrain-pilot-corpus.sh
grep -Fq 'find "$candidate" -type f -name' scripts/prepare-gbrain-pilot-corpus.sh
grep -Fq 'diff -u "$before_hash" "$after_hash"' scripts/prepare-gbrain-pilot-corpus.sh
grep -Fq 'import "/staging/$profile/$relative" --no-embed' scripts/run-gbrain-pilot.sh
grep -Fq 'config set search.mode conservative' scripts/run-gbrain-pilot.sh
grep -Fq 'init --pglite --no-embedding' scripts/run-gbrain-pilot.sh
grep -Fq 'Operation is not permitted by the read-only pilot' scripts/run-gbrain-pilot.sh
! grep -Fq 'run_gbrain serve' scripts/run-gbrain-pilot.sh
! grep -Fq 'run_gbrain embed' scripts/run-gbrain-pilot.sh

grep -Fq 'profiles: ["gbrain-http-test"]' docker-compose.yml
http_test_block=$(sed -n '/^  gbrain-http-test:/,/^  firecrawl-api:/p' docker-compose.yml)
grep -Fq '127.0.0.1:${GBRAIN_HTTP_TEST_HOST_PORT:-3131}:3131' <<< "$http_test_block"
! grep -Fqi 'obsidian' <<< "$http_test_block"
! grep -Eq '(API_KEY|TOKEN|PASSWORD|SECRET)' <<< "$http_test_block"
grep -Fq 'gbrain serve --http' docs/gbrain-pilot.md
grep -Fq 'unauthenticated JSON-RPC' docs/gbrain-pilot.md
grep -Fq 'read-scope authorization result' docs/gbrain-pilot.md
grep -Fq 'must **not** be treated as an enforcement boundary' docs/gbrain-pilot.md
grep -Fq 'MCP allowlist proxy' docs/gbrain-pilot.md
grep -Fq 'verify-gbrain-http-read-client.sh' docs/gbrain-pilot.md
grep -Fq 'run-gbrain-allowlist-test.sh' docs/gbrain-pilot.md
grep -Fq 'GBRAIN_HTTP_TEST_ENV_FILE' scripts/run-gbrain-http-test.sh
grep -Fq 'init --pglite --no-embedding' scripts/run-gbrain-http-test.sh
grep -Fq 'for _attempt in {1..20}; do' scripts/run-gbrain-http-test.sh
grep -Fq 'OAuth discovery did not become ready within 20 seconds.' scripts/run-gbrain-http-test.sh
grep -Fq '401|403' scripts/run-gbrain-http-test.sh
grep -Fq 'docker port "$container_id" 3131' scripts/run-gbrain-http-test.sh
grep -Fq 'up -d --build gbrain-http-test' scripts/run-gbrain-http-test.sh
grep -Fq 'exec bun /opt/gbrain/src/cli.ts "$@"' gbrain/entrypoint.sh
grep -Fq 'recover_stale_serve_lock' scripts/run-gbrain-http-test.sh
grep -Fq 'cmp "$lock_dir/lock" "$backup_dir/lock"' scripts/run-gbrain-http-test.sh
grep -Fq 'PGLite serve lock remains after a graceful HTTP stop' scripts/run-gbrain-http-test.sh
grep -Fq 'closeAndCleanup' gbrain/patches/0001-close-pglite-after-http-shutdown.patch
grep -Fq 'await disconnectEngine();' gbrain/patches/0001-close-pglite-after-http-shutdown.patch
grep -Fq "requires 'write' scope" scripts/verify-gbrain-http-read-client.sh
grep -Fq 'tools/list still advertises put_page' scripts/verify-gbrain-http-read-client.sh
grep -Fq 'Authorization: Bearer $access_token' scripts/verify-gbrain-http-read-client.sh
grep -Fq 'run-gbrain-http-test.sh" verify' scripts/verify-gbrain-http-read-client.sh
grep -Fq 'profiles: ["gbrain-proxy-test"]' docker-compose.yml
proxy_block=$(sed -n '/^  gbrain-mcp-allowlist-test:/,/^  firecrawl-api:/p' docker-compose.yml)
grep -Fq '127.0.0.1:${GBRAIN_ALLOWLIST_TEST_HOST_PORT:-3132}:3132' <<< "$proxy_block"
grep -Fq 'GBRAIN_ALLOWED_TOOLS: search' <<< "$proxy_block"
grep -Fq 'GBRAIN_UPSTREAM_TOKEN_URL: http://gbrain-http-test:3131/token' <<< "$proxy_block"
grep -Fq 'read_only: true' <<< "$proxy_block"
grep -Fq 'user: "0:0"' <<< "$proxy_block"
! grep -Fqi 'obsidian' <<< "$proxy_block"
grep -Fq 'filter_tools_list' gbrain-allowlist-proxy/server.py
grep -Fq 'allowed_request' gbrain-allowlist-proxy/server.py
grep -Fq 'GBRAIN_ALLOWED_TOOLS' gbrain-allowlist-proxy/server.py
grep -Fq 'not permitted by the retrieval proxy' scripts/run-gbrain-allowlist-test.sh
grep -Fq 'up -d --no-deps --build gbrain-mcp-allowlist-test' scripts/run-gbrain-allowlist-test.sh
grep -Fq 'ps --status running -q gbrain-http-test' scripts/run-gbrain-allowlist-test.sh
grep -Fq 'Reusing running gbrain-http-test after Phase 1 verification.' scripts/run-gbrain-allowlist-test.sh
grep -Fq 'run-gbrain-http-test.sh" verify' scripts/run-gbrain-allowlist-test.sh

fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/scripts" "$fixture_dir/gbrain" \
  "$fixture_dir/appdata/hermes/obsidian-memory-vault/Shared/Infrastructure" \
  "$fixture_dir/appdata/hermes/obsidian-memory-vault/Profiles/maestro/Research Wikis"
cp scripts/prepare-gbrain-pilot-corpus.sh "$fixture_dir/scripts/"
cp gbrain/pilot-include.example "$fixture_dir/gbrain/"
printf 'APPDATA_DIR=./appdata\n' > "$fixture_dir/.env"
printf '%s\n' '# selected pilot note' > "$fixture_dir/appdata/hermes/obsidian-memory-vault/Shared/Infrastructure/decision.md"
printf '%s\n' '# excluded non-Markdown file' > "$fixture_dir/appdata/hermes/obsidian-memory-vault/Shared/Infrastructure/secret.env"
printf '%s\n' '# profile note' > "$fixture_dir/appdata/hermes/obsidian-memory-vault/Profiles/maestro/Research Wikis/guide.md"
"$fixture_dir/scripts/prepare-gbrain-pilot-corpus.sh" --profile maestro --init-manifest
printf '%s\n' 'Shared/Infrastructure' 'Profiles/maestro/Research Wikis' > "$fixture_dir/appdata/gbrain/pilot-include-maestro.txt"
"$fixture_dir/scripts/prepare-gbrain-pilot-corpus.sh" --profile maestro --apply
staged_dir=$(find "$fixture_dir/appdata/gbrain/staging/maestro" -mindepth 1 -maxdepth 1 -type d -print -quit)
test -f "$staged_dir/Shared/Infrastructure/decision.md"
test -f "$staged_dir/Profiles/maestro/Research Wikis/guide.md"
test ! -e "$staged_dir/Shared/Infrastructure/secret.env"
before_hash=$(find "$fixture_dir/appdata/gbrain/reports/maestro" -name 'vault-before-*.sha256' -print -quit)
after_hash=$(find "$fixture_dir/appdata/gbrain/reports/maestro" -name 'vault-after-*.sha256' -print -quit)
diff -u "$before_hash" "$after_hash"

#!/usr/bin/env bash
set -euo pipefail

sql=gbrain/metabase-reporting.sql
setup=scripts/configure-gbrain-metabase.sh

bash -n "$setup"
grep -Fq 'CREATE SCHEMA IF NOT EXISTS metabase_reporting' "$sql"
for view in \
  overview \
  profile_inventory \
  content_inventory \
  mcp_activity_daily \
  ingestion_activity_daily \
  relationship_inventory \
  client_health; do
  grep -Fq "CREATE OR REPLACE VIEW metabase_reporting.$view" "$sql"
done

grep -Fq 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM gbrain_reporting' "$sql"
grep -Fq 'GRANT USAGE ON SCHEMA metabase_reporting TO gbrain_reporting' "$sql"
grep -Fq 'default_transaction_read_only = on' "$setup"
grep -Fq "statement_timeout = '30s'" "$setup"
grep -Fq "lock_timeout = '2s'" "$setup"
grep -Fq 'CONNECTION LIMIT 5' "$setup"
grep -Fq "has_table_privilege('gbrain_metabase_reader','public.pages','SELECT')" "$setup"

# The reporting surface must never expose raw memory text, request payloads,
# secrets, or embedding vectors.
! grep -Eq 'SELECT[^;]*(compiled_truth|chunk_text|error_message|params|client_secret_hash)' "$sql"
! grep -Eq 'GRANT SELECT ON (ALL TABLES|public\.)' "$sql"

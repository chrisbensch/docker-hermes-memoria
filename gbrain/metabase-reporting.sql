\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS metabase_reporting AUTHORIZATION gbrain;
REVOKE ALL ON SCHEMA metabase_reporting FROM PUBLIC;

CREATE OR REPLACE VIEW metabase_reporting.overview AS
SELECT
  (SELECT count(*) FROM public.pages WHERE deleted_at IS NULL) AS active_pages,
  (SELECT count(DISTINCT frontmatter->>'hindsight_profile')
     FROM public.pages
    WHERE deleted_at IS NULL
      AND coalesce(frontmatter->>'hindsight_profile', '') <> '') AS profiles,
  (SELECT count(*) FROM public.content_chunks) AS chunks,
  (SELECT count(*) FROM public.content_chunks WHERE embedded_at IS NOT NULL) AS embedded_chunks,
  round(
    100.0 * (SELECT count(*) FROM public.content_chunks WHERE embedded_at IS NOT NULL)
    / nullif((SELECT count(*) FROM public.content_chunks), 0),
    2
  ) AS embedding_coverage_percent,
  (SELECT count(*) FROM public.links) AS links,
  (SELECT count(*) FROM public.timeline_entries) AS timeline_entries,
  (SELECT count(*) FROM public.tags) AS tag_assignments,
  (SELECT count(DISTINCT tag) FROM public.tags) AS distinct_tags,
  (SELECT count(*) FROM public.oauth_clients WHERE deleted_at IS NULL) AS active_clients,
  (SELECT max(created_at) FROM public.ingest_log) AS last_ingest_at,
  (SELECT max(created_at) FROM public.mcp_request_log) AS last_mcp_request_at;

CREATE OR REPLACE VIEW metabase_reporting.profile_inventory AS
WITH page_stats AS (
  SELECT
    coalesce(nullif(frontmatter->>'hindsight_profile', ''), '(unassigned)') AS profile,
    coalesce(nullif(frontmatter->>'hindsight_bank_id', ''), '(unassigned)') AS bank_id,
    count(*) AS pages,
    count(*) FILTER (WHERE type = 'entity') AS entity_pages,
    count(*) FILTER (WHERE type <> 'entity' OR type IS NULL) AS note_pages,
    min(created_at) AS first_page_at,
    max(updated_at) AS last_page_updated_at
  FROM public.pages
  WHERE deleted_at IS NULL
  GROUP BY 1, 2
), chunk_stats AS (
  SELECT
    coalesce(nullif(p.frontmatter->>'hindsight_profile', ''), '(unassigned)') AS profile,
    coalesce(nullif(p.frontmatter->>'hindsight_bank_id', ''), '(unassigned)') AS bank_id,
    count(c.*) AS chunks,
    count(c.*) FILTER (WHERE c.embedded_at IS NOT NULL) AS embedded_chunks
  FROM public.pages p
  LEFT JOIN public.content_chunks c ON c.page_id = p.id
  WHERE p.deleted_at IS NULL
  GROUP BY 1, 2
), tag_stats AS (
  SELECT
    coalesce(nullif(p.frontmatter->>'hindsight_profile', ''), '(unassigned)') AS profile,
    coalesce(nullif(p.frontmatter->>'hindsight_bank_id', ''), '(unassigned)') AS bank_id,
    count(t.*) AS tag_assignments,
    count(DISTINCT t.tag) AS distinct_tags
  FROM public.pages p
  LEFT JOIN public.tags t ON t.page_id = p.id
  WHERE p.deleted_at IS NULL
  GROUP BY 1, 2
), link_stats AS (
  SELECT
    coalesce(nullif(p.frontmatter->>'hindsight_profile', ''), '(unassigned)') AS profile,
    coalesce(nullif(p.frontmatter->>'hindsight_bank_id', ''), '(unassigned)') AS bank_id,
    count(l.*) AS outgoing_links
  FROM public.pages p
  LEFT JOIN public.links l ON l.from_page_id = p.id
  WHERE p.deleted_at IS NULL
  GROUP BY 1, 2
), timeline_stats AS (
  SELECT
    coalesce(nullif(p.frontmatter->>'hindsight_profile', ''), '(unassigned)') AS profile,
    coalesce(nullif(p.frontmatter->>'hindsight_bank_id', ''), '(unassigned)') AS bank_id,
    count(te.*) AS timeline_entries
  FROM public.pages p
  LEFT JOIN public.timeline_entries te ON te.page_id = p.id
  WHERE p.deleted_at IS NULL
  GROUP BY 1, 2
)
SELECT
  p.profile,
  p.bank_id,
  p.pages,
  p.entity_pages,
  p.note_pages,
  coalesce(c.chunks, 0) AS chunks,
  coalesce(c.embedded_chunks, 0) AS embedded_chunks,
  coalesce(c.chunks - c.embedded_chunks, 0) AS pending_chunks,
  coalesce(t.tag_assignments, 0) AS tag_assignments,
  coalesce(t.distinct_tags, 0) AS distinct_tags,
  coalesce(l.outgoing_links, 0) AS outgoing_links,
  coalesce(te.timeline_entries, 0) AS timeline_entries,
  p.first_page_at,
  p.last_page_updated_at
FROM page_stats p
LEFT JOIN chunk_stats c USING (profile, bank_id)
LEFT JOIN tag_stats t USING (profile, bank_id)
LEFT JOIN link_stats l USING (profile, bank_id)
LEFT JOIN timeline_stats te USING (profile, bank_id);

CREATE OR REPLACE VIEW metabase_reporting.content_inventory AS
SELECT
  coalesce(nullif(frontmatter->>'hindsight_profile', ''), '(unassigned)') AS profile,
  coalesce(nullif(frontmatter->>'hindsight_bank_id', ''), '(unassigned)') AS bank_id,
  coalesce(type, '(unset)') AS gbrain_type,
  coalesce(nullif(frontmatter->>'hindsight_kind', ''), '(unset)') AS hindsight_kind,
  coalesce(nullif(frontmatter->>'hindsight_entity_status', ''), '(unset)') AS entity_status,
  coalesce(nullif(frontmatter->>'hindsight_state', ''), '(unset)') AS hindsight_state,
  count(*) AS pages,
  max(updated_at) AS last_updated_at
FROM public.pages
WHERE deleted_at IS NULL
GROUP BY 1, 2, 3, 4, 5, 6;

CREATE OR REPLACE VIEW metabase_reporting.mcp_activity_daily AS
SELECT
  date_trunc('day', created_at AT TIME ZONE 'UTC')::date AS activity_day_utc,
  coalesce(agent_name, '(unknown)') AS agent_name,
  operation,
  status,
  count(*) AS requests,
  round(avg(latency_ms)::numeric, 2) AS average_latency_ms,
  percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms) AS p95_latency_ms,
  max(latency_ms) AS maximum_latency_ms
FROM public.mcp_request_log
GROUP BY 1, 2, 3, 4;

CREATE OR REPLACE VIEW metabase_reporting.ingestion_activity_daily AS
SELECT
  date_trunc('day', created_at AT TIME ZONE 'UTC')::date AS activity_day_utc,
  source_id,
  source_type,
  count(*) AS ingestion_runs,
  sum(CASE WHEN jsonb_typeof(pages_updated) = 'array' THEN jsonb_array_length(pages_updated) ELSE 0 END)
    AS pages_updated
FROM public.ingest_log
GROUP BY 1, 2, 3;

CREATE OR REPLACE VIEW metabase_reporting.relationship_inventory AS
SELECT
  coalesce(nullif(fp.frontmatter->>'hindsight_profile', ''), '(unassigned)') AS from_profile,
  coalesce(nullif(tp.frontmatter->>'hindsight_profile', ''), '(unassigned)') AS to_profile,
  coalesce(l.link_type, '(unset)') AS link_type,
  coalesce(l.link_kind, '(unset)') AS link_kind,
  coalesce(l.resolution_type, '(unset)') AS resolution_type,
  count(*) AS links
FROM public.links l
JOIN public.pages fp ON fp.id = l.from_page_id AND fp.deleted_at IS NULL
JOIN public.pages tp ON tp.id = l.to_page_id AND tp.deleted_at IS NULL
GROUP BY 1, 2, 3, 4, 5;

CREATE OR REPLACE VIEW metabase_reporting.client_health AS
SELECT
  count(*) FILTER (WHERE deleted_at IS NULL) AS active_clients,
  count(*) FILTER (WHERE deleted_at IS NOT NULL) AS deleted_clients,
  max(created_at) AS most_recent_client_created_at
FROM public.oauth_clients;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM gbrain_reporting;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM gbrain_reporting;
GRANT USAGE ON SCHEMA metabase_reporting TO gbrain_reporting;
GRANT SELECT ON
  metabase_reporting.overview,
  metabase_reporting.profile_inventory,
  metabase_reporting.content_inventory,
  metabase_reporting.mcp_activity_daily,
  metabase_reporting.ingestion_activity_daily,
  metabase_reporting.relationship_inventory,
  metabase_reporting.client_health
TO gbrain_reporting;

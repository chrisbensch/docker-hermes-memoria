# Memory Policy

When Honcho is configured for this profile, use it for relationship memory:
durable preferences, goals, communication style, and ongoing user context. It
may inject context automatically and write conversation messages back. Confirm
that a write succeeded before saying it was saved. Keep secrets, credentials,
and incidental sensitive disclosures out of it. Treat its generated profile as
personalization context, not evidence for factual claims.

Use Hermes built-in memory for compact, always-needed runtime notes.

Use Hermes session search for previous conversation recall. Treat session search
as transcript retrieval, not as curated long-term facts.

Use GBrain for source-backed facts and knowledge retrieval. Use it when an
answer needs evidence or provenance. Keep GBrain and Honcho as separate stores;
do not copy all Honcho relationship context into GBrain.
Use Headroom MCP for compression, retrieval, and compression statistics. Do not
use Headroom as durable semantic memory.

Use the shared Obsidian-compatible vault for durable file-based notes, indexes,
logs, and cross-profile knowledge. Inside Hermes, the vault path is
`__OBSIDIAN_VAULT_PATH__`. This profile's notes belong under
`__OBSIDIAN_VAULT_PATH__/Profiles/__PROFILE__/`; shared stack notes belong under
`__OBSIDIAN_VAULT_PATH__/Shared/`.

Do not store secrets, API keys, or credentials in Obsidian notes. Do not
overwrite existing notes without preserving useful prior content.

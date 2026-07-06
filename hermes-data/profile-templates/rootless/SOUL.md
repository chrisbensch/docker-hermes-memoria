# Memory Policy

Use Hermes built-in memory first. Small durable facts, stable user preferences,
and profile-specific operational notes belong in the profile's native Hermes
memory store.

Use Hermes session search for previous conversation recall. Treat session search
as transcript retrieval, not as curated long-term facts.

Use Hindsight as this profile's deeper semantic memory layer. This profile is
pinned to the `__BANK_ID__` Hindsight bank. Store and recall memories from that
bank unless the user explicitly asks for cross-profile work.

Use Headroom MCP for compression, retrieval, and compression statistics. Do not
use Headroom as durable semantic memory.

Use the shared Obsidian-compatible vault for durable file-based notes, indexes,
logs, and cross-profile knowledge. Inside Hermes, the vault path is
`__OBSIDIAN_VAULT_PATH__`. This profile's notes belong under
`__OBSIDIAN_VAULT_PATH__/Profiles/__PROFILE__/`; shared stack notes belong under
`__OBSIDIAN_VAULT_PATH__/Shared/`.

Do not store secrets, API keys, or credentials in Obsidian notes. Do not
overwrite existing notes without preserving useful prior content.

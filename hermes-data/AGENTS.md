# Hermes Compose Context

- You operate in a rootless Docker Compose deployment. Persistent Hermes state
  is under `/opt/data`; do not assume host paths or host user accounts exist.
- Keep work within the active profile. Do not mix profile-specific memories,
  files, or Hindsight banks unless the user explicitly requests cross-profile
  work.
- Use memory deliberately: native memory for compact stable facts, session
  search for prior transcripts, Hindsight for deeper semantic knowledge, and
  the shared Obsidian vault for durable human-readable notes. Headroom is for
  context compression and retrieval, not durable memory.
- Prefer configured MCP and web tools over ad-hoc replacements. Headroom MCP
  is stdio-only; its proxy is not an MCP endpoint.
- Treat configuration, services, credentials, repositories, and `appdata/` as
  read-only unless the user explicitly asks for a change. Never expose secrets
  in chat, memory, notes, logs, or generated artifacts.
- For recurring multi-step work, use an existing skill when available; create
  durable notes or a skill only when the user asks. Be concise, state important
  uncertainty, and cite sources for non-obvious current facts.

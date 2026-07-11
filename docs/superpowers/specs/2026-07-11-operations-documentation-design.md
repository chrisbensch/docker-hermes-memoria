# Operations Documentation Design

**Date:** 2026-07-11

## Objective

Update the repository documentation to reflect the current rootless Docker
Compose architecture, host-data migration tooling, guarded Hindsight bank
export and restore workflow, and validated Restic backup system. Commands must
be useful on a fresh deployment without embedding credentials or details that
only apply to one server.

## Document Responsibilities

### `AGENTS.md`

Serve as the contributor and automation-agent guide. It will describe the
current repository layout, distinguish tracked configuration from ignored
runtime state, document Bash and Python conventions, list the real test suite,
and state safety rules for rootless ownership, migrations, backup data, and
secrets. It will remove stale claims that the repository has no tests or Git
history.

### `README.md`

Remain the canonical architecture and feature reference. It will summarize the
integrated service topology, profile and Hindsight bank model, migration path,
backup architecture, and links to task-focused guides. Existing detailed
material will be retained where it remains authoritative, but operational
procedures will link to `OPERATIONS.md` instead of growing duplicate runbooks.

### `QUICKSTART.md`

Remain the shortest path from a fresh clone to a healthy stack. It will cover
preflight, setup, startup, profile and service validation, and the immediate
post-install step of reviewing backup configuration. Migration and ongoing
maintenance will be linked rather than reproduced in full.

### `OPERATIONS.md`

Provide the day-two runbook. It will cover:

- stack status, health checks, logs, startup, and shutdown;
- dashboard authentication and password reset verification;
- profile, Memory Vault, cron, and integrated URL validation;
- Hindsight logical exports, validation, guarded restores, and bank checks;
- Restic environment loading, snapshots, data-size inspection, repository
  checks, timer management, manual logical and raw backups, and restore
  sequencing;
- migration inventory and host-data import verification;
- troubleshooting rules that preserve copied runtime data and failed backup
  staging directories until explicitly reviewed.

## Content Rules

- Use rootless Docker Compose commands with `--env-file .env`.
- Use Compose service names for container-to-container URLs.
- Keep secrets, passwords, Restic repository credentials, generated SearXNG
  settings, `.firecrawl-src`, and `appdata/` out of tracked examples.
- Use placeholders for server addresses, provider models, and backup locations.
- Clearly label destructive commands and require a backup before data moves,
  deletion, or raw restore operations.
- Link between guides instead of maintaining competing copies of long command
  sequences.
- Preserve historical design and implementation records under
  `docs/superpowers/` unchanged.

## Validation

Documentation changes will be checked with:

```bash
git diff --check
bash tests/test_backup_scripts.sh
python3 -m unittest discover -s tests -v
bash -n scripts/*.sh setup.sh reset.sh
docker compose --env-file .env config --quiet
```

The Compose validation requires a configured local `.env` and generated bind
mount inputs. If those are unavailable in the clean development clone, the
result will be reported as not run rather than implied to have passed.

## Acceptance Criteria

- Each document has a distinct purpose and cross-links to the others.
- Commands match the scripts and service names currently in the repository.
- Backup documentation reflects the validated daily logical and weekly raw
  Hindsight workflow and correct Restic retention grouping.
- Migration guidance protects copied data and points to the inventory and
  migration scripts.
- Contributor instructions describe the actual tests and Git-backed workflow.

# Repository Guidelines

## Purpose And Layout

This repository packages Hermes Agent and its Hindsight, Headroom, Firecrawl,
SearXNG, and Camofox dependencies as a rootless Docker Compose stack.

- `docker-compose.yml` defines the stack; use `.env` for local Compose values.
- `hermes-data/` contains tracked seed configuration and profile templates.
- `web-search/` contains tracked SearXNG and proxy templates. Generated
  `web-search/searxng-settings.yml` and `.firecrawl-src/` are ignored.
- `scripts/` contains profile, migration, Hindsight export/restore, permission,
  Restic backup, and timer-installation utilities. Use
  `scripts/fix-obsidian-vault-permissions.sh` as the canonical shared-vault
  ownership operation. Use `scripts/fix-headroom-mcp-command.py` to migrate
  existing profile configs to the rootless Headroom stdio command.
- `systemd/` contains user services and timers for daily logical backups and
  weekly raw Hindsight checkpoints.
- `tests/` contains Bash integration/static checks and Python `unittest` tests.
- `QUICKSTART.md` is the install path, `README.md` is the architecture reference,
  and `OPERATIONS.md` is the day-two runbook.
- `docs/superpowers/` records approved designs and implementation plans; do not
  rewrite historical records while making unrelated changes.

Ignored `appdata/` is writable runtime state, not a source tree. It includes
Hermes profiles, SQLite databases, the Obsidian Memory Vault, Hindsight state,
and other service data. Keep secrets in ignored `.env` files or external secret
stores; commit only examples and templates.

## Development Commands

Run commands from the repository root:

```bash
docker compose --env-file .env config --quiet
docker compose --env-file .env up -d
docker compose --env-file .env ps
bash tests/test_backup_scripts.sh
python3 -m unittest discover -s tests -v
bash -n scripts/*.sh setup.sh reset.sh
git diff --check
```

Compose validation requires a configured `.env`,
`.firecrawl-src/apps/nuq-postgres`, and generated
`web-search/searxng-settings.yml`. Report it as not run when those local inputs
are absent; do not imply that syntax validation proves runtime health.

Use `./setup.sh` for guided setup, `./scripts/create-profile.sh <profile>` for a
profile and bank, and `./scripts/install-backup-timers.sh` for systemd user
timers. Migration work starts with
`scripts/collect-host-migration-inventory.sh`, then uses
`scripts/migrate-host-hermes-data.sh --dry-run` before applying changes.

Headroom MCP is intentionally launched on demand over stdio in the sleeping
`hermes-headroom-mcp` container. The rootless Docker socket is already mounted
in Hermes. Profile configs must launch it through `sg hostdocker -c` because
some Hermes execution paths drop supplementary groups before starting MCP
subprocesses. Do not add a second socket mount, hard-code a mapped socket GID,
or describe `headroom-proxy` as an HTTP MCP endpoint. The proxy provides LLM
proxy and statistics APIs; it is not the MCP transport.

## Coding Conventions

- Use two-space indentation in YAML and preserve existing Compose service names
  for container-to-container URLs.
- Legacy setup, migration, permission, and profile scripts may use POSIX `sh`
  with `#!/usr/bin/env sh` and `set -eu`. Keep them POSIX-compatible.
- Operational scripts use Bash with `#!/usr/bin/env bash` and
  `set -Eeuo pipefail`. Quote expansions and fail clearly on missing inputs.
- Python utilities use the standard library, type hints where useful, and
  `unittest`. Keep network and filesystem operations injectable or testable.
- Profile names are lowercase letters, numbers, underscores, and hyphens;
  `default` is reserved. Hindsight bank IDs normally use `hermes-<profile>`.

## Migration, Backup, And Restore Safety

- Rootless container data can display numeric ownership that differs from the
  host user. Treat that as expected; use the provided normalization script only
  when the documented workflow calls for it.
- The Obsidian vault is `hermes:root` inside the container. Container `hermes`
  maps to a subordinate host UID, while container group `root` maps to the
  deployment user's host group. Setgid directories and default POSIX ACLs keep
  both identities writable when Hermes creates files with umask `0022`.
- Do not run host `sudo chown` against `/opt/data`, guess a subordinate UID, or
  assume a host `hermes` account exists. Install Ubuntu's `acl` package and use
  `scripts/fix-obsidian-vault-permissions.sh` for vault repair.
- Preserve the `sg hostdocker` Headroom command in profile templates and live
  configs. Diagnose it with the profile-aware `hermes -p <profile> mcp test
  headroom` command documented in `OPERATIONS.md`; `docker compose exec -u`
  can drop supplementary groups and produce a misleading socket failure.
- Never delete, replace, move, or recursively change ownership of `appdata/`
  without first creating and verifying a timestamped copy or Restic snapshot.
- Preserve migrated host configuration under `host-migration/` and existing
  destination data under `migration-backups/`. Run migrations in dry-run mode
  first and migrate all profiles unless the task explicitly narrows the scope.
- Use `backup-hindsight-banks.py` for logical exports and
  `validate-hindsight-bank-backup.py` before any restore. Treat
  `restore-hindsight-bank-backup.py --apply` as a write operation and confirm
  its target-bank preconditions and pre-restore checkpoint.
- `backup-hermes-data.sh --mode daily` creates logical application exports;
  `--mode weekly-raw` briefly stops Hindsight for a raw checkpoint. Failed
  staging directories are retained intentionally for diagnosis; inspect them
  before removing them.
- Redis and RabbitMQ queue state for Firecrawl is intentionally excluded from
  durable backups. Firecrawl PostgreSQL data is the durable component.
- Never commit Restic repository credentials, password files, backup contents,
  copied secrets, generated SearXNG settings, `.firecrawl-src/`, or `appdata/`.

## Git And Review Workflow

Inspect `git status` before editing and do not discard unrelated changes. Keep
commits narrowly scoped with concise imperative subjects. Before committing,
run the checks relevant to the changed files and record any unavailable runtime
validation. Pull requests should identify the deployment path affected, list
commands run, and call out changes to ports, socket mounts, ownership, secrets,
profile defaults, migration behavior, or restore behavior. Push the intended
branch and verify it matches its upstream when publication is part of the task.

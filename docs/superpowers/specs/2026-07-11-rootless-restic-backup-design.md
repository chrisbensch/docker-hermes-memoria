# Rootless Restic Backup Design

## Goal

Create a reliable, rootless Docker-aware backup system for
`/home/sysadmin/docker-hermes-memoria` on `bl-agentic-01`. It must protect
Hermes profiles, the Obsidian Memory Vault, cron definitions, Hindsight state,
and required deployment configuration in an encrypted Restic repository on the
NAS.

## Chosen Approach

Use a daily online logical backup plus a weekly raw Hindsight checkpoint.

- The daily backup runs at `07:45 JST` using a persistent `systemd --user`
  timer. It runs after the existing cron and consolidation work, without
  restarting Hermes or its messaging gateway.
- The daily job creates a complete portable Hindsight document-transfer export
  with all pages and observations, validates it, stages Hermes data through the
  running Hermes container, and uploads the staging set to Restic.
- The weekly job briefly stops only `hindsight-mcp`, captures its raw `.pg0`
  state through a one-off Compose container, restarts Hindsight immediately,
  and uploads that checkpoint to Restic.

This pairs a version-independent logical Hindsight restore path with a fast,
exact raw recovery path. It avoids backing up directly from the host paths that
are unreadable to `sysadmin` because of rootless Docker UID mappings.

## Scope

Daily Restic snapshots include:

- a Hermes archive produced from `/opt/data` in the Hermes container, including
  all profiles, `.env` files, Memory Vault and `.obsidian`, cron jobs, sessions,
  skills, configuration, and credentials, while excluding logs and runtime
  caches;
- a complete validated Hindsight logical export for every bank, including
  paginated API lists, document-transfer ZIP files, and observations;
- the repository `.env`, `web-search/searxng-settings.yml`, and a manifest
  containing the Git commit and Compose configuration fingerprint;
- `appdata/headroom` through the Headroom container;
- a consistent Firecrawl Postgres dump.

Daily snapshots exclude Firecrawl Redis and RabbitMQ queue state, Camofox and
Playwright runtime state, Docker images, cloned Firecrawl source, logs, caches,
and generic `tmp/` contents. The existing migration and Hindsight backups will
be taken once as a separate archival Restic snapshot before those routine
exclusions apply.

The weekly snapshot additionally includes a raw `appdata/hindsight` archive.

## Components

### `scripts/backup-hindsight-banks.py`

Creates a portable Hindsight export at a caller-supplied directory. It must:

- preflight `/health`, `/version`, and required document-transfer endpoints;
- enumerate all banks and paginate memories, entities, documents, directives,
  and mental-model endpoints;
- export every bank's documents with observations included;
- record per-bank and aggregate counts plus SHA-256 checksums in `manifest.json`;
- compare source bank counts before and after export and fail if data changed
  during export;
- remain read-only toward Hindsight and never log secrets.

The output must pass `scripts/validate-hindsight-bank-backup.py` unchanged.

### `scripts/backup-hermes-data.sh`

Provides the daily and weekly backup workflow. It must:

- require `/home/sysadmin/.config/hermes-backup/restic.env` and source it only
  after verifying strict permissions;
- use `flock` to prevent overlap between timer runs and manual invocations;
- create a `0700` staging directory under
  `/home/sysadmin/.local/state/hermes-backup/staging`;
- use `docker compose exec` to stream container-readable data into
  sysadmin-owned staging archives without changing application ownership;
- run the Hindsight exporter and validator before invoking Restic;
- invoke Restic with stable tags, retention of 14 daily, 8 weekly, and 12
  monthly snapshots, then prune;
- retain failed staging directories and clean successful staging directories;
- use a `trap` to restart `hindsight-mcp` after the weekly raw checkpoint even
  when the archive or Restic upload fails.

### Systemd user units

- `hermes-backup.service` runs the daily workflow.
- `hermes-backup.timer` uses
  `OnCalendar=*-*-* 07:45:00 Asia/Tokyo` and `Persistent=true`.
- `hermes-hindsight-raw-backup.service` runs the weekly raw workflow.
- `hermes-hindsight-raw-backup.timer` runs every Saturday at `08:00 JST`, after
  the daily backup window, and also uses `Persistent=true`.

The installer writes these units to `~/.config/systemd/user/`, reloads the user
manager, and enables the timers. `sysadmin` linger must remain enabled.

## Failure Handling

- A missing Restic configuration, unreadable password file, unavailable NAS,
  unhealthy Hindsight API, export validation failure, or archive failure exits
  non-zero and leaves staging data in place for diagnosis.
- The daily job never restarts Hermes, Hermes Dashboard, Headroom, Firecrawl,
  Redis, or RabbitMQ.
- The weekly job stops and starts only `hindsight-mcp`; its restart is enforced
  by a shell trap.
- The job records reports and manifest data but redacts environment values and
  never writes credential material to logs or the Git repository.

## Verification

- Unit tests cover pagination, observations, count drift rejection, manifest
  integrity, and shell command assembly.
- Shell tests cover `bash -n` validation and verify the scripts do not invoke
  direct host reads of rootless `appdata/hermes`.
- A manual backup test verifies `restic snapshots`, `restic check`, and the
  Hindsight validation report.
- A quarterly isolated restore test restores a snapshot into a separate
  appdata directory, validates the logical Hindsight export, imports it into an
  empty Hindsight instance, and compares bank, profile, vault, and cron counts.

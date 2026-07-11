# Operations Runbook

This is the day-two operations guide for the rootless Hermes Compose stack.
Run commands from the repository root as the same unprivileged account that
runs rootless Docker. See `QUICKSTART.md` for first-time setup and `README.md`
for architecture and configuration details.

Commands below assume the default host ports and `APPDATA_DIR=./appdata`.
Read the corresponding values from `.env` before using different bindings or
paths. Keep `.env`, `appdata/`, `.firecrawl-src/`, generated SearXNG settings,
Restic credentials, and restore output out of Git.

## Repository And Rootless Docker Context

Enter the checkout and confirm that Docker is using the deployment user's
rootless daemon:

```bash
cd /path/to/docker-hermes-memoria
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"

pwd
git status --short --branch
docker context ls
docker info
test -S "/run/user/$(id -u)/docker.sock"
```

In `docker info`, verify that the active daemon is rootless and that its socket
belongs to the current user. The socket configured in `.env` must match:

```bash
grep -E '^(APPDATA_DIR|HERMES_UID|HERMES_GID|DOCKER_SOCK|HINDSIGHT_IMAGE)=' .env
```

Render the effective configuration before starting or recreating services:

```bash
test -d .firecrawl-src/apps/nuq-postgres
test -f web-search/searxng-settings.yml
docker compose --env-file .env config --quiet
```

The generated SearXNG file must contain a deployment-unique secret. Do not
commit it or print that secret into an issue, log, or support transcript.

## Stack Control And Health

Start, stop, and inspect the stack with the explicit environment file:

```bash
docker compose --env-file .env up -d
docker compose --env-file .env ps
docker compose --env-file .env stop
docker compose --env-file .env start
docker compose --env-file .env down --remove-orphans
```

`down` removes containers and the project network, but the bind-mounted data
under `APPDATA_DIR` remains. Do not add `--volumes` during routine operations.

Inspect all logs or focus on one service:

```bash
docker compose --env-file .env logs --tail=200
docker compose --env-file .env logs --tail=200 hindsight-mcp
docker compose --env-file .env logs --tail=200 hermes hermes-dashboard
docker compose --env-file .env logs -f firecrawl-api
```

Test the host-published sidecar endpoints:

```bash
curl -fsS http://127.0.0.1:8888/health
curl -fsS http://127.0.0.1:8787/readyz
curl -fsS http://127.0.0.1:3002/v0/health/liveness
curl -fsS "http://127.0.0.1:8889/search?q=health-check&format=json"
curl -fsS http://127.0.0.1:9377/health
```

These correspond to `hindsight-mcp`, `headroom-proxy`, `firecrawl-api`,
`searxng`, and `camofox` on the Compose network. A running `headroom-mcp`
container is expected to sleep until Hermes starts its stdio MCP command:

```bash
docker compose --env-file .env ps headroom-mcp
docker exec -i hermes-headroom-mcp headroom mcp serve
```

The second command is an interactive diagnostic; stop it with `Ctrl-C`.

## Dashboard Authentication

The dashboard is local-only by default. Before setting
`HERMES_DASHBOARD_BIND_HOST=0.0.0.0`, configure basic authentication in
`appdata/hermes/config.yaml`.

Generate a password hash with the exact Hermes image used by the stack:

```bash
docker compose --env-file .env exec -T hermes \
  python -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('<new-password>'))"
```

Store only the generated hash in the base runtime configuration:

```yaml
dashboard:
  basic_auth:
    username: admin
    password_hash: "<generated-password-hash>"
```

Recreate the dashboard so it reloads the configuration:

```bash
docker compose --env-file .env up -d --force-recreate hermes-dashboard
docker compose --env-file .env logs --tail=100 hermes-dashboard
```

Verify the form endpoint directly. An unauthenticated protected request should
redirect to login or return `401`; a valid form submission should return a
redirect and establish a session cookie:

```bash
cookie_jar=$(mktemp)
curl -sS -o /dev/null -w 'unauthenticated: HTTP %{http_code}\n' \
  http://127.0.0.1:9119/
curl -sS -o /dev/null -w 'login: HTTP %{http_code}\n' \
  -c "$cookie_jar" \
  --data-urlencode 'username=admin' \
  --data-urlencode 'password=<new-password>' \
  'http://127.0.0.1:9119/login?next=%2F'
curl -sS -o /dev/null -w 'authenticated: HTTP %{http_code}\n' \
  -b "$cookie_jar" http://127.0.0.1:9119/
rm -f "$cookie_jar"
```

Use `http://<server-ip>:9119/login?next=%2F` from a remote browser. The explicit
login URL avoids the OAuth-first redirect used by the dashboard root. If valid
credentials still return `401`, confirm the hash is in the base
`appdata/hermes/config.yaml`, not only a profile config, and confirm the
dashboard container was recreated after the edit.

## Migrated Data Validation

### Profiles And Active Profile

List profile directories, inspect the selected profile, and confirm its local
state exists:

```bash
find appdata/hermes/profiles -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
cat appdata/hermes/active_profile

active_profile=$(sed -n '1p' appdata/hermes/active_profile)
test -n "$active_profile"
test -f "appdata/hermes/profiles/$active_profile/config.yaml"
test -f "appdata/hermes/profiles/$active_profile/state.db"
```

Each lowercase profile normally uses bank `hermes-<profile>`. Compare the
profile list with Hindsight's bank inventory:

```bash
curl -fsS http://127.0.0.1:8888/v1/default/banks | python3 -m json.tool
```

### Integrated URLs

Hermes must use Compose service names rather than old external server URLs.
Check the base and profile environment files without printing unrelated secret
values:

```bash
find appdata/hermes -type f -name .env -print0 | \
  xargs -0 grep -H -E \
  '^(FIRECRAWL_API_URL|CAMOFOX_URL|SEARXNG_URL|OBSIDIAN_VAULT_PATH)='
```

Expected values are:

```text
FIRECRAWL_API_URL=http://firecrawl-api:3002
CAMOFOX_URL=http://camofox:9377
SEARXNG_URL=http://searxng:80/search
OBSIDIAN_VAULT_PATH=/opt/data/obsidian-memory-vault
```

Also inspect profile MCP configuration for single-bank Hindsight URLs such as
`http://hindsight-mcp:8888/mcp/hermes-<profile>/` and the Docker-backed
Headroom command:

```bash
grep -R -n -E 'hindsight-mcp:8888|hermes-headroom-mcp|headroom mcp serve' \
  appdata/hermes/profiles/*/config.yaml
```

### Memory Vault And Cron

Confirm that the shared vault, Obsidian metadata, consolidation notes, and
profile indexes survived migration:

```bash
test -d appdata/hermes/obsidian-memory-vault
find appdata/hermes/obsidian-memory-vault -maxdepth 2 -type d -print | sort
find appdata/hermes/obsidian-memory-vault -type f | wc -l
du -sh appdata/hermes/obsidian-memory-vault
```

Review migrated cron definitions and scripts for stale host paths or external
service addresses before allowing scheduled work to run:

```bash
find appdata/hermes/profiles -path '*/cron/*' -type f -print | sort
grep -R -n -E '/home/hermes|10\.[0-9]+\.[0-9]+\.[0-9]+|localhost:(3002|8321|9377)' \
  appdata/hermes/profiles/*/cron appdata/hermes/profiles/*/scripts 2>/dev/null || true
```

Inspect the files reported by the second command. Update paths to `/opt/data`
or `/opt/data/obsidian-memory-vault` and integrated URLs to Compose service
names. Preserve schedules, prompts, and completion markers unless their old
host assumptions are understood.

## Host-Install Migration

Collect the inventory on the old host before copying data. The report applies
pattern-based redaction, but it must still be reviewed before sharing:

```bash
HERMES_HOST_HOME=/path/to/.hermes \
HERMES_MEMORY_VAULT=/path/to/Memory_Vault \
COMPOSE_SEARCH_ROOTS="/path/to/hermes /path/to/compose" \
MIGRATION_INVENTORY_OUTPUT=/tmp/host-migration-$(date +%Y%m%dT%H%M%S).md \
./scripts/collect-host-migration-inventory.sh
```

After transferring the old Hermes home and Memory Vault to a staging location
on the new host, preview the import. With no profile arguments, every directory
under `OLD_HERMES_HOME/profiles` is migrated:

```bash
OLD_HERMES_HOME=/path/to/migrated/.hermes \
OLD_MEMORY_VAULT=/path/to/migrated/Memory_Vault \
./scripts/migrate-host-hermes-data.sh --dry-run
```

To preview selected profiles only, append their names:

```bash
OLD_HERMES_HOME=/path/to/migrated/.hermes \
OLD_MEMORY_VAULT=/path/to/migrated/Memory_Vault \
./scripts/migrate-host-hermes-data.sh --dry-run maestro research
```

### Safety Gate Before Apply

**Potentially destructive:** migration replaces some destination paths. The
script moves overwritten files into a timestamped
`appdata/hermes/migration-backups/` directory, but that is not a substitute for
an independent backup. Before applying, create a Restic daily snapshot if the
stack is operational:

```bash
./scripts/backup-hermes-data.sh --mode daily
```

For a new stack that cannot yet run the backup job, preserve timestamped copies
of the transferred source directories outside `appdata/`:

```bash
stamp=$(date +%Y%m%dT%H%M%S)
mkdir -p "/path/to/migration-safety/$stamp"
cp -a /path/to/migrated/.hermes "/path/to/migration-safety/$stamp/"
cp -a /path/to/migrated/Memory_Vault "/path/to/migration-safety/$stamp/"
```

Apply the all-profile migration only after reviewing the dry run:

```bash
OLD_HERMES_HOME=/path/to/migrated/.hermes \
OLD_MEMORY_VAULT=/path/to/migrated/Memory_Vault \
./scripts/migrate-host-hermes-data.sh
```

The migration preserves the old base config at
`appdata/hermes/host-migration/config.host-migration.yaml` and each old profile
config at `profiles/<profile>/host-migration/config.host-migration.yaml`. The
generated rootless `config.yaml` files remain live. By default, env/auth/token
files and bulky workspace data are copied, obvious host paths are rewritten,
and the old active profile is restored. Use `MIGRATE_SECRETS=0`,
`MIGRATE_BULKY_DIRS=0`, or `MIGRATE_REWRITE_TEXT=0` only after deliberately
reviewing the resulting omissions.

Start the stack, normalize host-group read access through the containers, and
repeat the profile, vault, cron, integrated URL, and bank checks above:

```bash
docker compose --env-file .env config --quiet
docker compose --env-file .env up -d
./scripts/normalize-appdata-permissions.sh
docker compose --env-file .env ps
```

Rootless numeric ownership under `appdata/` is expected. Do not recursively
`chown` database-owned Firecrawl, RabbitMQ, Redis, or Hindsight files from the
host.

## Hindsight Logical Backup

Export every bank, including document-transfer observations and count data:

```bash
backup_parent=tmp/hindsight-bank-backups
backup_name=hindsight-backup-$(date -u +%Y%m%d-%H%M%S)
mkdir -p "$backup_parent"

python3 scripts/backup-hindsight-banks.py \
  --api-url http://127.0.0.1:8888 \
  --output-dir "$backup_parent" \
  --backup-name "$backup_name" \
  --report "$backup_parent/$backup_name-export-report.json"
```

The exporter checks the bank inventory before and after export and fails if
counts change. Validate checksums, manifests, observations, and per-bank totals
without contacting Hindsight:

```bash
python3 scripts/validate-hindsight-bank-backup.py \
  --backup-dir "$backup_parent/$backup_name" \
  --report "$backup_parent/$backup_name/validation-report.json"

python3 -m json.tool \
  "$backup_parent/$backup_name/validation-report.json"
```

Keep the complete backup directory. A successful validation report without its
referenced ZIP files and JSON payloads is not restorable.

## Guarded Hindsight Restore

Logical restore is intended for a new, empty Hindsight target. It requires API
version 0.8.4 or newer and supported document-import endpoints. Selected target
banks must be absent; the script refuses to overwrite them.

Run the read-only target preflight first. Omitting `--bank` checks every bank in
the backup:

```bash
python3 scripts/restore-hindsight-bank-backup.py \
  --backup-dir tmp/hindsight-bank-backups/<backup-name> \
  --api-url http://127.0.0.1:8888 \
  --report tmp/hindsight-bank-backups/<backup-name>/target-dry-run.json
```

Review the source totals, target version, selected banks, and existing-bank
inventory in the report.

### Pilot Bank

**Writes to Hindsight:** `--apply` creates the selected bank and imports data.
It first captures the current target `.pg0` state under a timestamped
`tmp/hindsight-target-pre-restore-*` directory. Preserve that directory until
the restored system is accepted.

```bash
python3 scripts/restore-hindsight-bank-backup.py \
  --backup-dir tmp/hindsight-bank-backups/<backup-name> \
  --api-url http://127.0.0.1:8888 \
  --bank hermes-<pilot-profile> \
  --apply
```

The restore temporarily disables automatic consolidation, waits for the import
operation, compares document and memory counts, then removes the temporary bank
override. Inspect the generated `restore-report.json` and live bank:

```bash
curl -fsS http://127.0.0.1:8888/v1/default/banks | python3 -m json.tool
curl -fsS \
  'http://127.0.0.1:8888/v1/default/banks/hermes-<pilot-profile>/documents?limit=100&offset=0' \
  | python3 -m json.tool
curl -fsS \
  'http://127.0.0.1:8888/v1/default/banks/hermes-<pilot-profile>/memories/list?limit=100&offset=0' \
  | python3 -m json.tool
```

Accept the pilot only when document totals equal the validation report and live
memory totals equal exported facts plus observations.

### All Banks

After the pilot succeeds, restore the remaining absent banks by repeating
`--bank` or restore all banks into a fresh empty target by omitting it:

```bash
python3 scripts/restore-hindsight-bank-backup.py \
  --backup-dir tmp/hindsight-bank-backups/<backup-name> \
  --api-url http://127.0.0.1:8888 \
  --apply
```

Do not run the all-bank command against a target containing the pilot bank; the
existing-bank guard will stop it. For the same target, pass one `--bank` option
for each remaining bank instead.

Before requesting consolidation, confirm Hindsight can reach its configured LLM
endpoint from inside the container:

```bash
grep -E '^HINDSIGHT_API_LLM_(PROVIDER|MODEL|BASE_URL)=' .env
docker compose --env-file .env exec -T hindsight-mcp \
  sh -lc 'curl -fsS --max-time 10 "$HINDSIGHT_API_LLM_BASE_URL/models"'
docker compose --env-file .env logs --tail=300 hindsight-mcp | \
  grep -i -E 'consolidat|error|timeout|connection' || true
```

An empty base URL or failed container request must be corrected before
requeuing consolidation. Do not treat a host-only `curl` as proof that the
container network path works.

## Restic Backups

The host-side wrapper stages container-readable exports, then Restic encrypts,
deduplicates, uploads, and applies retention. Daily logical backups include
Hermes data and online SQLite exports, the Memory Vault, Headroom, Firecrawl
Postgres, deployment configuration, and validated logical Hindsight data.
Weekly raw backups briefly stop only Hindsight to checkpoint `.pg0`. Redis and
RabbitMQ queue state, caches, logs, generated images, and generic temporary data
are intentionally outside the durable scope.

### Load Configuration

Restic configuration is outside the checkout and must be mode `0400` or `0600`:

```bash
config="$HOME/.config/hermes-backup/restic.env"
test -r "$config"
stat -c '%a %n' "$config"
set -a
source "$config"
set +a
test -r "$RESTIC_PASSWORD_FILE"
```

Never print or commit the password file or repository credentials.

By default, `scripts/backup-hermes-data.sh` reads
`/home/sysadmin/.config/hermes-backup/restic.env` and writes staging state below
`/home/sysadmin/.local/state/hermes-backup`. On another deployment account,
set `HERMES_BACKUP_RESTIC_ENV` and `HERMES_BACKUP_STATE_ROOT` when invoking the
script and carry those settings into the systemd services.

### List Snapshots And Sizes

```bash
restic snapshots --tag hermes
restic snapshots --tag daily
restic snapshots --tag weekly

restic stats --mode restore-size latest
restic stats --mode restore-size <snapshot-id>
restic stats --mode raw-data
```

`restore-size` reports the logical size that a snapshot would restore.
`raw-data` reports repository data stored after Restic deduplication and
compression; it is not the sum of logical snapshot sizes.

Inspect snapshot paths before any restore and verify repository integrity:

```bash
restic ls <snapshot-id>
restic check
```

### Manual Jobs

Run the same workflows used by the timers:

```bash
./scripts/backup-hermes-data.sh --mode daily
./scripts/backup-hermes-data.sh --mode weekly-raw
```

Daily mode is online. Weekly raw mode causes a brief Hindsight interruption and
starts it again on success or failure. The script uses a nonblocking lock, so a
second job exits with `Backup already running`. Failed staging directories are
retained under `~/.local/state/hermes-backup/staging/` for diagnosis; do not
delete them until the failure is understood and any useful export is preserved.

### User Timers And Logs

The supplied timers run the daily logical backup at 07:45 JST and the weekly
raw checkpoint at 08:00 JST on Saturday. Enable linger once, then install them:

The checked-in service units target the validated checkout at
`/home/sysadmin/docker-hermes-memoria` and rootless socket
`/run/user/1000/docker.sock`. Before installation on another account or path,
update all `WorkingDirectory`, `ExecStart`, and `DOCKER_HOST` values under
`systemd/` and validate them with `systemd-analyze --user verify systemd/*`.

```bash
sudo loginctl enable-linger "$USER"
./scripts/install-backup-timers.sh
```

Inspect scheduling, status, and logs:

```bash
systemctl --user list-timers --all | grep -E 'hermes-backup|hermes-hindsight-raw-backup'
systemctl --user status hermes-backup.timer hermes-hindsight-raw-backup.timer
systemctl --user status hermes-backup.service hermes-hindsight-raw-backup.service
journalctl --user -u hermes-backup.service -n 200 --no-pager
journalctl --user -u hermes-hindsight-raw-backup.service -n 200 --no-pager
```

After changing a checked-in unit, reinstall it with
`./scripts/install-backup-timers.sh`; editing only `systemd/` does not update
the copies already loaded under `~/.config/systemd/user/`.

### Isolated Restore Test

Restore a snapshot into a new directory, never over live appdata:

```bash
restore_root=$(mktemp -d "$HOME/hermes-restore-test.XXXXXXXX")
restic restore <snapshot-id> --target "$restore_root"
find "$restore_root" -type f -print | sort
```

Restic preserves the absolute staging path beneath the restore target. Locate
the snapshot payload by its metadata rather than assuming a fixed timestamped
directory:

```bash
find "$restore_root" -name metadata.json -print
find "$restore_root" -name hindsight-validation.json -print
```

Validate the restored logical Hindsight directory before testing an import:

```bash
python3 scripts/validate-hindsight-bank-backup.py \
  --backup-dir /path/inside/restore-root/hindsight-logical \
  --report "$restore_root/hindsight-validation-recheck.json"
```

Use a separate Compose checkout and separate appdata directories for a full
restore drill. Never point the test stack at production bind mounts or publish
it on production ports.

## Disaster-Recovery Sequence

Prefer a daily logical snapshot for portable recovery. Use a weekly raw
Hindsight checkpoint only when logical import is unavailable or an exact
database-level rollback is required.

1. Restore the selected Restic snapshot to an isolated directory and run
   `restic check`.
2. Identify the payload directory with `metadata.json`; review its Git revision,
   timestamp, mode, and file hashes.
3. Prepare a fresh checkout at the recorded revision, run `setup.sh`, and verify
   rootless Docker and Compose configuration without starting production work.
4. Restore deployment configuration and the Hermes archive.
5. Restore each profile's online-exported SQLite `state.db` after its profile
   directory exists.
6. Restore Headroom and Firecrawl Postgres.
7. Start dependencies and restore Hindsight through the validated logical
   import. Use the raw checkpoint only as the whole-state alternative.
8. Validate profiles, active profile, vault, cron, integrated URLs, banks, and
   sidecar health before enabling timers or external access.

### Applying A Daily Snapshot

**Destructive recovery:** the following procedure replaces runtime data. Stop
the stack and create an independent timestamped copy or a newer Restic snapshot
of every current destination before proceeding. Examples assume the payload
directory found in the isolated restore is stored in `payload`:

```bash
payload=/path/inside/restore-root/to/daily-staging-directory
test -f "$payload/metadata.json"
test -f "$payload/hermes-data.tar.gz"
python3 -m json.tool "$payload/metadata.json"

docker compose --env-file .env down --remove-orphans
```

Restore configuration only after reviewing differences, especially bind hosts,
UID/GID, socket paths, and provider endpoints:

```bash
diff -u .env "$payload/compose.env" || true
diff -u web-search/searxng-settings.yml "$payload/searxng-settings.yml" || true
```

When those files are appropriate for this host, copy them deliberately. Then
extract Hermes through a one-off container so rootless ownership is preserved:

```bash
cp "$payload/compose.env" .env
cp "$payload/searxng-settings.yml" web-search/searxng-settings.yml
docker compose --env-file .env run --rm --no-deps -T --entrypoint tar hermes \
  -C /opt/data -xzf - < "$payload/hermes-data.tar.gz"
```

Restore each profile SQLite export separately after checking its profile name:

```bash
profile=<profile>
test -f "$payload/hermes-profile-databases/$profile/state.db"
docker compose --env-file .env run --rm --no-deps -T --entrypoint sh hermes \
  -c 'mkdir -p "/opt/data/profiles/$1"; cat > "/opt/data/profiles/$1/state.db"' \
  sh "$profile" < "$payload/hermes-profile-databases/$profile/state.db"
```

Restore Headroom, then start Firecrawl Postgres and load its logical dump:

```bash
docker compose --env-file .env run --rm --no-deps -T --entrypoint tar headroom-proxy \
  -C /home/nonroot -xzf - < "$payload/headroom-data.tar.gz"

docker compose --env-file .env up -d firecrawl-nuq-postgres
docker compose --env-file .env exec -T firecrawl-nuq-postgres sh -lc \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < "$payload/firecrawl-postgres.sql"
```

The SQL import expects a fresh target database. If objects already exist, stop
and rebuild the isolated target rather than dropping production tables in
place.

Start Hindsight with an empty data directory, validate the logical export, then
use the dry-run, pilot, and all-bank process documented above:

```bash
docker compose --env-file .env up -d hindsight-mcp
python3 scripts/validate-hindsight-bank-backup.py \
  --backup-dir "$payload/hindsight-logical"
python3 scripts/restore-hindsight-bank-backup.py \
  --backup-dir "$payload/hindsight-logical" \
  --api-url http://127.0.0.1:8888
```

### Applying A Raw Hindsight Checkpoint

**Destructive whole-state restore:** do not combine this with logical Hindsight
import. This replaces all current Hindsight banks and requires the checkpoint's
compatible Hindsight image/configuration. Preserve current `appdata/hindsight`
outside the destination first:

```bash
payload=/path/inside/restore-root/to/weekly-raw-staging-directory
test -f "$payload/hindsight-raw.tar.gz"

docker compose --env-file .env stop hindsight-mcp
stamp=$(date +%Y%m%dT%H%M%S)
mv appdata/hindsight "appdata/hindsight.before-raw-restore-$stamp"
mkdir -p appdata/hindsight
docker compose --env-file .env run --rm --no-deps -T --entrypoint tar hindsight-mcp \
  -C /home/hindsight -xzf - < "$payload/hindsight-raw.tar.gz"
docker compose --env-file .env up -d hindsight-mcp
curl -fsS http://127.0.0.1:8888/health
curl -fsS http://127.0.0.1:8888/v1/default/banks | python3 -m json.tool
```

Keep `appdata/hindsight.before-raw-restore-*` until bank counts, memory
retrieval, consolidation connectivity, and application behavior are accepted.
Do not delete current appdata, migration backups, failed backup staging, or
pre-restore Hindsight snapshots merely to make a restore command succeed.

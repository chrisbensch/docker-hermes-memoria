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
container is expected to sleep until Hermes starts its stdio MCP command. The
proxy readiness check above validates the HTTP proxy, not MCP transport.

```bash
docker compose --env-file .env ps headroom-mcp
```

Do not replace the stdio transport with the proxy URL. See the Headroom MCP
procedure below for the canonical profile-aware test.

## Headroom MCP Stdio And Socket Access

Headroom MCP is not an HTTP service. Hermes starts `headroom mcp serve` over
stdio with `docker exec -i` in the intentionally sleeping
`hermes-headroom-mcp` container. The Hermes service already mounts the rootless
socket selected by `DOCKER_SOCK`; adding `/var/run/docker.sock` again can target
the wrong daemon and grants no missing capability.

The image creates `hostdocker` dynamically from the mounted socket GID. Profile
configuration invokes `sg hostdocker -c` so MCP subprocesses reacquire that
group even when an agent-session or cron path has dropped supplementary groups.
Do not put a host, subordinate, or container socket GID in Compose or profile
configuration. The `headroom-proxy` service at port 8787 supports proxy and
statistics APIs, but it is not an HTTP MCP endpoint.

Use Hermes' profile-aware client test as the canonical check, replacing
`<profile>` with the actual profile name:

```bash
docker compose --env-file .env exec -T hermes \
  /package/admin/s6/command/s6-setuidgid hermes \
  hermes -p <profile> mcp test headroom
```

A successful result connects and discovers `headroom_compress`,
`headroom_retrieve`, and `headroom_stats`. For lower-level socket confirmation,
explicitly reacquire the group:

```bash
docker compose --env-file .env exec -T -u 1000:1000 hermes \
  sg hostdocker -c 'docker version >/dev/null'
```

Do not use a bare `docker compose exec -u 1000:1000 hermes docker ...` result as
proof that the configured MCP path is broken. The `-u` execution path can omit
supplementary groups and create the same false socket failure that
`sg hostdocker` is designed to prevent.

When a profile fails to register Headroom tools, inspect its MCP stderr log:

```bash
profile=<profile>
tail -n 200 "appdata/hermes/profiles/$profile/logs/mcp-stderr.log"
```

Look for new `Connection closed` or Docker socket errors after the latest
Hermes restart. Also verify that the profile block uses `command: sg`, followed
by `hostdocker`, `-c`, and the expected `exec docker exec -i` command.

### Update Existing Profiles

The updater runs through the Hermes container so it can read permission-mapped
profile files. Preview all recognized profile configs before writing:

```bash
python3 scripts/fix-headroom-mcp-command.py --dry-run
python3 scripts/fix-headroom-mcp-command.py
```

Limit either operation with repeatable profile selectors:

```bash
python3 scripts/fix-headroom-mcp-command.py --dry-run --profile maestro
python3 scripts/fix-headroom-mcp-command.py --profile maestro
```

Each changed file receives an adjacent UTC-stamped backup named
`config.yaml.headroom-mcp-backup-<UTC>`. Already-correct files are unchanged,
and custom, malformed, or ambiguous Headroom blocks are refused rather than
overwritten. After applying changes, restart Hermes and rerun the canonical MCP
test. To roll back, stop Hermes, restore the appropriate adjacent backup over
`config.yaml`, restart Hermes, and test the same profile again.

## Dashboard Authentication

The dashboard is local-only by default. Before setting
`HERMES_DASHBOARD_BIND_HOST=0.0.0.0`, configure basic authentication in
`appdata/hermes/config.yaml`.

Generate a password hash with the exact Hermes image used by the stack. The
password is read without echo and passed through the container environment so
it is not embedded in shell history:

```bash
read -rsp 'New dashboard password: ' DASH_PASSWORD
printf '\n'
export DASH_PASSWORD
dashboard_hash=$(docker compose --env-file .env exec -T -e DASH_PASSWORD \
  hermes-dashboard python -c \
  'import os; from plugins.dashboard_auth.basic import hash_password; print(hash_password(os.environ["DASH_PASSWORD"]))')
unset DASH_PASSWORD
printf 'password_hash: "%s"\n' "$dashboard_hash"
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

Before testing HTTP login, verify that the password matches the hash visible
inside the recreated dashboard container:

```bash
read -rsp 'Dashboard password to verify: ' DASH_PASSWORD
printf '\n'
export DASH_PASSWORD
docker compose --env-file .env exec -T -e DASH_PASSWORD hermes-dashboard \
  python - <<'PY'
import os
from hermes_cli.config import cfg_get, load_config
from plugins.dashboard_auth.basic import _verify_password

encoded = cfg_get(load_config(), "dashboard", "basic_auth", "password_hash")
print("MATCH" if _verify_password(os.environ["DASH_PASSWORD"], encoded) else "NO MATCH")
PY
unset DASH_PASSWORD
```

The expected output is `MATCH`. Then test the dashboard's JSON password-login
endpoint. An unauthenticated protected request should redirect to login or
return `401`; successful login returns HTTP `200`, JSON containing
`{"ok":true}`, and session cookies:

```bash
cookie_jar=$(mktemp)
login_response=$(mktemp)
trap 'rm -f "$cookie_jar" "$login_response"; unset DASH_PASSWORD' EXIT
unauthenticated_http=$(curl -sS -o /dev/null -w '%{http_code}' \
  http://127.0.0.1:9119/)
case $unauthenticated_http in
  301|302|303|307|308|401) ;;
  *) printf 'Authentication gate is not active: HTTP %s\n' \
       "$unauthenticated_http" >&2; exit 1 ;;
esac
printf 'unauthenticated: HTTP %s\n' "$unauthenticated_http"

read -rsp 'Dashboard password to test: ' DASH_PASSWORD
printf '\n'
export DASH_PASSWORD
login_http=$(python3 - <<'PY' | curl -sS -o "$login_response" \
  -w 'login: HTTP %{http_code}\n' \
  -c "$cookie_jar" \
  -H 'content-type: application/json' \
  --data-binary @- \
  http://127.0.0.1:9119/auth/password-login
import json
import os

print(json.dumps({
    "provider": "basic",
    "username": "admin",
    "password": os.environ["DASH_PASSWORD"],
    "next": "/",
}))
PY
)
unset DASH_PASSWORD
test "$login_http" = 'login: HTTP 200'
python3 -m json.tool "$login_response"
python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["ok"] is True' \
  "$login_response"
authenticated_http=$(curl -sS -o /dev/null -w '%{http_code}' \
  -b "$cookie_jar" http://127.0.0.1:9119/)
test "$authenticated_http" = 200
printf 'authenticated: HTTP %s\n' "$authenticated_http"
rm -f "$cookie_jar" "$login_response"
trap - EXIT
```

Use `http://<server-ip>:9119/login?next=%2F` from a remote browser. The explicit
login URL avoids the OAuth-first redirect used by the dashboard root. If valid
credentials still return `401`, confirm the hash is in the base
`appdata/hermes/config.yaml`, not only a profile config, and confirm the
dashboard container was recreated after the edit.

### Trusted Remote UI Access

The default loopback binds are safest. To expose selected interfaces on a
trusted LAN or private overlay, set only the required values in `.env`:

```bash
HERMES_DASHBOARD_BIND_HOST=0.0.0.0
HINDSIGHT_UI_BIND_HOST=0.0.0.0

# This port is an LLM proxy as well as a statistics interface.
HEADROOM_PROXY_BIND_HOST=0.0.0.0
```

Recreate the affected services and use the server address rather than
`127.0.0.1`:

```bash
docker compose --env-file .env up -d --force-recreate \
  hermes-dashboard hindsight-mcp headroom-proxy
```

```text
Hermes Dashboard:        http://<server-ip>:9119/login?next=%2F
Hindsight Control Plane: http://<server-ip>:9999
Headroom stats:          http://<server-ip>:8787/stats
Headroom history:        http://<server-ip>:8787/stats-history
```

Do not expose Hindsight or Headroom directly to an untrusted network. Prefer an
SSH or Tailscale tunnel when broader bind addresses are unnecessary.

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
`http://hindsight-mcp:8888/mcp/hermes-<profile>/` and the group-reacquiring
Headroom stdio command:

```bash
grep -R -n -E 'hindsight-mcp:8888|command:.*sg|hostdocker|headroom mcp serve' \
  appdata/hermes/profiles/*/config.yaml
```

For copied profiles that still invoke Docker directly, use the dry-run and
apply workflow in [Headroom MCP Stdio And Socket Access](#headroom-mcp-stdio-and-socket-access).

### Memory Vault And Cron

Confirm that the shared vault, Obsidian metadata, consolidation notes, and
profile indexes survived migration:

```bash
test -d appdata/hermes/obsidian-memory-vault
find appdata/hermes/obsidian-memory-vault -maxdepth 2 -type d -print | sort
find appdata/hermes/obsidian-memory-vault -type f | wc -l
du -sh appdata/hermes/obsidian-memory-vault
```

### Obsidian Vault Permissions

The shared vault is intentionally writable from both sides of the rootless
bind mount. Inside the container its ownership is `hermes:root`. Container
`hermes` maps to a dynamically assigned subordinate host UID, while container
group `root` maps to the deployment user's host group. Directories are setgid
so new entries inherit that group. Named and default POSIX ACLs keep the mapped
Hermes UID and owning group writable even when Hermes creates files with umask
`0022`.

Install the Ubuntu ACL tools once on the host:

```bash
command -v setfacl >/dev/null || sudo apt-get install -y acl
```

Resolve the configured host path and inspect only its metadata. Numeric owners
that differ between host and container are expected:

```bash
appdata_value=$(sed -n 's/^APPDATA_DIR=//p' .env | tail -n 1)
appdata_value=${appdata_value:-./appdata}
case $appdata_value in
  /*) appdata_host=$appdata_value ;;
  *) appdata_host=$PWD/$appdata_value ;;
esac
vault_host=$appdata_host/hermes/obsidian-memory-vault

test -d "$vault_host"
stat -c 'host: %u:%g %a %n' "$vault_host"
getfacl -ncp "$vault_host"
docker compose --env-file .env exec -T hermes \
  stat -c 'container: %u:%g %a %n' /opt/data/obsidian-memory-vault
```

Test an unprivileged Hermes create/delete without printing vault contents:

```bash
hermes_uid=$(sed -n 's/^HERMES_UID=//p' .env | tail -n 1)
test -n "$hermes_uid"
docker compose --env-file .env exec -T -u "$hermes_uid:$hermes_uid" hermes \
  sh -c 'umask 0022; f=/opt/data/obsidian-memory-vault/.permission-diagnosis-$$; : > "$f" && rm -f "$f"'
```

If either identity cannot write, apply the guarded repair from the repository
root. It derives the mapped Hermes UID, applies recursive access ACLs plus
default directory ACLs, restores `hermes:root` in-container ownership, and
verifies cross-writes in both directions:

```bash
./scripts/fix-obsidian-vault-permissions.sh
```

Expected output includes both `Host deployment-user write: ok` and
`Container Hermes write: ok`. Verify host access independently:

```bash
host_test=$vault_host/.permission-host-diagnosis-$$
trap 'rm -f "$host_test"' EXIT
(umask 0022 && : > "$host_test")
rm -f "$host_test"
trap - EXIT
```

Do **not** run
`sudo chown -R hermes:hermes /opt/data/obsidian-memory-vault`. `/opt/data/...`
is a container path, the host may have no `hermes` account, and guessed host
ownership breaks rootless user-namespace mappings. The helper is also called
automatically after setup scaffolding and applied migration, and runs last in
`scripts/normalize-appdata-permissions.sh`.

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

**Potentially destructive:** migration replaces some individual destination
files and merges directory contents. Individual paths handled by the script's
replacement helper are moved into timestamped
`appdata/hermes/migration-backups/`, but same-name files inside merged vault,
cron, script, memory, and similar directories may be overwritten without first
being copied there. Create an independent backup before applying. If the stack
is operational, run:

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

The applied migration invokes the vault permission helper after copying profile,
vault, cron, and active-profile state; `--dry-run` reports that operation without
changing metadata. Start the stack, normalize general appdata access and the
shared vault policy through the containers, then repeat the profile, vault,
cron, integrated URL, and bank checks above:

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
`tmp/hindsight-target-pre-restore-*` directory. Because Hindsight remains live
during this script-created archive, treat it as a best-effort diagnostic copy,
not a consistent rollback checkpoint. Create a quiesced weekly raw backup or
another independently verified checkpoint before `--apply`, and preserve both
until the restored system is accepted.

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

Before requesting consolidation, inspect the configured provider. A blank
explicit base URL is valid for OpenAI and DeepSeek, whose known provider
defaults are selected below. LM Studio and other custom OpenAI-compatible
providers must have a nonempty URL. The check performs an authenticated
`/models` request from inside Hindsight without printing the API key:

```bash
grep -E '^HINDSIGHT_API_LLM_(PROVIDER|MODEL|BASE_URL)=' .env
docker compose --env-file .env exec -T hindsight-mcp python - <<'PY'
import os
import urllib.request
from urllib.parse import urlparse

provider = os.environ.get("HINDSIGHT_API_LLM_PROVIDER", "openai").lower()
base_url = os.environ.get("HINDSIGHT_API_LLM_BASE_URL", "").strip()
if not base_url:
    defaults = {
        "openai": "https://api.openai.com/v1",
        "deepseek": "https://api.deepseek.com/v1",
    }
    base_url = defaults.get(provider, "")
if not base_url:
    raise SystemExit(f"{provider} requires an explicit base URL for this check")

headers = {}
api_key = os.environ.get("HINDSIGHT_API_LLM_API_KEY", "").strip()
if api_key:
    headers["Authorization"] = f"Bearer {api_key}"
request = urllib.request.Request(base_url.rstrip("/") + "/models", headers=headers)
with urllib.request.urlopen(request, timeout=15) as response:
    print(f"LLM endpoint reachable: HTTP {response.status} ({urlparse(base_url).hostname})")
PY
docker compose --env-file .env logs --tail=300 hindsight-mcp | \
  grep -i -E 'consolidat|error|timeout|connection' || true
```

A failed required container connection must be corrected before requeuing
consolidation. Do not treat a host-only request as proof that the container
network path works.

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
case $(stat -c '%a' "$config") in
  400|600) ;;
  *) printf 'Unsafe Restic config mode\n' >&2; exit 1 ;;
esac
case $(stat -c '%a' "$RESTIC_PASSWORD_FILE") in
  400|600) ;;
  *) printf 'Unsafe Restic password mode\n' >&2; exit 1 ;;
esac
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

Use the snapshot configuration as a comparison source, especially for bind
hosts, UID/GID, socket paths, and provider endpoints:

```bash
diff -u .env "$payload/compose.env" || true
diff -u web-search/searxng-settings.yml "$payload/searxng-settings.yml" || true
```

Do not copy these files wholesale onto a different host. Merge only the values
that remain appropriate and preserve this host's rootless socket, UID/GID,
paths, bind addresses, and generated secrets.

Resolve the effective appdata path, move the entire current tree aside, and
create an empty destination. This prevents removed files and database objects
from surviving into a hybrid restore:

```bash
appdata_value=$(awk -F= '$1 == "APPDATA_DIR" {print substr($0, length($1) + 2)}' .env)
appdata_value=${appdata_value:-./appdata}
case $appdata_value in
  /*) appdata_host=$appdata_value ;;
  *) appdata_host=$(realpath -m "$PWD/$appdata_value") ;;
esac
stamp=$(date +%Y%m%dT%H%M%S)
test -d "$appdata_host"
case $appdata_host in
  /|"$PWD") printf 'Refusing unsafe APPDATA_DIR: %s\n' "$appdata_host" >&2; exit 1 ;;
esac
test -d "$appdata_host/hermes"
test -d "$appdata_host/hindsight"
appdata_previous="${appdata_host}.before-restore-$stamp"
test ! -e "$appdata_previous"
mv "$appdata_host" "$appdata_previous"
mkdir -p "$appdata_host"
printf 'Previous appdata: %s\n' "$appdata_previous"
```

Extract Hermes through a one-off container so archive ownership is interpreted
inside the rootless user namespace:

```bash
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

Because the complete appdata tree was moved aside, Firecrawl initializes a
fresh target database before this import. If PostgreSQL reports existing-object
collisions, stop: the target is not empty, and dropping objects in place is not
an acceptable shortcut.

Prepare the empty Hindsight directory with the same container-side ownership
step used by setup, then start it, validate the logical export, and use the
dry-run, pilot, and all-bank process documented above:

```bash
mkdir -p "$appdata_host/hindsight"
hindsight_image=$(awk -F= '$1 == "HINDSIGHT_IMAGE" {print substr($0, length($1) + 2)}' .env)
hindsight_image=${hindsight_image:-ghcr.io/vectorize-io/hindsight:latest}
docker run --rm --user 0:0 \
  -v "$appdata_host/hindsight:/mnt" \
  --entrypoint sh "$hindsight_image" \
  -c 'chown 1000:1000 /mnt'
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
appdata_value=$(awk -F= '$1 == "APPDATA_DIR" {print substr($0, length($1) + 2)}' .env)
appdata_value=${appdata_value:-./appdata}
case $appdata_value in
  /*) appdata_host=$appdata_value ;;
  *) appdata_host=$(realpath -m "$PWD/$appdata_value") ;;
esac
stamp=$(date +%Y%m%dT%H%M%S)
case $appdata_host in
  /|"$PWD") printf 'Refusing unsafe APPDATA_DIR: %s\n' "$appdata_host" >&2; exit 1 ;;
esac
test -d "$appdata_host/hermes"
test -d "$appdata_host/hindsight"
hindsight_previous="$appdata_host/hindsight.before-raw-restore-$stamp"
test ! -e "$hindsight_previous"
mv "$appdata_host/hindsight" "$hindsight_previous"
mkdir -p "$appdata_host/hindsight"
hindsight_image=$(awk -F= '$1 == "HINDSIGHT_IMAGE" {print substr($0, length($1) + 2)}' .env)
hindsight_image=${hindsight_image:-ghcr.io/vectorize-io/hindsight:latest}
docker run --rm --user 0:0 \
  -v "$appdata_host/hindsight:/mnt" \
  --entrypoint sh "$hindsight_image" \
  -c 'chown 1000:1000 /mnt'
docker compose --env-file .env run --rm --no-deps -T --entrypoint tar hindsight-mcp \
  -C /home/hindsight -xzf - < "$payload/hindsight-raw.tar.gz"
docker compose --env-file .env up -d hindsight-mcp
curl -fsS http://127.0.0.1:8888/health
curl -fsS http://127.0.0.1:8888/v1/default/banks | python3 -m json.tool
```

Keep `$appdata_host/hindsight.before-raw-restore-*` until bank counts, memory
retrieval, consolidation connectivity, and application behavior are accepted.
Do not delete current appdata, migration backups, failed backup staging, or
pre-restore Hindsight snapshots merely to make a restore command succeed.

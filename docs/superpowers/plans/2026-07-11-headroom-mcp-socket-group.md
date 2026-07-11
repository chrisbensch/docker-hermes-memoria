# Headroom MCP Socket Group Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Headroom stdio MCP reliable in agent sessions and cron jobs by reacquiring the dynamically created `hostdocker` group before `docker exec`.

**Architecture:** Update tracked profile templates to launch Headroom through `sg hostdocker -c`. Add a Python YAML updater that executes inside the Hermes container for existing permission-protected profiles, creates adjacent timestamped backups, and refuses custom commands; deploy only after a fresh Restic snapshot.

**Tech Stack:** Python 3 standard library, PyYAML inside Hermes, POSIX shell, rootless Docker Compose, `unittest`, Markdown.

## Global Constraints

- Keep the existing rootless socket mount; do not mount host `/var/run/docker.sock`.
- Do not hard-code the socket GID or add Compose `group_add` values.
- Keep `hermes-headroom-mcp` sleeping until stdio `docker exec` starts it.
- Keep `HEADROOM_PROXY_URL=http://headroom-proxy:8787` and stdio transport.
- Parse YAML structurally and preserve unrelated configuration values.
- Back up every changed live config before writing.
- Refuse custom or ambiguous Headroom MCP blocks.
- Run a fresh daily logical Restic backup before live profile edits.

---

### Task 1: Add The Tested Existing-Profile Updater

**Files:**
- Create: `scripts/fix-headroom-mcp-command.py`
- Create: `tests/test_headroom_mcp_command.py`

**Interfaces:**
- Consumes: `--dry-run`, repeatable `--profile`, and hidden/internal `--inside-data-dir` arguments.
- Produces: changed/already-correct/skipped/failed profile reports and adjacent `config.yaml.headroom-mcp-backup-<UTC>` files.

- [ ] **Step 1: Write updater unit tests**

Cover these exact cases with temporary directories:

```python
def test_old_docker_command_is_rewritten_with_backup(): ...
def test_dry_run_does_not_write_or_backup(): ...
def test_new_sg_command_is_idempotent(): ...
def test_custom_headroom_command_is_refused(): ...
def test_selected_profiles_only(): ...
def test_missing_headroom_block_is_skipped(): ...
```

Expected new block:

```python
{
    "command": "sg",
    "args": [
        "hostdocker",
        "-c",
        "exec docker exec -i -e HEADROOM_PROXY_URL=http://headroom-proxy:8787 "
        "hermes-headroom-mcp headroom mcp serve",
    ],
    "enabled": True,
    "timeout": 120,
}
```

- [ ] **Step 2: Run tests and confirm failure**

Run:

```bash
python3 -m unittest tests.test_headroom_mcp_command -v
```

Expected: import failure because the updater does not exist.

- [ ] **Step 3: Implement pure YAML transformation functions**

Implement constants for the exact old and new blocks plus functions that load,
classify, transform, back up, and write one config. Preserve all unrelated
mapping keys and preserve existing `enabled`/`timeout` values when converting a
recognized old block.

- [ ] **Step 4: Implement container execution**

Normal host mode reads the repository `.env`, then invokes:

```bash
docker compose --env-file .env exec -T hermes \
  python - --inside-data-dir /opt/data
```

Feed the updater's own source on stdin and forward `--dry-run` and selected
profiles. Internal mode scans `/opt/data/profiles/*/config.yaml` plus
`/opt/data/config.yaml` when it contains Headroom configuration. It must print
paths and statuses without printing YAML content or secrets.

- [ ] **Step 5: Implement failure and backup behavior**

Use UTC timestamps, `shutil.copy2`, atomic temporary-file replacement, and
nonzero exit status when any selected config is custom, malformed, or fails.
Dry-run performs no write or backup. Existing new blocks remain unchanged.

- [ ] **Step 6: Validate and commit**

Run:

```bash
python3 -m unittest tests.test_headroom_mcp_command -v
python3 -m unittest discover -s tests -v
python3 -m py_compile scripts/fix-headroom-mcp-command.py
git diff --check
```

Commit:

```bash
git add scripts/fix-headroom-mcp-command.py tests/test_headroom_mcp_command.py
git commit -m "Add Headroom MCP command updater"
```

### Task 2: Update Templates And Static Validation

**Files:**
- Modify: `hermes-data/profile-templates/rootless/config.yaml`
- Modify: `hermes-config-fragment.yaml`
- Modify: `tests/test_backup_scripts.sh`

**Interfaces:**
- Consumes: selected command shape from Task 1.
- Produces: fixed configuration for every future rootless profile.

- [ ] **Step 1: Add failing static assertions**

Require both YAML files to contain `command: sg`, `hostdocker`, and the exact
`exec docker exec -i` command. Reject a Headroom block whose command is direct
`docker`.

- [ ] **Step 2: Update both tracked YAML blocks**

Use:

```yaml
command: "sg"
args:
  - "hostdocker"
  - "-c"
  - "exec docker exec -i -e HEADROOM_PROXY_URL=http://headroom-proxy:8787 hermes-headroom-mcp headroom mcp serve"
enabled: true
timeout: 120
```

- [ ] **Step 3: Validate and commit**

Run:

```bash
bash tests/test_backup_scripts.sh
python3 - <<'PY'
import yaml
for path in ["hermes-data/profile-templates/rootless/config.yaml", "hermes-config-fragment.yaml"]:
    yaml.safe_load(open(path))
PY
git diff --check
```

Commit:

```bash
git add hermes-data/profile-templates/rootless/config.yaml \
  hermes-config-fragment.yaml tests/test_backup_scripts.sh
git commit -m "Reacquire Docker group for Headroom MCP"
```

### Task 3: Document Diagnostics And Migration

**Files:**
- Modify: `AGENTS.md`
- Modify: `README.md`
- Modify: `QUICKSTART.md`
- Modify: `OPERATIONS.md`
- Modify: `hermes-data/profile-templates/rootless/README.md`

**Interfaces:**
- Consumes: updater and template behavior from Tasks 1-2.
- Produces: accurate setup, migration, and troubleshooting guidance.

- [ ] **Step 1: Document architecture and unsafe alternatives**

State that the rootless socket is already mounted, the sleeping MCP container
is expected, the HTTP proxy is not an MCP endpoint, and mapped GIDs must not be
hard-coded.

- [ ] **Step 2: Document existing-profile migration**

Add dry-run/apply commands:

```bash
python3 scripts/fix-headroom-mcp-command.py --dry-run
python3 scripts/fix-headroom-mcp-command.py
```

Document adjacent backups and selected-profile use.

- [ ] **Step 3: Document canonical diagnostics**

Use:

```bash
docker compose --env-file .env exec -T hermes \
  /package/admin/s6/command/s6-setuidgid hermes \
  hermes -p <profile> mcp test headroom
```

Explain why `docker compose exec -u 1000:1000` drops supplementary groups and
can produce a false failure unless the command itself uses `sg hostdocker`.

- [ ] **Step 4: Validate and commit**

Run link checks, `rg` for `sg hostdocker`, updater commands, and unsafe socket
recommendations, then `git diff --check`.

Commit:

```bash
git add AGENTS.md README.md QUICKSTART.md OPERATIONS.md \
  hermes-data/profile-templates/rootless/README.md
git commit -m "Document Headroom socket group handling"
```

### Task 4: Back Up And Update Live Profiles

**Files:**
- Deploy: `/home/sysadmin/docker-hermes-memoria`
- Modify through updater: `/opt/data/profiles/*/config.yaml`

**Interfaces:**
- Consumes: updater and committed templates.
- Produces: fixed live profiles with adjacent timestamped backups.

- [ ] **Step 1: Push and deploy repository changes**

```bash
git push origin main
ssh sysadmin@100.75.104.119 \
  'cd /home/sysadmin/docker-hermes-memoria && git pull --ff-only'
```

- [ ] **Step 2: Create a fresh logical backup**

```bash
./scripts/backup-hermes-data.sh --mode daily
set -a
source ~/.config/hermes-backup/restic.env
set +a
restic snapshots --tag daily --latest 1
restic check
```

- [ ] **Step 3: Dry-run all live profiles**

```bash
python3 scripts/fix-headroom-mcp-command.py --dry-run
```

Expected: standard profiles are `would-change`, already migrated profiles are
`already-correct`, and no custom or malformed block is reported.

- [ ] **Step 4: Apply and verify backups**

```bash
python3 scripts/fix-headroom-mcp-command.py
```

Confirm every changed config has one adjacent timestamped backup and `maestro`
uses `command: sg` with `hostdocker`.

- [ ] **Step 5: Restart Hermes and run canonical MCP tests**

```bash
docker compose --env-file .env restart hermes
docker compose --env-file .env exec -T hermes \
  /package/admin/s6/command/s6-setuidgid hermes \
  hermes -p maestro mcp test headroom
```

Expected: connected and three tools discovered.

- [ ] **Step 6: Verify fresh agent-session behavior**

Start a new `maestro` session, confirm all three `mcp__headroom__*` tools are
registered, call `headroom_stats`, and confirm no new Headroom `Connection
closed` entry after the restart timestamp.

- [ ] **Step 7: Run full validation**

```bash
bash tests/test_backup_scripts.sh
python3 -m unittest discover -s tests -v
bash -n setup.sh scripts/*.sh reset.sh
docker compose --env-file .env config --quiet
git status --short --branch
```

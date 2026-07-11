# Obsidian Vault Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the shared Obsidian vault writable by both container Hermes and the host deployment user now and in every future setup or migration.

**Architecture:** Add one guarded rootless-container helper that owns the vault permission policy. Setup, migration, and general appdata normalization call that helper so ownership logic is not duplicated; live remediation runs only after a verified Restic snapshot.

**Tech Stack:** POSIX shell, rootless Docker, Docker Compose, Bash static tests, Markdown, Restic.

## Global Constraints

- Never run host `sudo chown` against `/opt/data` or rootless subordinate IDs.
- Inside the container, vault ownership is `hermes:root`.
- Directories are user/group writable, setgid, and inaccessible to others.
- Files are user/group writable, preserve existing user/group execute bits, and are inaccessible to others.
- Resolve `APPDATA_DIR`; never assume `./appdata` when an override exists.
- Refuse `/`, the repository root, the Hermes data root, and paths whose basename is not `obsidian-memory-vault`.
- Do not move, delete, or rewrite vault contents.
- Run a verified daily logical Restic backup before live ownership changes.

---

### Task 1: Add The Guarded Vault Permission Helper

**Files:**
- Create: `scripts/fix-obsidian-vault-permissions.sh`
- Modify: `tests/test_backup_scripts.sh`

**Interfaces:**
- Consumes: `.env` values `APPDATA_DIR`, `HERMES_IMAGE`, and `HERMES_UID`; optional `HERMES_DATA_DIR`, `HERMES_OBSIDIAN_VAULT_DIR`, and `DOCKER_HOST` environment overrides.
- Produces: normalized vault metadata and successful host/container write verification.

- [ ] **Step 1: Add static expectations before the helper exists**

Extend `tests/test_backup_scripts.sh` to require:

```bash
vault_script=scripts/fix-obsidian-vault-permissions.sh
bash -n "$vault_script"
grep -Fq 'obsidian-memory-vault' "$vault_script"
grep -Fq 'chown -R "$hermes_uid":0' "$vault_script"
grep -Fq 'chmod u+rwx,g+rwx,o-rwx,g+s' "$vault_script"
grep -Fq 'chmod u+rw,g+rw,o-rwx' "$vault_script"
grep -Fq 'Container Hermes write: ok' "$vault_script"
grep -Fq 'Host deployment-user write: ok' "$vault_script"
```

- [ ] **Step 2: Run the test and confirm it fails**

Run:

```bash
bash tests/test_backup_scripts.sh
```

Expected: failure because `scripts/fix-obsidian-vault-permissions.sh` does not exist.

- [ ] **Step 3: Implement guarded path resolution**

Create a POSIX shell script using `#!/usr/bin/env sh` and `set -eu`. Resolve the repository root, read values from `.env` without sourcing it, resolve relative paths against the repository root, and reject unsafe targets before Docker runs. The final vault path must exist and end in `/obsidian-memory-vault`.

- [ ] **Step 4: Implement rootless ownership and mode normalization**

Run the configured Hermes image as container root with the vault bind-mounted at `/mnt`. Inside that one-off container:

```sh
chown -R "$hermes_uid":0 /mnt
find /mnt -type d -exec chmod u+rwx,g+rwx,o-rwx,g+s {} +
find /mnt -type f -exec chmod u+rw,g+rw,o-rwx {} +
```

Use the configured numeric `HERMES_UID`, not a host subordinate UID. Preserve file execute bits by adding permissions instead of assigning a fixed mode.

- [ ] **Step 5: Add host and container-user verification**

Use unique temporary filenames below the vault. Verify create/write/delete as the host user, then run a second one-off container with `--user "$HERMES_UID:$HERMES_UID"` to verify create/write/delete at `/mnt`. Install a trap that removes any remaining verification files.

- [ ] **Step 6: Run tests and commit**

Run:

```bash
bash tests/test_backup_scripts.sh
bash -n scripts/fix-obsidian-vault-permissions.sh
git diff --check
```

Expected: all checks pass.

Commit:

```bash
git add scripts/fix-obsidian-vault-permissions.sh tests/test_backup_scripts.sh
git commit -m "Add Obsidian vault permission helper"
```

### Task 2: Integrate Setup, Migration, And Normalization

**Files:**
- Modify: `setup.sh`
- Modify: `scripts/migrate-host-hermes-data.sh`
- Modify: `scripts/normalize-appdata-permissions.sh`
- Modify: `tests/test_backup_scripts.sh`

**Interfaces:**
- Consumes: helper from Task 1.
- Produces: automatic permission normalization after future vault scaffolding and migration.

- [ ] **Step 1: Add failing integration assertions**

Require each integration point in `tests/test_backup_scripts.sh`:

```bash
grep -Fq 'fix-obsidian-vault-permissions.sh' setup.sh
grep -Fq 'fix-obsidian-vault-permissions.sh' scripts/migrate-host-hermes-data.sh
grep -Fq 'fix-obsidian-vault-permissions.sh' scripts/normalize-appdata-permissions.sh
grep -Fq '[dry-run] fix Obsidian vault permissions' scripts/migrate-host-hermes-data.sh
```

- [ ] **Step 2: Run the test and confirm integration assertions fail**

Run `bash tests/test_backup_scripts.sh`.

Expected: the helper exists, but setup/migration/normalization assertions fail.

- [ ] **Step 3: Integrate setup after profile scaffolding**

At the end of `setup.sh`, after `create-profile.sh` has written vault seed files, invoke the helper with explicit values already calculated by setup:

```sh
HERMES_DATA_DIR="$data_dir" \
HERMES_OBSIDIAN_VAULT_DIR="$obsidian_vault_dir" \
HERMES_IMAGE="$image_name" \
HERMES_UID="$uid_value" \
  "$script_dir/scripts/fix-obsidian-vault-permissions.sh"
```

- [ ] **Step 4: Integrate migration with dry-run handling**

After all profiles, the vault, cron data, and active-profile state are migrated, print the intended operation during `--dry-run`; otherwise invoke the helper with `HERMES_DATA_DIR`, `HERMES_OBSIDIAN_VAULT_DIR`, and values resolved from `.env`. A real apply must fail if normalization fails.

- [ ] **Step 5: Integrate general normalization last**

After existing Hermes and Hindsight read-access normalization, invoke the helper so its write-sharing policy wins for the vault. Resolve the helper relative to the script directory and preserve current container override behavior.

- [ ] **Step 6: Validate and commit**

Run:

```bash
bash tests/test_backup_scripts.sh
bash -n setup.sh scripts/*.sh
python3 -m unittest discover -s tests -v
git diff --check
```

Expected: all checks pass.

Commit:

```bash
git add setup.sh scripts/migrate-host-hermes-data.sh \
  scripts/normalize-appdata-permissions.sh tests/test_backup_scripts.sh
git commit -m "Apply vault permissions during setup and migration"
```

### Task 3: Document The Shared Permission Model

**Files:**
- Modify: `AGENTS.md`
- Modify: `README.md`
- Modify: `QUICKSTART.md`
- Modify: `OPERATIONS.md`

**Interfaces:**
- Consumes: helper and integration behavior from Tasks 1-2.
- Produces: operator and contributor instructions that replace incorrect host `sudo chown` advice.

- [ ] **Step 1: Update contributor safety guidance**

Explain the `hermes:root` container ownership model, host group mapping, and prohibition on host `chown` to a guessed subordinate UID or nonexistent host `hermes` account.

- [ ] **Step 2: Update setup and architecture references**

Add the helper to the layout, state that setup applies permissions after vault scaffolding, and keep Quickstart's normalization command as the normal post-start operation.

- [ ] **Step 3: Add operational diagnosis and repair**

In `OPERATIONS.md`, document numeric ownership inspection, an unprivileged container write test, the helper invocation, expected results, and host write verification. Warn that `/opt/data/obsidian-memory-vault` is a container path and must not be passed to host `sudo chown`.

- [ ] **Step 4: Validate and commit**

Run:

```bash
rg -n "fix-obsidian-vault-permissions|hermes:root|sudo chown|obsidian-memory-vault" \
  AGENTS.md README.md QUICKSTART.md OPERATIONS.md
git diff --check
```

Expected: every guide points to the helper and the unsafe command is present only as a warning not to run it.

Commit:

```bash
git add AGENTS.md README.md QUICKSTART.md OPERATIONS.md
git commit -m "Document shared vault permissions"
```

### Task 4: Back Up, Deploy, And Repair The Current Server

**Files:**
- Deploy: repository changes to `/home/sysadmin/docker-hermes-memoria`
- Modify metadata only: effective `APPDATA_DIR/hermes/obsidian-memory-vault`

**Interfaces:**
- Consumes: committed helper and integrations.
- Produces: a writable current vault and verified future deployment behavior.

- [ ] **Step 1: Push and deploy code**

Run:

```bash
git push origin main
ssh sysadmin@100.75.104.119 \
  'cd /home/sysadmin/docker-hermes-memoria && git pull --ff-only'
```

- [ ] **Step 2: Capture pre-change evidence**

On the server, record the vault file count, total size, numeric top-level ownership, stack status, and latest Restic snapshot list. Do not print vault file contents.

- [ ] **Step 3: Create and verify a daily logical backup**

Run:

```bash
./scripts/backup-hermes-data.sh --mode daily
set -a
source ~/.config/hermes-backup/restic.env
set +a
restic snapshots --tag daily --latest 1
restic check
```

Expected: a new successful daily snapshot and no repository errors.

- [ ] **Step 4: Apply the helper**

Run:

```bash
./scripts/fix-obsidian-vault-permissions.sh
```

Expected: host and container Hermes write checks both report `ok`.

- [ ] **Step 5: Verify data and runtime health**

Confirm the vault file count is unchanged, host ownership maps to a subordinate owner plus the deployment user's group, the Hermes unprivileged UID can write, the host user can write, and Compose services remain healthy.

- [ ] **Step 6: Run full server validation**

Run:

```bash
bash tests/test_backup_scripts.sh
python3 -m unittest discover -s tests -v
bash -n setup.sh scripts/*.sh
docker compose --env-file .env config --quiet
git status --short --branch
```

Expected: all checks pass; only pre-existing ignored or untracked runtime files remain.

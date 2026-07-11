# Rootless Restic Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build daily online logical backups at 07:45 JST and weekly raw Hindsight checkpoints at Saturday 08:00 JST for the rootless Hermes Compose deployment.

**Architecture:** A Python Hindsight API exporter produces a complete validator-compatible document-transfer backup. A Bash wrapper stages container-readable data for Restic without changing rootless ownership. Persistent systemd user timers run daily logical and weekly raw workflows.

**Tech Stack:** Python standard library, Bash, Docker Compose, systemd user units, Restic 0.18.1.

## Global Constraints

- Use `/home/sysadmin/.config/hermes-backup/restic.env`; never log its values.
- Use rootless Docker through the deployment user's Compose socket.
- Do not read `appdata/hermes` directly from the host or change its ownership.
- Daily backup does not restart Hermes, dashboard, Headroom, Firecrawl, Redis, or RabbitMQ.
- Weekly raw backup stops and starts only `hindsight-mcp`.
- Daily scope excludes Redis, RabbitMQ, logs, caches, generic `tmp`, images, and Firecrawl source.
- Keep failed staging output; remove staging only after successful Restic completion.

---

### Task 1: Implement complete Hindsight logical export

**Files:**
- Create: `scripts/backup-hindsight-banks.py`
- Create: `tests/test_hindsight_backup.py`
- Modify: `tests/test_hindsight_bank_restore.py`

**Interfaces:**
- `export_backup(client, output_dir, backup_name) -> dict[str, Any]`
- CLI: `--api-url`, `--output-dir`, `--backup-name`, `--report`
- Output: `manifest.json` and `banks/<bank-id>/` accepted unchanged by `scripts/validate-hindsight-bank-backup.py`.

- [ ] **Step 1: Write a failing pagination and observation test**

Create a fake API client that returns 101 memory items over two pages and a document-transfer ZIP with `observations.json`.

```python
def test_export_paginates_and_preserves_observations(self):
    with tempfile.TemporaryDirectory() as temporary:
        report = self.backup.export_backup(self.client, Path(temporary), "backup")
    self.assertEqual(report["totals"]["memories"], 2)
    self.assertIn(
        ("GET", "/v1/default/banks/hermes-test/memories/list?limit=100&offset=100"),
        self.client.calls,
    )
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 -m unittest tests/test_hindsight_backup.py -v`

Expected: FAIL because `backup-hindsight-banks.py` does not exist.

- [ ] **Step 3: Add API and pagination helpers**

Implement `ApiClient.request_json()`, `ApiClient.request_bytes()`, and `fetch_all_items()`. Require each page to contain a list `items` and integer `total`; fail on an empty premature page or count mismatch.

```python
def fetch_all_items(client, path, page_size=100):
    offset, result = 0, []
    while True:
        page = client.request_json("GET", f"{path}?limit={page_size}&offset={offset}")
        items, total = page.get("items"), page.get("total")
        if not isinstance(items, list) or not isinstance(total, int):
            raise BackupError(f"Invalid paginated response for {path}")
        result.extend(items)
        if len(result) == total:
            return result
        if not items or len(result) > total:
            raise BackupError(f"Pagination mismatch for {path}")
        offset += len(items)
```

- [ ] **Step 4: Export each bank and build the manifest**

Preflight `/health` and `/version`; collect bank fact counts before export. Export bank config, paginated memories/entities/documents, directives, mental models, document details, and request:

```python
transfer_path = f"/v1/default/banks/{bank_id}/document-transfer?include_observations=true"
archive_bytes = client.request_bytes("GET", transfer_path)
archive_path.write_bytes(archive_bytes)
transfer = inspect_transfer_archive(archive_path, bank_id)
summary["sections"]["document-transfer.zip"] = {
    "sha256": hashlib.sha256(archive_bytes).hexdigest(),
    "documents": transfer["documents"],
    "facts": transfer["facts"],
    "observations": transfer["observations"],
}
```

List banks again after export; fail when any fact count changed. Call the existing `validate_backup()` before returning.

- [ ] **Step 5: Verify and commit**

Run:

```bash
python3 -m unittest tests/test_hindsight_backup.py tests/test_hindsight_bank_restore.py -v
python3 -m py_compile scripts/backup-hindsight-banks.py
git add scripts/backup-hindsight-banks.py tests/test_hindsight_backup.py tests/test_hindsight_bank_restore.py
git commit -m "Add complete Hindsight backup exporter"
```

### Task 2: Implement the rootless Restic staging wrapper

**Files:**
- Create: `scripts/backup-hermes-data.sh`
- Create: `tests/test_backup_scripts.sh`

**Interfaces:**
- CLI: `scripts/backup-hermes-data.sh --mode daily|weekly-raw`
- Config: `/home/sysadmin/.config/hermes-backup/restic.env`
- State root: `/home/sysadmin/.local/state/hermes-backup`
- Output: a tagged Restic snapshot and retained failure staging data.

- [ ] **Step 1: Write a failing shell contract test**

```bash
#!/usr/bin/env bash
set -euo pipefail
script=scripts/backup-hermes-data.sh
bash -n "$script"
grep -Fq "flock" "$script"
grep -Fq "backup-hindsight-banks.py" "$script"
grep -Fq "validate-hindsight-bank-backup.py" "$script"
! grep -Fq "restic backup appdata" "$script"
```

Run: `bash tests/test_backup_scripts.sh`

Expected: FAIL because the wrapper does not exist.

- [ ] **Step 2: Add secure configuration, locking, and staging**

Use `set -Eeuo pipefail`, `umask 077`, and `flock`. Reject a missing or too-permissive Restic env file. Source it only after validation and create a timestamped `0700` staging directory.

```bash
STATE_ROOT=/home/sysadmin/.local/state/hermes-backup
CONFIG_FILE=/home/sysadmin/.config/hermes-backup/restic.env
mkdir -p "$STATE_ROOT/staging"
exec 9>"$STATE_ROOT/backup.lock"
flock -n 9 || { printf "Backup already running.\n" >&2; exit 1; }
[[ -r "$CONFIG_FILE" ]] || { printf "Missing Restic configuration.\n" >&2; exit 1; }
set -a
source "$CONFIG_FILE"
set +a
```

- [ ] **Step 3: Stage daily data using running containers**

Use `docker compose --env-file .env exec -T hermes tar` to stream `/opt/data` to a sysadmin-owned archive. Exclude `logs`, `.cache`, `audio_cache`, `image_cache`, and `lazy-packages`. Copy the repository `.env` and SearXNG settings. Stage Headroom from its container and Firecrawl Postgres with `pg_dump`.

```bash
compose exec -T hermes tar   --exclude="./logs" --exclude="./.cache" --exclude="./audio_cache"   --exclude="./image_cache" --exclude="./lazy-packages"   -C /opt/data -czf - . > "$staging/hermes-data.tar.gz"
python3 scripts/backup-hindsight-banks.py   --api-url http://127.0.0.1:8888   --output-dir "$staging" --backup-name hindsight-logical
python3 scripts/validate-hindsight-bank-backup.py   --backup-dir "$staging/hindsight-logical"   --report "$staging/hindsight-validation.json"
```

- [ ] **Step 4: Add weekly raw Hindsight checkpoint**

For `weekly-raw`, stop only Hindsight, stream its raw database through a one-off Compose container, and always restart it from a trap.

```bash
raw_stopped=no
restart_hindsight() {
  [[ "$raw_stopped" == yes ]] && compose start hindsight-mcp
}
trap restart_hindsight EXIT
compose stop hindsight-mcp
raw_stopped=yes
compose run --rm --no-deps --entrypoint tar hindsight-mcp   -C /home/hindsight -czf - .pg0 > "$staging/hindsight-raw.tar.gz"
restart_hindsight
raw_stopped=no
trap - EXIT
```

- [ ] **Step 5: Upload, retain, test, and commit**

Tag daily backups with `hermes,daily,logical`; tag weekly with `hermes,weekly,raw`. Run retention only after a successful upload.

```bash
restic backup --tag hermes --tag "$mode" --tag "$kind" "$staging"
restic forget --prune --keep-daily 14 --keep-weekly 8 --keep-monthly 12
restic snapshots --tag hermes --latest 1
bash tests/test_backup_scripts.sh
git add scripts/backup-hermes-data.sh tests/test_backup_scripts.sh
git commit -m "Add rootless Restic backup wrapper"
```

### Task 3: Add persistent systemd user units

**Files:**
- Create: `systemd/hermes-backup.service`
- Create: `systemd/hermes-backup.timer`
- Create: `systemd/hermes-hindsight-raw-backup.service`
- Create: `systemd/hermes-hindsight-raw-backup.timer`
- Create: `scripts/install-backup-timers.sh`
- Modify: `tests/test_backup_scripts.sh`

**Interfaces:**
- Daily unit invokes `backup-hermes-data.sh --mode daily`.
- Weekly unit invokes `backup-hermes-data.sh --mode weekly-raw`.
- Installer copies templates into `~/.config/systemd/user`, reloads units, and enables timers.

- [ ] **Step 1: Extend the failing test with exact schedules**

```bash
grep -Fq "OnCalendar=*-*-* 07:45:00 Asia/Tokyo" systemd/hermes-backup.timer
grep -Fq "OnCalendar=Sat *-*-* 08:00:00 Asia/Tokyo" systemd/hermes-hindsight-raw-backup.timer
grep -Fq "Persistent=true" systemd/hermes-backup.timer
grep -Fq "Persistent=true" systemd/hermes-hindsight-raw-backup.timer
```

- [ ] **Step 2: Add service and timer templates**

```ini
# systemd/hermes-backup.service
[Unit]
Description=Hermes logical Restic backup

[Service]
Type=oneshot
WorkingDirectory=/home/sysadmin/docker-hermes-memoria
ExecStart=/home/sysadmin/docker-hermes-memoria/scripts/backup-hermes-data.sh --mode daily
```

```ini
# systemd/hermes-backup.timer
[Unit]
Description=Run Hermes logical backup after scheduled agent work

[Timer]
OnCalendar=*-*-* 07:45:00 Asia/Tokyo
Persistent=true
Unit=hermes-backup.service

[Install]
WantedBy=timers.target
```

Create parallel raw templates with `weekly-raw` and the Saturday schedule.

- [ ] **Step 3: Implement the installer and validate**

Require `Linger=yes`, install templates with mode `0644`, reload the user manager, enable both timers, then print the timer list.

```bash
loginctl show-user "$USER" -p Linger | grep -qx "Linger=yes"
install -D -m 0644 systemd/hermes-backup.service "$HOME/.config/systemd/user/hermes-backup.service"
systemctl --user daemon-reload
systemctl --user enable --now hermes-backup.timer hermes-hindsight-raw-backup.timer
systemctl --user list-timers --all
```

Run:

```bash
bash tests/test_backup_scripts.sh
systemd-analyze verify systemd/hermes-backup.service systemd/hermes-backup.timer   systemd/hermes-hindsight-raw-backup.service systemd/hermes-hindsight-raw-backup.timer
git add systemd scripts/install-backup-timers.sh tests/test_backup_scripts.sh
git commit -m "Add scheduled rootless backup timers"
```

### Task 4: Document, deploy, and verify the first backup

**Files:**
- Modify: `README.md`
- Modify: `tests/test_backup_scripts.sh`

- [ ] **Step 1: Document setup and restore verification**

Add README instructions for Restic config permissions, NAS SFTP/rest-server requirement, timer install, manual daily/weekly runs, tags/retention, `restic snapshots`, `restic check`, and quarterly isolated restore verification. State that CIFS must not host the Restic repository.

- [ ] **Step 2: Add README contract assertions**

```bash
grep -Fq "scripts/install-backup-timers.sh" README.md
grep -Fq "restic check" README.md
grep -Fq "07:45 JST" README.md
grep -Fq "weekly raw Hindsight" README.md
```

- [ ] **Step 3: Run all local checks**

```bash
python3 -m unittest tests/test_hindsight_backup.py tests/test_hindsight_bank_restore.py -v
bash tests/test_backup_scripts.sh
python3 -m py_compile scripts/backup-hindsight-banks.py scripts/restore-hindsight-bank-backup.py scripts/validate-hindsight-bank-backup.py
bash -n scripts/backup-hermes-data.sh scripts/install-backup-timers.sh
git diff --check
```

- [ ] **Step 4: Deploy and prove a first snapshot**

```bash
git push origin main
ssh sysadmin@100.75.104.119 "cd /home/sysadmin/docker-hermes-memoria && git pull --ff-only origin main"
ssh sysadmin@100.75.104.119 "cd /home/sysadmin/docker-hermes-memoria && ./scripts/install-backup-timers.sh"
ssh sysadmin@100.75.104.119 "systemctl --user start hermes-backup.service"
ssh sysadmin@100.75.104.119 "set -a; source ~/.config/hermes-backup/restic.env; set +a; restic snapshots --tag hermes --latest 1; restic check"
```

Expected: a tagged daily logical snapshot exists, Hindsight validation passes, and `restic check` succeeds.

- [ ] **Step 5: Commit and publish documentation**

```bash
git add README.md tests/test_backup_scripts.sh
git commit -m "Document rootless Restic backups"
git push origin main
```


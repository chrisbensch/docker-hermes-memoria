# Operations Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the repository documentation so fresh installs, migrations, day-two operations, Hindsight recovery, and Restic backups match the validated rootless Compose deployment.

**Architecture:** Keep `README.md` as the architecture reference, `QUICKSTART.md` as the shortest setup path, and `AGENTS.md` as contributor guidance. Add `OPERATIONS.md` as the single command-oriented runbook and cross-link it from the existing guides to avoid competing copies of recovery procedures.

**Tech Stack:** Markdown, rootless Docker Compose, Bash, Python `unittest`, systemd user timers, Restic.

## Global Constraints

- Use rootless Docker Compose commands with `--env-file .env`.
- Use Compose service names for container-to-container URLs.
- Never commit secrets, passwords, Restic credentials, generated SearXNG settings, `.firecrawl-src`, or `appdata/`.
- Use placeholders for deployment addresses, provider models, and backup locations.
- Mark destructive operations clearly and require a backup before moving, replacing, or deleting runtime data.
- Do not modify historical records under `docs/superpowers/specs/` or existing plans except this implementation checklist.
- Report Compose validation as not run when a configured `.env` or generated bind-mount inputs are unavailable.

---

### Task 1: Correct Contributor Guidance

**Files:**
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: current repository scripts, tests, service names, and ignored runtime layout.
- Produces: contributor rules referenced by future agents and maintainers.

- [ ] **Step 1: Replace stale repository and testing claims**

Update `AGENTS.md` so it explicitly lists `OPERATIONS.md`, `systemd/`, `tests/`, the migration scripts, Hindsight backup/restore scripts, and Restic scripts. Replace “There is no formal test suite” and “This workspace does not include Git history” with current commands and concise imperative commit guidance.

- [ ] **Step 2: Document language-specific conventions**

State that legacy setup/profile scripts may use POSIX `sh`, operational scripts use Bash with `set -Eeuo pipefail`, and Python utilities use the standard library with `unittest`. Preserve lowercase profile naming and `hermes-<profile>` bank conventions.

- [ ] **Step 3: Add operational safety rules**

Document that rootless numeric ownership is expected, `appdata/` must not be deleted or replaced without a backup, failed staging directories are retained intentionally, logical Hindsight exports must be validated before restore, and Redis/RabbitMQ queue state is intentionally outside the durable backup scope.

- [ ] **Step 4: Validate and commit**

Run:

```bash
git diff --check
rg -n "no formal test suite|does not include Git history" AGENTS.md
```

Expected: `git diff --check` succeeds and `rg` returns no matches.

Commit:

```bash
git add AGENTS.md
git commit -m "Update contributor operations guidance"
```

### Task 2: Add The Operations Runbook

**Files:**
- Create: `OPERATIONS.md`

**Interfaces:**
- Consumes: `setup.sh`, `reset.sh`, scripts under `scripts/`, units under `systemd/`, and endpoints from `docker-compose.yml`.
- Produces: the canonical day-two command reference linked by the other guides.

- [ ] **Step 1: Add stack and health operations**

Create sections for loading the repository context, confirming rootless Docker, rendering Compose config, starting/stopping services, listing status, inspecting logs, and testing Hindsight, Headroom, Firecrawl, SearXNG, and Camofox health endpoints.

- [ ] **Step 2: Add dashboard and migrated-data checks**

Document password-hash generation inside the Hermes container, the `dashboard.basic_auth` configuration shape, force recreation, direct HTTP login verification, profile enumeration, active-profile inspection, integrated URL checks, Memory Vault checks, and cron file inspection. Use `<server-ip>` and `<new-password>` placeholders.

- [ ] **Step 3: Add migration workflow**

Document inventory collection with environment variables, migration dry-run and apply commands, all-profile behavior, preservation of `config.host-migration.yaml`, permission normalization, and post-migration validation. Require a timestamped copy or Restic snapshot before replacing destination data.

- [ ] **Step 4: Add Hindsight backup and restore workflow**

Document `backup-hindsight-banks.py`, `validate-hindsight-bank-backup.py`, dry-run target preflight, pilot-bank restore, all-bank restore, count comparison, and consolidation/network checks. State that target banks must be absent and `--apply` performs writes.

- [ ] **Step 5: Add Restic operations and recovery order**

Document loading `~/.config/hermes-backup/restic.env`, listing snapshots, inspecting logical and raw data sizes, running `restic check`, manual daily and weekly jobs, timer status and logs, snapshot browsing with `restic ls`, restoring into an isolated directory, and recovery order: configuration and Hermes archive, profile SQLite databases, Headroom, Firecrawl Postgres, then Hindsight logical import or raw checkpoint.

- [ ] **Step 6: Validate and commit**

Run:

```bash
git diff --check
rg -n -- "--mode daily|--mode weekly-raw|restic snapshots|restic stats|systemctl --user|restore-hindsight-bank-backup.py" OPERATIONS.md
```

Expected: no whitespace errors and all operational command groups are present.

Commit:

```bash
git add OPERATIONS.md
git commit -m "Add rootless operations runbook"
```

### Task 3: Rebalance README And Quickstart

**Files:**
- Modify: `README.md`
- Modify: `QUICKSTART.md`

**Interfaces:**
- Consumes: canonical procedures in `OPERATIONS.md`.
- Produces: architecture overview and fresh-install path that link to the runbook.

- [ ] **Step 1: Add guide navigation to README**

Near the introduction, add a guide map linking setup to `QUICKSTART.md`, ongoing administration to `OPERATIONS.md`, contributor rules to `AGENTS.md`, and design history to `docs/superpowers/`. Keep the architecture and memory model in README.

- [ ] **Step 2: Tighten migration, restore, and backup sections**

Retain their conceptual guarantees and primary entry commands, add links to the complete runbook, include Restic snapshot size commands, and remove duplicated procedural detail when `OPERATIONS.md` is authoritative.

- [ ] **Step 3: Add post-install operations to Quickstart**

After service validation, add a short next-steps section linking migrated installs, dashboard auth, backup timer installation, and restore testing to `OPERATIONS.md`. Do not turn Quickstart into a second operations manual.

- [ ] **Step 4: Verify links and terminology**

Run:

```bash
rg -n "OPERATIONS.md|QUICKSTART.md|AGENTS.md" README.md QUICKSTART.md
rg -n "Firecrawl|Camofox|SearXNG|Hindsight|Headroom|Restic" README.md QUICKSTART.md
git diff --check
```

Expected: both guides link to operations, README links all guide roles, and terminology matches Compose service names.

- [ ] **Step 5: Commit**

```bash
git add README.md QUICKSTART.md
git commit -m "Link setup and operations documentation"
```

### Task 4: Full Documentation Verification And Deployment

**Files:**
- Verify: `AGENTS.md`
- Verify: `README.md`
- Verify: `QUICKSTART.md`
- Verify: `OPERATIONS.md`

**Interfaces:**
- Consumes: all documentation changes from Tasks 1-3.
- Produces: a tested and pushed documentation set.

- [ ] **Step 1: Run repository tests**

Run:

```bash
bash tests/test_backup_scripts.sh
python3 -m unittest discover -s tests -v
bash -n scripts/*.sh setup.sh reset.sh
git diff --check
```

Expected: shell checks pass and all Python tests pass.

- [ ] **Step 2: Validate Compose when local inputs permit**

Run:

```bash
docker compose --env-file .env config --quiet
```

Expected: success when `.env`, `.firecrawl-src/apps/nuq-postgres`, and `web-search/searxng-settings.yml` exist. Otherwise record the missing prerequisite and do not claim runtime validation.

- [ ] **Step 3: Review documentation diff**

Run:

```bash
git diff HEAD~3 -- AGENTS.md README.md QUICKSTART.md OPERATIONS.md
git status --short --branch
```

Expected: only intentional documentation changes are present; unrelated untracked runtime files are absent from the commit.

- [ ] **Step 4: Push and verify**

Run:

```bash
git push origin main
git status --short --branch
```

Expected: `main` matches `origin/main` and the worktree is clean.

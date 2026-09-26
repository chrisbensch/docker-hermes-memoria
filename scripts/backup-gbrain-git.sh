#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
readonly STACK_REPO=https://github.com/chrisbensch/hermes-gbrain.git
readonly STACK_REPO_NAME=chrisbensch/hermes-gbrain
readonly GIT_ROOT="$REPO_ROOT/appdata/gbrain/shared/.gbrain/git-backup"
readonly STAGING_ROOT="$REPO_ROOT/appdata/gbrain/shared/.gbrain/git-backup-staging"
readonly CONTAINER_STAGING_ROOT=/var/lib/gbrain/home/.gbrain/git-backup-staging
readonly STATE_ROOT=${GBRAIN_GIT_BACKUP_STATE_ROOT:-/home/sysadmin/.local/state/gbrain-git-backup}

compose() {
  docker compose --env-file "$REPO_ROOT/.env" --profile gbrain "$@"
}

mkdir -m 700 -p "$STATE_ROOT" "$STAGING_ROOT"
exec 9>"$STATE_ROOT/backup.lock"
flock -n 9 || { printf 'GBrain Git backup already running.\n' >&2; exit 1; }

export GH_PROMPT_DISABLED=1
export GIT_TERMINAL_PROMPT=0

if [[ $(gh repo view "$STACK_REPO_NAME" --json isPrivate --jq '.isPrivate') != true ]]; then
  printf 'Refusing to export GBrain data: %s is not verified private.\n' "$STACK_REPO_NAME" >&2
  exit 1
fi

if [[ ! -d "$GIT_ROOT/.git" ]]; then
  mkdir -p "$(dirname -- "$GIT_ROOT")"
  git clone "$STACK_REPO" "$GIT_ROOT"
fi

[[ $(git -C "$GIT_ROOT" remote get-url origin) == "$STACK_REPO" ]] || {
  printf 'Unexpected origin in GBrain Git backup repository: %s\n' "$GIT_ROOT" >&2
  exit 1
}
[[ $(git -C "$GIT_ROOT" branch --show-current) == main ]] || {
  printf 'Expected the GBrain Git backup repository to use main.\n' >&2
  exit 1
}
[[ -z $(git -C "$GIT_ROOT" status --porcelain) ]] || {
  printf 'GBrain Git backup worktree is dirty; inspect before retrying: %s\n' "$GIT_ROOT" >&2
  exit 1
}

git -C "$GIT_ROOT" fetch origin main
git -C "$GIT_ROOT" merge --ff-only origin/main

timestamp=$(date -u +%Y%m%d-%H%M%SZ)
staging="$STAGING_ROOT/$timestamp"
container_export="$CONTAINER_STAGING_ROOT/$timestamp/database-export"
success=no

finish() {
    status=$?
    if [[ $status -eq 0 && $success == yes ]]; then
      python3 - "$staging" "$STAGING_ROOT" <<'PY'
import shutil
import sys
from pathlib import Path

stage = Path(sys.argv[1])
parent = Path(sys.argv[2])
if stage.parent != parent or not stage.is_dir():
    raise SystemExit("refusing to remove an unexpected GBrain Git staging path")
shutil.rmtree(stage)
PY
  else
    printf 'GBrain Git export staging retained for diagnosis: %s\n' "$staging" >&2
  fi
  exit "$status"
}
trap finish EXIT

container_staging="$CONTAINER_STAGING_ROOT/$timestamp"
export_summary=$(compose exec -T gbrain sh -lc \
  "umask 077; mkdir -m 700 -p '$container_staging'; /usr/local/bin/gbrain export --quiet --dir '$container_export'")
printf '%s\n' "$export_summary"
[[ $export_summary =~ Exported\ ([1-9][0-9]*)\ pages ]] || {
  printf 'GBrain export did not report a positive page count.\n' >&2
  exit 1
}
exported_pages=${BASH_REMATCH[1]}

host_export="$staging/database-export"
[[ -d $host_export ]] || { printf 'GBrain export files are not visible on the host.\n' >&2; exit 1; }

file_count=$(find -L "$host_export" -type f | wc -l)
markdown_count=$(find -L "$host_export" -type f -name '*.md' | wc -l)
[[ $file_count -gt 0 && $markdown_count -eq $exported_pages ]] || {
  printf 'Export file count mismatch: pages=%s markdown=%s files=%s\n' \
    "$exported_pages" "$markdown_count" "$file_count" >&2
  exit 1
}

compose exec -T \
  -e GBRAIN_EXPORT_SCAN_ROOT="$container_export" \
  gbrain bun - <<'JS'
import { readdirSync, statSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { scanText, SCAN_MAX_FILE_BYTES } from '/opt/gbrain/src/core/secret-scan.ts';

const root = process.env.GBRAIN_EXPORT_SCAN_ROOT;
const files = [];
function walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) walk(path);
    else if (entry.isFile()) files.push(path);
  }
}
walk(root);

const denied = [];
const oversized = [];
const findings = [];
for (const path of files) {
  const rel = relative(root, path);
  if (rel.endsWith('.pglite') || rel.split('/').some((part) => part.startsWith('.env')) ||
      rel.endsWith('.pem') || rel.endsWith('.key') || rel.startsWith('.gbrain/')) {
    denied.push(rel);
  }
  const size = statSync(path).size;
  if (size > SCAN_MAX_FILE_BYTES) {
    oversized.push(rel);
    continue;
  }
  for (const finding of scanText(readFileSync(path, 'utf8'))) {
    findings.push({ file: rel, pattern: finding.pattern, line: finding.line });
  }
}
console.log(JSON.stringify({ files: files.length, denied, oversized, findings }, null, 2));
if (denied.length || oversized.length || findings.length) process.exitCode = 2;
JS

if ! command -v rsync >/dev/null 2>&1; then
  printf 'rsync is required to safely mirror the GBrain export.\n' >&2
  exit 1
fi
mkdir -p "$GIT_ROOT/database-export"
rsync -rt --delete "$host_export/" "$GIT_ROOT/database-export/"
git -C "$GIT_ROOT" add -A -- database-export

if ! git -C "$GIT_ROOT" diff --cached --quiet -- database-export; then
  if ! compose exec -T \
    -e GBRAIN_EXPORT_SCAN_REPO=/var/lib/gbrain/home/.gbrain/git-backup \
    gbrain bun - <<'JS'
import { execFileSync } from 'node:child_process';
import { scanText, SCAN_MAX_FILE_BYTES, loadWorkspaceAllowlist } from '/opt/gbrain/src/core/secret-scan.ts';
const root = process.env.GBRAIN_EXPORT_SCAN_REPO;
const rels = execFileSync('git', ['-C', root, 'diff', '--cached', '--name-only', '-z', '--', 'database-export'])
  .toString().split('\0').filter(Boolean);
const allowlist = loadWorkspaceAllowlist(root);
const denied = rels.filter((p) => p.endsWith('.pglite') || p.startsWith('.env') ||
  p.endsWith('.pem') || p.endsWith('.key') || p.startsWith('.gbrain/'));
const oversized = [];
const findings = [];
for (const rel of rels) {
  const blob = execFileSync('git', ['-C', root, 'cat-file', '-p', `:${rel}`], { maxBuffer: SCAN_MAX_FILE_BYTES + 1 });
  if (blob.length > SCAN_MAX_FILE_BYTES) { oversized.push(rel); continue; }
  for (const finding of scanText(blob.toString('utf8'), { allowlist })) {
    findings.push({ file: rel, pattern: finding.pattern, line: finding.line });
  }
}
console.log(JSON.stringify({ staged: rels.length, denied, oversized, findings }, null, 2));
if (denied.length || oversized.length || findings.length) process.exitCode = 2;
JS
  then
    git -C "$GIT_ROOT" reset -q
    git -C "$GIT_ROOT" restore --worktree -- database-export
    printf 'GBrain export failed its staged-content secret scan; nothing was committed.\n' >&2
    exit 1
  fi

  git -C "$GIT_ROOT" \
    -c user.name='GBrain Git Backup' \
    -c user.email='gbrain-git-backup@localhost' \
    commit -m "GBrain database export $timestamp"
fi

git -C "$GIT_ROOT" push origin main
local_commit=$(git -C "$GIT_ROOT" rev-parse HEAD)
remote_commit=$(git -C "$GIT_ROOT" ls-remote origin refs/heads/main | awk '{print $1}')
[[ -n $remote_commit && $local_commit == "$remote_commit" ]] || {
  printf 'Remote GBrain Git backup did not verify against local HEAD.\n' >&2
  exit 1
}

success=yes
printf 'Verified GBrain database export: %s pages at %s\n' "$exported_pages" "$local_commit"

# Obsidian Vault Permissions Design

**Date:** 2026-07-11

## Objective

Make the shared Obsidian Memory Vault writable by both Hermes Agent inside the
rootless container and the deployment user on the host. Apply the same model to
the current migrated vault and every future setup or migration without using
host `sudo chown`, world-writable modes, or hard-coded host subordinate IDs.

## Current Failure

The migrated vault is owned by host `sysadmin:sysadmin` with restrictive group
modes. Rootless Docker maps that ownership to `root:root` inside the container.
Hermes tools that run as the container `hermes` user therefore receive
`Permission denied`, even though container-root diagnostics can write.

The existing normalization script changes groups and read permissions but does
not make the vault owned or writable by the container Hermes user.

## Ownership Model

The vault will use this identity model inside the Hermes container:

```text
owner: hermes
group: root
directories: user and group rwx, setgid, no other access
files: user and group rw, preserve existing user/group execute bits, no other access
```

In rootless Docker, container user `hermes` maps to a subordinate host UID,
while container group `root` maps to the deployment user's primary host group.
This gives Hermes owner access and host `sysadmin` group access without exposing
the vault to other users. Setgid directories make new content inherit the
shared group.

## Components

### Permission Helper

Add `scripts/fix-obsidian-vault-permissions.sh` as the canonical operation. It
will:

- resolve the repository root and effective `APPDATA_DIR` from `.env`;
- allow explicit `HERMES_DATA_DIR`, `HERMES_IMAGE`, and vault-path overrides for
  setup, migration, tests, and non-default deployments;
- refuse empty, `/`, checkout-root, or non-vault target paths;
- require the vault directory to exist;
- use a one-off rootless Hermes image as container root, avoiding host sudo and
  hard-coded subordinate IDs;
- resolve the `hermes` account inside the image and apply `hermes:root`
  ownership recursively;
- add user/group write permissions, remove other access, set setgid on
  directories, and preserve existing executable bits on files;
- verify a write/delete operation as the container Hermes UID and a separate
  write/delete operation as the host deployment user;
- print mapped numeric ownership and a concise success result without listing
  vault contents or secrets.

### Setup Integration

`setup.sh` will invoke the helper after profile and vault scaffolding is
complete. Running it last ensures host-created seed files are normalized before
Hermes starts.

### Migration Integration

`scripts/migrate-host-hermes-data.sh` will invoke the helper after copied vault,
profile, and cron content has been written. Dry-run mode will print the intended
permission operation without changing ownership. A missing Docker daemon or
image is a clear failure for an applied migration because leaving the migrated
vault unwritable would create a partially successful deployment.

### Existing Normalization Integration

`scripts/normalize-appdata-permissions.sh` will retain its current general
Hermes/Hindsight readability behavior, then invoke the vault-specific helper.
The specialized helper owns the vault's write-sharing policy and must run last.

## Current Server Remediation

Before changing ownership on `bl-agentic-01`:

1. Run a daily logical Restic backup and verify the snapshot completes.
2. Record the vault file count and current numeric ownership summary.
3. Run the new helper from the deployed checkout.
4. Verify create/write/delete as container Hermes and host `sysadmin`.
5. Confirm the file count is unchanged and the Compose stack remains healthy.

The change modifies metadata only. No vault content will be moved or deleted.

## Error Handling

- Unsafe or missing target paths fail before container execution.
- Missing `.env`, Docker, image identity, or rootless socket fails clearly.
- Any `chown`, `chmod`, or write verification failure aborts with a nonzero
  status.
- Temporary verification files use unique names and are removed by traps.
- The helper never follows a user-supplied path outside the resolved vault.

## Testing

Static tests will verify path guards, ownership/mode commands, integration
points, dry-run behavior, and shell syntax. Runtime validation on
`bl-agentic-01` will verify:

```bash
docker compose --env-file .env config --quiet
bash tests/test_backup_scripts.sh
python3 -m unittest discover -s tests -v
bash -n scripts/*.sh setup.sh reset.sh
docker compose --env-file .env exec -T -u 1000:1000 hermes \
  sh -c ': > /opt/data/obsidian-memory-vault/.permission-test && rm -f /opt/data/obsidian-memory-vault/.permission-test'
```

The runtime check will use the configured Hermes UID rather than assuming
`1000` in the implementation.

## Acceptance Criteria

- Hermes can create, modify, and delete a vault file as its unprivileged user.
- Host `sysadmin` can create, modify, and delete a vault file without sudo.
- Existing vault file count and contents remain unchanged.
- Setup, migration, and normalization all apply the same ownership policy.
- No tracked file contains host subordinate UID values or vault secrets.

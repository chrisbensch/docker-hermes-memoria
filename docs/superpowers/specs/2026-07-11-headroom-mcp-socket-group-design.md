# Headroom MCP Socket Group Design

**Date:** 2026-07-11

## Objective

Make Headroom's stdio MCP connection reliable from every Hermes execution path
in the rootless Compose stack, including agent sessions and cron jobs that drop
supplementary groups before spawning MCP subprocesses.

## Confirmed Failure

The Hermes container already mounts the correct rootless Docker socket:

```text
/run/user/1000/docker.sock -> /var/run/docker.sock
```

At container startup, the Hermes image reads the socket GID, creates the
`hostdocker` group, and adds the `hermes` account to it. The long-running
gateway has that supplementary group, and profile-aware `hermes mcp test`
succeeds. Some agent-session startup paths nevertheless spawn with only the
primary `hermes` group. Their direct `docker exec` fails, the Headroom stdio
server exits, and Hermes reports `Connection closed`.

The per-profile `mcp-stderr.log` confirms repeated Docker socket connection
failures. Headroom itself is healthy: a direct MCP initialize, tools/list, and
`headroom_stats` call all succeed when launched with the socket group.

## Selected Design

Configure Headroom MCP to invoke `sg hostdocker -c ...` rather than invoking
`docker exec` directly:

```yaml
headroom:
  command: sg
  args:
    - hostdocker
    - -c
    - >-
      exec docker exec -i
      -e HEADROOM_PROXY_URL=http://headroom-proxy:8787
      hermes-headroom-mcp headroom mcp serve
```

`sg` resolves `hostdocker` through the container account database and switches
the command's effective group before executing Docker. The image creates that
group dynamically from the mounted socket, so no host or subordinate GID is
hard-coded. Stdin, stdout, and stderr remain attached to the MCP client.

## Repository Changes

### Future Profiles

Update `hermes-data/profile-templates/rootless/config.yaml` and
`hermes-config-fragment.yaml` to use the group-reacquiring command. New profiles
created by setup or migration inherit the fixed transport.

### Existing Profiles

Add `scripts/fix-headroom-mcp-command.py`, using YAML parsing rather than text
replacement. It will:

- resolve effective `APPDATA_DIR` and Hermes data paths;
- run through the Hermes container when host permissions prevent direct reads;
- inspect every named profile and the base config if it contains a Headroom MCP
  block;
- recognize the old direct Docker command and the new `sg` command;
- create a timestamped backup beside each changed config before writing;
- preserve unrelated YAML configuration;
- support `--dry-run` and selected-profile filters;
- refuse ambiguous or custom Headroom commands instead of overwriting them;
- report changed, already-correct, skipped, and failed profiles.

The live migration will run a dry-run first, then update all recognized profile
configs. `maestro` must be included.

### Setup And Migration

Future setup and migration primarily receive the fix through the profile
template. Their validation and documentation will state that the Hermes image
must provide `sg` and dynamically create `hostdocker` when the socket is
mounted.

### Documentation

Update contributor and operations guidance to explain:

- the sleeping `hermes-headroom-mcp` container is intentional;
- Headroom MCP is stdio, not HTTP;
- the rootless socket is already mounted;
- `sg hostdocker` is required because some session paths drop supplementary
  groups;
- direct `docker exec -u 1000` diagnostics are misleading unless the socket
  group is reacquired;
- `hermes -p <profile> mcp test headroom` is the canonical client test.

## Alternatives Rejected

- A second `/var/run/docker.sock` mount would point at the wrong daemon and is
  redundant because the rootless socket is already mounted.
- Compose `group_add` would require a mapped socket GID that varies by rootless
  namespace and host.
- Headroom's current MCP command is stdio-only; the healthy HTTP proxy is not an
  MCP HTTP endpoint.
- Accepting failures would leave interactive tools and scheduled statistics
  jobs unreliable.

## Safety And Rollback

- Run a daily logical Restic backup before live profile edits.
- The updater creates timestamped per-config backups before every write.
- Stop on custom or ambiguous Headroom blocks.
- Do not change the Docker socket mount, Headroom image, proxy, or container
  lifecycle.
- Rollback restores the adjacent backup and restarts Hermes.

## Validation

Repository validation:

```bash
bash tests/test_backup_scripts.sh
python3 -m unittest discover -s tests -v
bash -n setup.sh scripts/*.sh reset.sh
docker compose --env-file .env config --quiet
```

Live validation:

```bash
docker compose --env-file .env exec -T -u 1000:1000 hermes \
  sg hostdocker -c 'docker version >/dev/null'

docker compose --env-file .env exec -T hermes \
  /package/admin/s6/command/s6-setuidgid hermes \
  hermes -p maestro mcp test headroom
```

After restarting Hermes, a fresh `maestro` session must register
`mcp__headroom__headroom_compress`, `mcp__headroom__headroom_retrieve`, and
`mcp__headroom__headroom_stats` without adding a new `Connection closed` entry.

## Acceptance Criteria

- Every standard profile uses the `sg hostdocker` Headroom command.
- No mapped Docker GID is committed or written to profile configuration.
- Hermes' canonical MCP test discovers all three Headroom tools.
- A fresh agent session registers all Headroom tools.
- The Headroom daily statistics cron can connect through the same transport.
- Existing profile configs have timestamped rollback copies.

# GBrain Read-Only Retrieval Pilot

## Outcome and boundaries

This optional pilot measures whether GBrain improves retrieval over selected
Obsidian Markdown. It does not integrate GBrain into Hermes yet.

- The Obsidian vault remains the human-readable system of record.
- Hindsight remains the profile-scoped conversational and semantic memory
  layer.
- GBrain state is a disposable, derived PGLite index under `appdata/gbrain/`.
- The GBrain container gets no provider credentials, no host port, no live-vault
  mount, and no Hermes MCP configuration.
- The runner permits only local keyword/graph evaluation. It always imports
  with `--no-embed` and forces `search.mode=conservative` at initialization.

The GBrain image is built from the exact `GBRAIN_REF` commit in `.env.example`.
Review and change that full SHA deliberately before rebuilding. The image build
does contact GitHub and the Bun package registry, but no vault content leaves
the host. The running container has no embedding, chat, or other provider
credentials. `GBRAIN_SKIP_STARTUP_HOOKS=1` also disables GBrain's detached
runtime update check; update the pinned source only through an explicit review.

## Pilot topology

```text
live Obsidian vault
        |
        | reviewed Markdown selection (host copy; hash checked)
        v
appdata/gbrain/staging/<profile>/<timestamp>  [read-only mount]
        |
        v
gbrain-pilot one-shot CLI  --->  appdata/gbrain/home/<profile> (derived PGLite)

Hermes / Hindsight / Headroom: unchanged
```

The staging manifest is intentionally narrow. It may select only `Shared/` and
`Profiles/<profile>/` paths, and only Markdown is copied. The script refuses
absolute paths, parent traversal, `.env` paths, credential-named paths, other
profiles, and non-Markdown files. These guards supplement—not replace—human
review of the selected notes.

## Runbook

Do this on the deployment host from the repository root. These commands create
files only under the ignored `appdata/gbrain/` directory; none alters the live
vault.

1. Create a selection manifest, then edit it carefully:

   ```bash
   ./scripts/prepare-gbrain-pilot-corpus.sh --profile maestro --init-manifest
   ${EDITOR:-vi} appdata/gbrain/pilot-include-maestro.txt
   ```

   Start with a small number of non-sensitive infrastructure and research notes.
   Exclude Daily Reviews, generated reports, credentials, raw API responses,
   and profile-private material that is not required for the evaluation.

2. Prepare the corpus. This records before/after SHA-256 inventories of the
   live vault and fails if they differ:

   ```bash
   ./scripts/prepare-gbrain-pilot-corpus.sh --profile maestro --apply
   ```

   Copy the printed staging path exactly. Do not point GBrain at the live vault.

3. Build and initialize the isolated index:

   ```bash
   ./scripts/run-gbrain-pilot.sh --profile maestro init
   ```

   This invokes the optional `gbrain-pilot` Compose profile as a one-shot
   container. It runs `gbrain init --pglite --no-embedding`, sets `search.mode=conservative`,
   and displays the configured search modes.

4. Import and evaluate the staging corpus:

   ```bash
   ./scripts/run-gbrain-pilot.sh --profile maestro import \
     appdata/gbrain/staging/maestro/<timestamp>
   ./scripts/run-gbrain-pilot.sh --profile maestro stats
   ./scripts/run-gbrain-pilot.sh --profile maestro doctor
   ./scripts/run-gbrain-pilot.sh --profile maestro search "database migration decision"
   ./scripts/run-gbrain-pilot.sh --profile maestro extract-links-dry-run
   ```

   `graph-query` is read-only, but it has useful results only after a separately
   approved graph backfill. The pilot intentionally offers only extraction
   preview, not graph mutation.

5. Record the evaluation in `appdata/gbrain/reports/<profile>/`: corpus scope,
   result examples, missing results, doctor/stats output, the staging path, and
   the live-vault hash report. The index may be deleted and rebuilt; retain the
   report if it informs a promotion decision.

## What the runner permits

`scripts/run-gbrain-pilot.sh` permits only:

- `init` with PGLite plus conservative search mode;
- import from the profile's generated staging directory with `--no-embed`;
- `doctor`, `stats`, `search`, `extract links --dry-run`, and `graph-query`.

It rejects `serve`, sync, embed, dream, autopilot, enrichment, write operations,
provider configuration, live-vault import, and arbitrary GBrain subcommands.
No GBrain service is started by `docker compose up`.

## Phase 1: private HTTP/OAuth surface

Phase 1 validates only that `gbrain serve --http` is private and requires
authentication. It does not add GBrain to a Hermes profile or create an OAuth
client. The test uses two tracked synthetic Markdown files and an isolated
`appdata/gbrain/home/http-test` PGLite home.

```bash
./scripts/run-gbrain-http-test.sh init
./scripts/run-gbrain-http-test.sh start
./scripts/run-gbrain-http-test.sh verify
```

`verify` succeeds only when the OAuth discovery document is reachable, an
unauthenticated JSON-RPC `initialize` request is rejected with HTTP 401 or 403,
and Docker reports `127.0.0.1:<port>` as the sole published binding. The test
service has no vault mount, no provider credentials, and no Hermes dependency.
It runs as container root only within rootless Docker so its root identity maps
to the deployment user that owns the derived bind mount; it has no Docker socket
or mount outside `appdata/gbrain`.
It stops independently without touching the base stack:

```bash
./scripts/run-gbrain-http-test.sh stop
```

Do not run `init` a second time against the same `http-test` home. Review the
existing test data first, or set a fresh `APPDATA_DIR` explicitly for a new run.
The HTTP service has a 30-second shutdown grace period. The pinned GBrain
source has a narrowly scoped local patch that closes the HTTP listener and then
awaits the PGLite engine disconnect on every shutdown path. `stop` fails if the
serve lock remains, retaining it for diagnosis. Before a start, the runner can
still recover an older lock left by an unpatched run: it confirms the test
container is stopped, preserves and verifies a copy of that derived lock, then
archives it. It never deletes the brain directory.

## Phase 2: read-scope authorization result

Phase 2 creates a dedicated OAuth `client_credentials` client with only the
`read` scope against the synthetic HTTP-test brain. Its secret stays in an
ignored, mode-`0600` file under `appdata/gbrain/secrets/`; it is never placed in
a profile, Compose environment, report, or tracked file.

The required server-side read-only proof is an authenticated `search` followed
by an authenticated `put_page` attempt. The search must succeed and the write
must return an MCP error stating that `write` scope is required. This proves
that a stolen or misconfigured read-scope token cannot mutate GBrain data.

With the confidential client created, run the repeatable verifier while the
synthetic test service is running:

```bash
./scripts/run-gbrain-http-test.sh start
./scripts/verify-gbrain-http-read-client.sh
./scripts/run-gbrain-http-test.sh stop
```

The verifier reads the ignored, mode-`0600` credential file, writes only
synthetic evidence, and removes its short-lived access-token file before exit.

The pinned GBrain revision has an important limitation: its `--bound-tools`
client option must **not** be treated as an enforcement boundary. In Phase 2
testing, `tools/list` still advertised mutating tools and a client bound to
`search` could call the unbound read operation `get_page`. The OAuth `read`
scope did enforce the write denial, but tool binding did not reduce either the
advertised tool set or the allowed read operations.

Therefore Phase 2 passes the narrow, server-side read-only authorization check,
but it does **not** approve a direct Hermes integration. Keep the client
confidential and stop the HTTP test service after testing. The timestamped,
synthetic request/response evidence belongs only in
`appdata/gbrain/reports/http-test/`.

## Phase 3: local MCP allowlist proxy

Phase 3 adds a synthetic-only `gbrain-mcp-allowlist-test` service. It obtains
the Phase 2 confidential OAuth client credentials from a read-only file mount,
then presents an unauthenticated MCP endpoint only on host loopback. No caller
gets the upstream OAuth secret or token. The proxy filters **both** `tools/list`
and `tools/call`; its initial allowlist is intentionally only `search`.

Run the proxy test after Phase 2 has created the protected client file:

```bash
./scripts/run-gbrain-allowlist-test.sh start
./scripts/run-gbrain-allowlist-test.sh verify
./scripts/run-gbrain-allowlist-test.sh stop
```

`start` reuses an already-running synthetic HTTP test only after its Phase 1
checks pass; otherwise it starts and verifies that service before launching the
proxy. A running service that fails authentication or loopback-binding checks
causes the command to fail closed.

`verify` requires that discovery exposes `search` but not `put_page`, that a
search returns the synthetic corpus, and that `put_page` is rejected locally by
the proxy before it reaches GBrain. The proxy has no vault mount, no Hermes
configuration, and no externally reachable listener. Its unit tests cover the
policy and response filtering separately from this integration test.

This is a security boundary, not a convenience filter: do not add GBrain tools
to `GBRAIN_ALLOWED_TOOLS` merely because they are read-like. Each operation
must first be reviewed for data exposure and mutation behavior, then receive a
specific denied-operation test.

## Synthetic validation record

The complete synthetic workflow passed on 2026-08-17 against pinned GBrain
revision `c6dc0adf26a2d20df1147d2ec87c8922ca86d410`:

- the image built with the reviewed shutdown patch and synthetic PGLite state;
- OAuth discovery succeeded, unauthenticated MCP initialization was denied,
  and the HTTP service published only on `127.0.0.1:3131`;
- a confidential `read`-scope client searched the synthetic corpus, while
  GBrain rejected `put_page` because the client lacked `write` scope;
- the loopback proxy advertised only `search`, returned the synthetic result,
  and rejected `put_page` before forwarding it upstream;
- Phase 3 start succeeded both with Phase 1 already running and with it
  stopped; an existing service was reused only after Phase 1 verification;
- both services stopped cleanly, ports 3131 and 3132 closed, and the PGLite
  serve lock was released without affecting the base Compose stack.

Request/response evidence remains in ignored `appdata/gbrain/reports/` state
on the validation host. This proves the synthetic isolation and authorization
controls; it does not satisfy the retrieval-quality or Hermes-integration
promotion gates below.

## Promotion gates

Promote only after the pilot has run long enough to compare retrieval quality
against direct vault lookup and Hindsight recall for real, non-sensitive work.
All of these must be true:

1. The selected scope, vault hash reports, and GBrain source commit are recorded.
2. Keyword retrieval and graph preview provide a measurable benefit; otherwise
   remove the derived state and stop here.
3. The index remains segregated by profile. Start with one GBrain brain per
   Hermes profile; add a separate shared brain only if cross-profile shared
   retrieval is explicitly wanted.
4. If embeddings are considered, the provider, data egress, retention terms,
   cost, and an explicit operator approval have been reviewed. Do not reuse a
   Hermes or Hindsight key by default.
5. Revalidate the pinned GBrain HTTP lifecycle patch after every GBrain source
   update. A clean start, authenticated check, stop, and restart must leave no
   PGLite serve lock; otherwise do not treat the HTTP service as durable.
6. Hermes' MCP authentication capabilities have been tested against GBrain's
   HTTP OAuth client-credentials flow. Configure an internal-only endpoint and
   a dedicated `read`-scope client; publish no port and use no tunnel.
7. The independently tested local MCP allowlist proxy has passed against the
   selected GBrain storage engine and filters both `tools/list` and `tools/call`
   to the approved read operations. Hermes-side `tools.include` is useful
   defense in depth, but is not the server-side boundary because current
   GBrain tool binding is not sufficient.

Do not connect Hermes to `gbrain serve` over stdio. Stdio treats the caller as
trusted and exposes mutating GBrain operations. Do not connect Hermes directly
to GBrain HTTP until the allowlist proxy and its denied-operation tests exist.

The future Hermes allowlist is: search, local-safe query, get/list page,
backlinks, graph traversal, timeline/trajectory reads, health, stats, and
identity reads. Explicitly exclude page/link/timeline writes, file upload,
source/schema/config mutation, sync, embedding, dream, autopilot, shell jobs,
minions, onboarding remediation, and auth/client administration.

## Rollback

There is no live integration to undo in this phase. Stop using the optional
Compose profile and archive or remove only the specific `appdata/gbrain/`
subdirectories after preserving any evaluation report you need. Never delete or
modify `appdata/hermes/obsidian-memory-vault`, Hindsight data, or Hermes profile
configuration as part of this rollback.

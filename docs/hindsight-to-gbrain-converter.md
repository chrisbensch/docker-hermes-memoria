# Hindsight-to-GBrain Converter

`scripts/convert-hindsight-backup-to-gbrain.py` converts a complete, validated
Hindsight logical backup into a new, staged GBrain Markdown corpus. It never
contacts Hindsight or GBrain, changes the backup, imports data, or writes under
`appdata/` unless that location is explicitly supplied as the output.

Run the backup validator first, then convert into a new directory:

```bash
python3 scripts/validate-hindsight-bank-backup.py \
  --backup-dir tmp/hindsight-bank-backups/<backup-name> \
  --report tmp/hindsight-bank-backups/<backup-name>/validation-report.json

python3 scripts/convert-hindsight-backup-to-gbrain.py \
  --backup-dir tmp/hindsight-bank-backups/<backup-name> \
  --output-dir tmp/gbrain-corpora/<conversion-name> \
  --report tmp/gbrain-corpora/<conversion-name>-summary.json
```

The output directory contains the full sensitive document, memory, directive,
and raw provenance text from the backup. Treat it with the same access,
retention, encryption, and disposal controls as the Hindsight backup. Never
commit it or place it in a broadly readable location.

The output directory must not already exist. Conversion first re-runs the
repository's Hindsight validator, stages into a temporary sibling directory,
and publishes the completed corpus by one rename. A failure leaves an existing
destination untouched. Standard output and the optional report contain paths
and counts only, never memory content.

## Mapping and provenance

Each `hermes-<profile>` bank maps to `profiles/<profile>/`. The converter
rejects unsafe profile names, `default`, and profile collisions.

| Hindsight section | Staged GBrain path |
| --- | --- |
| Transfer documents | `profiles/<profile>/documents/` |
| Non-observation memories | `profiles/<profile>/memories/facts/` |
| Observation memories | `profiles/<profile>/memories/observations/` |
| Entities | `profiles/<profile>/entities/` |
| Directives | `profiles/<profile>/directives/` |
| Mental models | `profiles/<profile>/mental-models/` |

Every artifact produces a searchable `.md` page and an exact normalized JSON
sidecar below the adjacent `.raw/` directory. Markdown frontmatter records the
source bank, profile, kind, Hindsight ID, dates, state, tags, and document link
where available. Opaque filenames combine a sanitized ID with an ID hash; no
memory text is placed in filenames or logs. Each profile also has a
`.raw/hindsight-transfer-observations.json` sidecar. This preserves the transfer
archive's observation `sources` and `observation_scopes`, which are absent from
`memories.json`; the converter deliberately does not guess a correlation because
transfer observations have no stable IDs.

Hindsight entities use their canonical Hindsight names as titles. A
deterministic, high-precision quality pass only marks a record as a linkable
GBrain `entity` when its normalized title-token sequence is unique, Hindsight
recorded at least two mentions, and its name passes conservative syntax and
generic-name gates. Every member of an ambiguous normalized-name group is
quarantined rather than merged or assigned an arbitrary winner. Ambiguous,
low-evidence, short, generic, identifier-like, bare-handle, and plain lowercase
single-token names remain searchable `note` pages with suppression reasons in
frontmatter. The manifest reports aggregate decisions without entity names.

This makes the retained entity pages available to GBrain's mention gazetteer
without guessing narrower `person`, `company`, or `organization` types that
are not present in the backup. The built-in `gbrain-base-v2` pack does not
declare the generic `entity` type, so import can report an advisory
undeclared-type warning; GBrain's mention and NER extractors nevertheless
recognize it. Missing or blank canonical names fail conversion rather than
creating unusable entity pages.

The root `manifest.json` records input validation totals, the input manifest
checksum, the pinned GBrain compatibility commit, profile mappings, per-kind
counts, paths, source IDs, and SHA-256 checksums for both representations and
the supplemental observation files. It does not include memory content. Given
the same validated backup and converter version, the complete output is
byte-for-byte deterministic.

The Markdown and raw sidecars intentionally preserve both original documents
and Hindsight-derived memories. This is evidence plus derived knowledge, so
some semantic overlap is expected. Review the staged corpus and manifest before
running `gbrain import`; import is a separate write operation. Embeddings,
Hindsight ranking state, and internal consolidation history are not converted.

## Relationship extraction

Conversion and import do not create links. Keep relationship extraction as a
separate, reviewed operation after the entity-quality report and live page-type
counts have been checked. Start with NER alone:

```bash
docker compose --env-file .env --profile gbrain exec -T gbrain \
  /usr/local/bin/gbrain extract links --ner --source db --dry-run --json
```

The command reports an aggregate proposed-link count but does not enumerate
individual candidates. Do not treat a nonzero count as approval to apply it:
the active schema pack's contextual regular expressions can match negated or
incidental wording. Inspect each candidate with a read-only audit before a
write pass. Broad `--by-mention` extraction is intentionally not part of the
migration workflow because imported prose can produce dense, low-value links
even after conservative entity filtering. Timeline extraction is also a
separate migration decision; the converter does not infer chronology from
database import times.

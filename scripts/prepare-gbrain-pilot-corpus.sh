#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
env_file="$repo_root/.env"
profile=""
apply=false
init_manifest=false

usage() {
  cat <<'EOF'
Usage: scripts/prepare-gbrain-pilot-corpus.sh --profile <name> [--init-manifest|--apply]

Prepare a timestamped, read-only GBrain staging corpus from a reviewed list of
Obsidian Markdown paths. With no action it prints the next required action.

  --init-manifest  Create appdata/gbrain/pilot-include-<profile>.txt from the
                   tracked example; edit and review it before copying.
  --apply          Hash the live vault, copy only selected Markdown to a new
                   staging directory, hash again, and require an empty diff.

This script never modifies the live vault. It refuses paths outside Shared/ and
Profiles/<profile>/, non-Markdown files, and suspicious path components.
EOF
}

while (($#)); do
  case "$1" in
    --profile) profile=${2:-}; shift 2 ;;
    --init-manifest) init_manifest=true; shift ;;
    --apply) apply=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! $profile =~ ^[a-z0-9_-]+$ ]] || [[ $profile == default ]]; then
  printf 'Profile must use lowercase letters, digits, underscores, or hyphens (not default).\n' >&2
  exit 2
fi
if $apply && $init_manifest; then
  printf 'Choose either --init-manifest or --apply.\n' >&2
  exit 2
fi
if [[ ! -f $env_file ]]; then
  printf 'Missing %s; create it from .env.example first.\n' "$env_file" >&2
  exit 1
fi

appdata_value=$(awk -F= '$1 == "APPDATA_DIR" {value = substr($0, length($1) + 2)} END {print value}' "$env_file")
appdata_value=${appdata_value:-./appdata}
if [[ $appdata_value == /* ]]; then
  appdata_dir=$appdata_value
else
  appdata_dir="$repo_root/$appdata_value"
fi
vault_dir="$appdata_dir/hermes/obsidian-memory-vault"
pilot_dir="$appdata_dir/gbrain"
manifest="$pilot_dir/pilot-include-$profile.txt"

if $init_manifest; then
  if [[ -e $manifest ]]; then
    printf 'Refusing to replace existing manifest: %s\n' "$manifest" >&2
    exit 1
  fi
  mkdir -p "$pilot_dir"
  sed "s|__PROFILE__|$profile|g" "$repo_root/gbrain/pilot-include.example" > "$manifest"
  printf 'Created %s. Review it, remove any sensitive locations, then run with --apply.\n' "$manifest"
  exit 0
fi

if ! $apply; then
  printf 'Create and review a manifest first:\n  %s --profile %s --init-manifest\n' "$0" "$profile"
  exit 0
fi
if [[ ! -d $vault_dir ]]; then
  printf 'Vault directory does not exist: %s\n' "$vault_dir" >&2
  exit 1
fi
if [[ ! -f $manifest ]]; then
  printf 'Missing reviewed manifest: %s\n' "$manifest" >&2
  exit 1
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
staging_dir="$pilot_dir/staging/$profile/$timestamp"
report_dir="$pilot_dir/reports/$profile"
before_hash="$report_dir/vault-before-$timestamp.sha256"
after_hash="$report_dir/vault-after-$timestamp.sha256"

hash_vault() {
  find "$vault_dir" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
}

mkdir -p "$staging_dir" "$report_dir"
hash_vault > "$before_hash"

copied=0
while IFS= read -r entry || [[ -n $entry ]]; do
  entry=${entry%$'\r'}
  [[ -z $entry || $entry == \#* ]] && continue
  if [[ $entry == /* || $entry == *'..'* || $entry == *'/.env'* || $entry == *.env || $entry == *credentials* ]]; then
    printf 'Unsafe manifest entry: %s\n' "$entry" >&2
    exit 1
  fi
  if [[ $entry != Shared/* && $entry != "Profiles/$profile/"* ]]; then
    printf 'Entry is outside the permitted pilot scope: %s\n' "$entry" >&2
    exit 1
  fi
  candidate="$vault_dir/$entry"
  if [[ -f $candidate ]]; then
    [[ $candidate == *.md ]] || { printf 'Only Markdown files are permitted: %s\n' "$entry" >&2; exit 1; }
    mkdir -p "$staging_dir/$(dirname -- "$entry")"
    cp -- "$candidate" "$staging_dir/$entry"
    ((copied += 1))
  elif [[ -d $candidate ]]; then
    while IFS= read -r -d '' markdown; do
      relative=${markdown#"$vault_dir/"}
      mkdir -p "$staging_dir/$(dirname -- "$relative")"
      cp -- "$markdown" "$staging_dir/$relative"
      ((copied += 1))
    done < <(find "$candidate" -type f -name '*.md' -print0)
  else
    printf 'Manifest path does not exist: %s\n' "$entry" >&2
    exit 1
  fi
done < "$manifest"

if ((copied == 0)); then
  printf 'Manifest selected no Markdown files; leaving %s for inspection.\n' "$staging_dir" >&2
  exit 1
fi
hash_vault > "$after_hash"
if ! diff -u "$before_hash" "$after_hash"; then
  printf 'Live vault changed during staging; do not import this corpus.\n' >&2
  exit 1
fi

printf 'Prepared %d Markdown files in %s\n' "$copied" "$staging_dir"
printf 'Vault hash comparison: unchanged (%s)\n' "$before_hash"
printf 'Next: scripts/run-gbrain-pilot.sh --profile %s import %s\n' "$profile" "$staging_dir"

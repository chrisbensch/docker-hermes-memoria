#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
env_file="$repo_root/.env"
profile=""

usage() {
  cat <<'EOF'
Usage: scripts/run-gbrain-pilot.sh --profile <name> <operation> [arguments]

Allowed operations:
  init                         Initialize isolated PGLite state; forces conservative mode.
  import <staging-directory>   Import staged Markdown only, always with --no-embed.
  doctor | stats               Read-only diagnostics.
  search <terms>               Read-only keyword retrieval.
  extract-links-dry-run        Preview graph extraction without writing graph edges.
  graph-query <slug>           Read-only graph traversal after an approved backfill.

No service is started and this script cannot run embedding, sync, serve, dream,
autopilot, enrichment, write operations, or live-vault imports.
EOF
}

while (($#)); do
  case "$1" in
    --profile) profile=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done

if [[ ! $profile =~ ^[a-z0-9_-]+$ ]] || [[ $profile == default ]]; then
  printf 'Profile must use lowercase letters, digits, underscores, or hyphens (not default).\n' >&2
  exit 2
fi
operation=${1:-}
[[ -n $operation ]] || { usage >&2; exit 2; }
shift
[[ -f $env_file ]] || { printf 'Missing %s; create it from .env.example first.\n' "$env_file" >&2; exit 1; }

appdata_value=$(awk -F= '$1 == "APPDATA_DIR" {value = substr($0, length($1) + 2)} END {print value}' "$env_file")
appdata_value=${appdata_value:-./appdata}
if [[ $appdata_value == /* ]]; then
  appdata_dir=$appdata_value
else
  appdata_dir="$repo_root/$appdata_value"
fi
pilot_dir="$appdata_dir/gbrain"
home_dir="$pilot_dir/home/$profile"
mkdir -p "$home_dir"

compose=(docker compose --env-file "$env_file" --profile gbrain-pilot run --rm -e "GBRAIN_HOME=/var/lib/gbrain/home/$profile" gbrain-pilot)
run_gbrain() {
  "${compose[@]}" "$@"
}

case "$operation" in
  init)
    (($# == 0)) || { usage >&2; exit 2; }
    run_gbrain init --pglite --no-embedding
    run_gbrain config set search.mode conservative
    run_gbrain search modes
    ;;
  import)
    (($# == 1)) || { usage >&2; exit 2; }
    corpus=$1
    [[ -d $corpus ]] || { printf 'Staging directory does not exist: %s\n' "$corpus" >&2; exit 1; }
    staging_root="$pilot_dir/staging/$profile/"
    corpus_real=$(realpath -e -- "$corpus")
    staging_real=$(realpath -e -- "$staging_root")/
    [[ $corpus_real == "$staging_real"* ]] || { printf 'Corpus must be below %s\n' "$staging_root" >&2; exit 1; }
    relative=${corpus_real#"$staging_real"}
    run_gbrain import "/staging/$profile/$relative" --no-embed
    ;;
  doctor)
    (($# == 0)) || { usage >&2; exit 2; }
    run_gbrain doctor --json
    ;;
  stats)
    (($# == 0)) || { usage >&2; exit 2; }
    run_gbrain stats
    ;;
  search)
    (($# == 1)) || { usage >&2; exit 2; }
    run_gbrain search "$1"
    ;;
  extract-links-dry-run)
    (($# == 0)) || { usage >&2; exit 2; }
    run_gbrain extract links --source db --dry-run
    ;;
  graph-query)
    (($# == 1)) || { usage >&2; exit 2; }
    run_gbrain graph-query "$1" --depth 2
    ;;
  *)
    printf 'Operation is not permitted by the read-only pilot: %s\n' "$operation" >&2
    usage >&2
    exit 2
    ;;
esac

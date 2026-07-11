#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
env_file=${HERMES_ENV_FILE:-$repo_dir/.env}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

env_value() {
  key=$1
  fallback=$2
  value=$(awk -F= -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "")
      sub(/\r$/, "")
      print
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$env_file" 2>/dev/null) || value=$fallback

  case $value in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
  esac
  printf '%s\n' "$value"
}

resolve_dir() {
  candidate=$1
  case $candidate in
    /*) ;;
    *) candidate=$repo_dir/$candidate ;;
  esac
  [ -d "$candidate" ] || fail "Directory does not exist: $candidate"
  (CDPATH= cd -- "$candidate" && pwd -P)
}

[ -f "$env_file" ] || fail "Environment file not found: $env_file"
command -v docker >/dev/null 2>&1 || fail "docker is required"
if ! command -v setfacl >/dev/null 2>&1; then
  fail "setfacl is required. On Ubuntu, install it with: sudo apt-get install acl"
fi

appdata_value=${APPDATA_DIR:-$(env_value APPDATA_DIR ./appdata)}
hermes_image=${HERMES_IMAGE:-$(env_value HERMES_IMAGE nousresearch/hermes-agent:latest)}
hermes_uid=${HERMES_UID:-$(env_value HERMES_UID 10000)}

case $hermes_uid in
  ''|*[!0-9]*) fail "HERMES_UID must be a positive numeric UID" ;;
  0) fail "HERMES_UID must be an unprivileged UID" ;;
esac
[ -n "$hermes_image" ] || fail "HERMES_IMAGE must not be empty"

appdata_dir=$(resolve_dir "$appdata_value")
data_value=${HERMES_DATA_DIR:-$appdata_dir/hermes}
data_dir=$(resolve_dir "$data_value")
vault_value=${HERMES_OBSIDIAN_VAULT_DIR:-$data_dir/obsidian-memory-vault}
vault_dir=$(resolve_dir "$vault_value")

case $vault_dir in
  /|"$repo_dir"|"$data_dir") fail "Refusing unsafe vault path: $vault_dir" ;;
esac
[ "$(basename -- "$vault_dir")" = obsidian-memory-vault ] ||
  fail "Refusing unsafe vault path: $vault_dir"
case $vault_dir in
  "$data_dir"/obsidian-memory-vault) ;;
  *) fail "Refusing unsafe vault path outside Hermes data: $vault_dir" ;;
esac

host_name=.permission-host-$(date +%s)-$$
container_name=.permission-hermes-$(date +%s)-$$
mapping_name=.permission-mapping-$(date +%s)-$$
host_file=$vault_dir/$host_name
container_file=$vault_dir/$container_name
mapping_file=$vault_dir/$mapping_name

cleanup() {
  rm -f -- "$host_file" "$container_file" "$mapping_file" 2>/dev/null || true
  docker run --rm --user 0:0 --entrypoint sh \
    --mount "type=bind,src=$vault_dir,dst=/mnt" \
    "$hermes_image" -c 'rm -f -- "/mnt/$1" "/mnt/$2" "/mnt/$3"' sh \
    "$host_name" "$container_name" "$mapping_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Temporarily map the tree to the rootless deployment user so host setfacl can
# update ACLs even when this helper is run repeatedly.
docker run --rm --user 0:0 --entrypoint sh \
  --mount "type=bind,src=$vault_dir,dst=/mnt" \
  "$hermes_image" -c '
    hermes_uid=$1
    mapping_name=$2
    chown -R 0:0 /mnt
    find /mnt -type d -exec chmod u+rwx,g+rwx,o-rwx,g+s {} +
    find /mnt -type f -exec chmod u+rw,g+rw,o-rwx {} +
    : > "/mnt/$mapping_name"
    chown "$hermes_uid":0 "/mnt/$mapping_name"
  ' sh "$hermes_uid" "$mapping_name"

mapped_hermes_uid=$(stat -c %u "$mapping_file")
case $mapped_hermes_uid in
  ''|*[!0-9]*) fail "Could not derive the mapped Hermes UID" ;;
esac
rm -f -- "$mapping_file"

# The named user maps back to container Hermes, while the owning group maps to
# the deployment user group. Defaults keep both paths writable under umask 0022.
setfacl -R -m "u:$mapped_hermes_uid:rwX,g::rwX,m::rwX,o::---" "$vault_dir"
find "$vault_dir" -type d -exec \
  setfacl -m "u::rwx,u:$mapped_hermes_uid:rwx,g::rwx,m::rwx,o::---,d:u::rwx,d:u:$mapped_hermes_uid:rwx,d:g::rwx,d:m::rwx,d:o::---" {} +

# Restore the intended container identity after the host ACL operation.
docker run --rm --user 0:0 --entrypoint sh \
  --mount "type=bind,src=$vault_dir,dst=/mnt" \
  "$hermes_image" -c '
    hermes_uid=$1
    chown -R "$hermes_uid":0 /mnt
    find /mnt -type d -exec chmod u+rwx,g+rwx,o-rwx,g+s {} +
    find /mnt -type f -exec chmod u+rw,g+rw,o-rwx {} +
  ' sh "$hermes_uid"

# Hermes creates with its real umask; the host must be able to modify/delete it.
docker run --rm --user "$hermes_uid:$hermes_uid" --entrypoint sh \
  --mount "type=bind,src=$vault_dir,dst=/mnt" \
  "$hermes_image" -c '
    umask 0022
    printf "%s\n" hermes-created > "/mnt/$1"
  ' sh "$container_name"
printf '%s\n' host-appended >> "$container_file"
rm -f -- "$container_file"
printf 'Host deployment-user write: ok\n'

# The host creates with umask 0022; Hermes must be able to modify/delete it.
(umask 0022 && printf '%s\n' host-created > "$host_file")
docker run --rm --user "$hermes_uid:$hermes_uid" --entrypoint sh \
  --mount "type=bind,src=$vault_dir,dst=/mnt" \
  "$hermes_image" -c '
    printf "%s\n" hermes-appended >> "/mnt/$1"
    rm -f -- "/mnt/$1"
  ' sh "$host_name"
printf 'Container Hermes write: ok\n'
printf 'Obsidian vault permissions normalized: %s\n' "$vault_dir"

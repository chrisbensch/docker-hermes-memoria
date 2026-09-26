#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

export HERMES_PROFILE_TEMPLATE=rootless
export HERMES_HEADROOM_MCP_DESCRIPTION="docker-backed stdio server joined to hermes-compose-mcp-rootless"

exec "$script_dir/create-profile.sh" "$@"
